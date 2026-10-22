//! hyprshell-face: the face unlock service's command line.
//!
//!   hyprshell-face status                     is it running, what it uses
//!   hyprshell-face verify [USER]              look for you now (as the lock screen does)
//!   hyprshell-face list [USER]                the looks it knows you by (JSON)
//!   hyprshell-face remove ID [USER]           forget one
//!   hyprshell-face clear [USER]               forget them all
//!   hyprshell-face enrol USER LABEL [STILLS]  add a look (root: Settings' helper);
//!                                             STILLS, a folder of webcam JPEGs
//!   hyprshell-face set KEY=VALUE …            change /etc/hyprshell-face.conf (root)
//!   hyprshell-face bench MODELS PICTURE …     the models on pictures, no service
//!
//! USER defaults to whoever runs it; only root may name someone else.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use serde_json::{json, Value};

use hyprshell_faced::image::Rgb;
use hyprshell_faced::models::{self, Detector, Recognizer};
use hyprshell_faced::store;

const SOCKET: &str = "/run/hyprshell-face/socket";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |i: usize| args.get(i).map(String::as_str);
    let code = match arg(0).unwrap_or("") {
        "status" => print(ask(json!({ "op": "status" }))),
        "verify" => print(ask(with_user(json!({ "op": "verify" }), arg(1)))),
        "list" => print(ask(with_user(json!({ "op": "list" }), arg(1)))),
        "clear" => print(ask(with_user(json!({ "op": "clear" }), arg(1)))),
        "remove" => match arg(1).and_then(|s| s.parse::<u32>().ok()) {
            Some(id) => print(ask(with_user(json!({ "op": "remove", "id": id }), arg(2)))),
            None => usage(),
        },
        "enrol" => match (arg(1), arg(2)) {
            (Some(user), Some(label)) => {
                let stills = arg(3).map(stills).unwrap_or_default();
                print(ask(json!({ "op": "enrol", "user": user, "label": label, "stills": stills })))
            }
            _ => usage(),
        },
        "set" if args.len() > 1 => set(&args[1..]),
        "bench" if args.len() >= 3 => {
            bench(Path::new(&args[1]), &args[2..]);
            0
        }
        _ => usage(),
    };
    std::process::exit(code);
}

fn usage() -> i32 {
    eprintln!("{}", include_str!("cli.rs").lines().skip(2).take(12).map(|l| l.trim_start_matches("//!").trim_start_matches(' ')).collect::<Vec<_>>().join("\n"));
    2
}

fn with_user(mut request: Value, user: Option<&str>) -> Value {
    if let Some(u) = user {
        request["user"] = json!(u);
    }
    request
}

/// The webcam stills in a folder, as base64, at most eight.
fn stills(dir: &str) -> Vec<String> {
    let mut paths: Vec<_> = std::fs::read_dir(dir).into_iter().flatten().filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("jpg")))
        .collect();
    paths.sort();
    paths.iter().take(8).filter_map(|p| std::fs::read(p).ok()).filter(|b| b.len() < 2 << 20)
        .map(|b| base64::engine::general_purpose::STANDARD.encode(b)).collect()
}

fn ask(request: Value) -> Value {
    let attempt = || -> std::io::Result<Value> {
        let mut stream = UnixStream::connect(SOCKET)?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.write_all(format!("{request}\n").as_bytes())?;
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line)?;
        serde_json::from_str(&line).map_err(std::io::Error::other)
    };
    attempt().unwrap_or_else(|e| json!({ "result": "unavailable", "message": format!("the face service isn't running ({e})") }))
}

/// The answer on stdout; the exit status says how it went: 0 done or
/// recognised, 1 not recognised, 2 refused or wrong, 3 unavailable.
fn print(reply: Value) -> i32 {
    println!("{reply}");
    match reply["result"].as_str().unwrap_or("") {
        "ok" | "match" => 0,
        "nomatch" => 1,
        "unavailable" => 3,
        _ => 2,
    }
}

/// Settings in /etc/hyprshell-face.conf, each checked before any is
/// written; the rest of the file kept as it is.
fn set(pairs: &[String]) -> i32 {
    const NUMBERS: [(&str, f32, f32); 6] = [("threshold", 0.2, 0.9), ("webcam_threshold", 0.2, 0.9), ("timeout", 1.0, 20.0),
                                             ("min_light", 0.0, 200.0), ("dark_frame", 0.0, 100.0), ("detect_score", 0.5, 0.99)];
    let mut changes = Vec::new();
    for pair in pairs {
        let Some((k, v)) = pair.split_once('=') else {
            eprintln!("hyprshell-face: KEY=VALUE, not {pair}");
            return 2;
        };
        let ok = match k {
            "ir_device" | "webcam_device" => v.is_empty() || is_video_device(v),
            "webcam_check" => v == "true" || v == "false",
            _ => NUMBERS.iter().any(|(n, lo, hi)| *n == k && v.parse::<f32>().is_ok_and(|x| (*lo..=*hi).contains(&x))),
        };
        if !ok {
            eprintln!("hyprshell-face: not a setting this takes: {pair}");
            return 2;
        }
        changes.push((k.to_string(), v.to_string()));
    }
    let text = std::fs::read_to_string(store::CONFIG).unwrap_or_default();
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    for (k, v) in changes {
        let line = format!("{k} = {v}");
        match lines.iter().position(|l| l.split('#').next().and_then(|s| s.split_once('=')).is_some_and(|(key, _)| key.trim() == k)) {
            Some(i) => lines[i] = line,
            None => lines.push(line),
        }
    }
    let tmp = format!("{}.new", store::CONFIG);
    let written = std::fs::write(&tmp, lines.join("\n") + "\n").and_then(|_| std::fs::rename(&tmp, store::CONFIG));
    match written {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("hyprshell-face: {}: {e}", store::CONFIG);
            2
        }
    }
}

fn is_video_device(v: &str) -> bool {
    v.strip_prefix("/dev/video").is_some_and(|n| !n.is_empty() && n.len() <= 3 && n.bytes().all(|b| b.is_ascii_digit()))
}

/// The models on pictures, without the service: faces found, how long
/// it took, and how alike each picture's face is to the others.
fn bench(models_dir: &Path, pictures: &[String]) {
    let t = std::time::Instant::now();
    let mut detector = Detector::load(&models_dir.join("yunet.onnx")).expect("YuNet");
    let recognizer = Recognizer::load(&models_dir.join("sface.onnx")).expect("SFace");
    println!("models loaded in {:?}", t.elapsed());
    let mut faces = Vec::new();
    for path in pictures {
        let Some(picture) = std::fs::read(path).ok().and_then(|b| Rgb::from_jpeg(&b)) else {
            println!("{path}: not a JPEG");
            continue;
        };
        // Twice: the first makes the plan for this size.
        let _ = detector.detect(&picture);
        let t = std::time::Instant::now();
        let found = detector.detect(&picture).expect("detect");
        let dt = t.elapsed();
        let t = std::time::Instant::now();
        let v = found.first().map(|f| recognizer.describe(&picture, f).expect("describe"));
        println!("{path}: {} face(s), find {:?}, describe {:?}, light {:.0}{}", found.len(), dt, t.elapsed(), picture.light(),
                 found.first().map(|f| format!(", box {:.0},{:.0} {:.0}x{:.0} sure {:.2}", f.x, f.y, f.w, f.h, f.score)).unwrap_or_default());
        faces.push((path.clone(), v));
    }
    for (i, (a, va)) in faces.iter().enumerate() {
        for (b, vb) in faces.iter().skip(i + 1) {
            if let (Some(va), Some(vb)) = (va, vb) {
                println!("  {a} ~ {b}: {:.3}", models::similarity(va, vb));
            }
        }
    }
}
