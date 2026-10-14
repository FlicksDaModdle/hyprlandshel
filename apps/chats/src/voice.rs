//! Voice messages: WhatsApp's are Ogg Opus. Played by decoding them to a WAV
//! the sound engine plays; recorded by encoding the microphone to Ogg Opus.
//! The codec is the system's libopus, opened at run time (as Videos opens
//! libmpv), so nothing is linked at build time; the Ogg framing is the `ogg`
//! crate's.

use std::ffi::{c_int, c_void};
use std::io::Write;
use std::path::Path;
use std::sync::OnceLock;

const RATE: i32 = 48_000;
const OPUS_APPLICATION_VOIP: c_int = 2048;
const OPUS_SET_BITRATE: c_int = 4002;
const OPUS_GET_LOOKAHEAD: c_int = 4027;

struct Lib {
    _lib: libloading::Library,
    dec_create: unsafe extern "C" fn(i32, c_int, *mut c_int) -> *mut c_void,
    dec_float: unsafe extern "C" fn(*mut c_void, *const u8, i32, *mut f32, c_int, c_int) -> c_int,
    dec_destroy: unsafe extern "C" fn(*mut c_void),
    enc_create: unsafe extern "C" fn(i32, c_int, c_int, *mut c_int) -> *mut c_void,
    enc_float: unsafe extern "C" fn(*mut c_void, *const f32, c_int, *mut u8, i32) -> i32,
    enc_ctl: unsafe extern "C" fn(*mut c_void, c_int, ...) -> c_int,
    enc_destroy: unsafe extern "C" fn(*mut c_void),
}

fn lib() -> Result<&'static Lib, String> {
    static LIB: OnceLock<Result<Lib, String>> = OnceLock::new();
    LIB.get_or_init(|| unsafe {
        let lib = ["libopus.so.0", "libopus.so"]
            .iter()
            .find_map(|n| libloading::Library::new(n).ok())
            .ok_or("Voice messages need libopus (sudo pacman -S opus)")?;
        macro_rules! sym {
            ($n:literal) => {
                *lib.get(concat!($n, "\0").as_bytes()).map_err(|e| format!("libopus: {e}"))?
            };
        }
        Ok(Lib {
            dec_create: sym!("opus_decoder_create"),
            dec_float: sym!("opus_decode_float"),
            dec_destroy: sym!("opus_decoder_destroy"),
            enc_create: sym!("opus_encoder_create"),
            enc_float: sym!("opus_encode_float"),
            enc_ctl: sym!("opus_encoder_ctl"),
            enc_destroy: sym!("opus_encoder_destroy"),
            _lib: lib,
        })
    })
    .as_ref()
    .map_err(Clone::clone)
}

/// An Ogg Opus file as a 16-bit WAV, for the sound engine. Anything else is
/// left as it is (the engine plays it).
pub fn playable(src: &Path, cache: &Path) -> Result<std::path::PathBuf, String> {
    let mut head = [0u8; 40];
    {
        use std::io::Read;
        let mut f = std::fs::File::open(src).map_err(|e| e.to_string())?;
        let n = f.read(&mut head).unwrap_or(0);
        if n < 36 || &head[0..4] != b"OggS" || !head[..n].windows(8).any(|w| w == b"OpusHead") {
            return Ok(src.to_path_buf());
        }
    }
    let out = cache.join(format!(
        "{}.wav",
        src.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "voice".into())
    ));
    if out.exists() {
        return Ok(out);
    }
    let l = lib()?;
    let mut r = ogg::PacketReader::new(std::io::BufReader::new(std::fs::File::open(src).map_err(|e| e.to_string())?));
    let mut channels = 1;
    let mut skip = 0usize;
    let mut pcm: Vec<f32> = Vec::new();
    let mut dec: *mut c_void = std::ptr::null_mut();
    let mut buf = vec![0f32; 5760 * 2];
    while let Ok(Some(p)) = r.read_packet() {
        let d = &p.data;
        if d.starts_with(b"OpusHead") && d.len() >= 19 {
            channels = d[9].clamp(1, 2) as c_int;
            skip = u16::from_le_bytes([d[10], d[11]]) as usize * channels as usize;
            let mut err = 0;
            dec = unsafe { (l.dec_create)(RATE, channels, &mut err) };
            if dec.is_null() || err != 0 {
                return Err("libopus couldn't open the voice message".into());
            }
            continue;
        }
        if d.starts_with(b"OpusTags") || dec.is_null() {
            continue;
        }
        let n = unsafe { (l.dec_float)(dec, d.as_ptr(), d.len() as i32, buf.as_mut_ptr(), 5760, 0) };
        if n > 0 {
            pcm.extend_from_slice(&buf[..n as usize * channels as usize]);
        }
    }
    if !dec.is_null() {
        unsafe { (l.dec_destroy)(dec) };
    }
    if pcm.is_empty() {
        return Err("The voice message is empty or damaged".into());
    }
    let pcm = &pcm[skip.min(pcm.len())..];
    let _ = std::fs::create_dir_all(cache);
    write_wav(&out, pcm, channels as u16, RATE as u32).map_err(|e| e.to_string())?;
    Ok(out)
}

fn write_wav(path: &Path, pcm: &[f32], ch: u16, rate: u32) -> std::io::Result<()> {
    let bytes = (pcm.len() * 2) as u32;
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + bytes).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&ch.to_le_bytes())?;
    f.write_all(&rate.to_le_bytes())?;
    f.write_all(&(rate * ch as u32 * 2).to_le_bytes())?;
    f.write_all(&(ch * 2).to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&bytes.to_le_bytes())?;
    for s in pcm {
        f.write_all(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes())?;
    }
    f.flush()
}

/// Mono 48 kHz samples as an Ogg Opus voice message, the way WhatsApp's
/// own apps send them.
pub fn encode(samples: &[f32], out: &Path) -> Result<(), String> {
    let l = lib()?;
    let mut err = 0;
    let enc = unsafe { (l.enc_create)(RATE, 1, OPUS_APPLICATION_VOIP, &mut err) };
    if enc.is_null() || err != 0 {
        return Err("libopus couldn't start an encoder".into());
    }
    let mut lookahead: i32 = 312;
    unsafe {
        (l.enc_ctl)(enc, OPUS_SET_BITRATE, 32_000 as c_int);
        (l.enc_ctl)(enc, OPUS_GET_LOOKAHEAD, &mut lookahead as *mut i32);
    }
    let file = std::fs::File::create(out).map_err(|e| e.to_string())?;
    let mut w = ogg::PacketWriter::new(std::io::BufWriter::new(file));
    let serial = (crate::now_ms() & 0x7fff_ffff) as u32;
    let mut head = b"OpusHead".to_vec();
    head.push(1);
    head.push(1);
    head.extend_from_slice(&(lookahead as u16).to_le_bytes());
    head.extend_from_slice(&(RATE as u32).to_le_bytes());
    head.extend_from_slice(&0i16.to_le_bytes());
    head.push(0);
    let mut tags = b"OpusTags".to_vec();
    let vendor = b"hyprshell-chats";
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0u32.to_le_bytes());
    let pe = |e: std::io::Error| e.to_string();
    w.write_packet(head, serial, ogg::PacketWriteEndInfo::EndPage, 0).map_err(pe)?;
    w.write_packet(tags, serial, ogg::PacketWriteEndInfo::EndPage, 0).map_err(pe)?;

    const FRAME: usize = 960; // 20 ms
    let frames = samples.len().div_ceil(FRAME).max(1);
    let mut packet = vec![0u8; 4000];
    let mut frame = vec![0f32; FRAME];
    for i in 0..frames {
        let s = &samples[(i * FRAME).min(samples.len())..((i + 1) * FRAME).min(samples.len())];
        frame[..s.len()].copy_from_slice(s);
        frame[s.len()..].fill(0.0);
        let n = unsafe { (l.enc_float)(enc, frame.as_ptr(), FRAME as c_int, packet.as_mut_ptr(), packet.len() as i32) };
        if n < 0 {
            unsafe { (l.enc_destroy)(enc) };
            return Err("libopus couldn't encode the recording".into());
        }
        let last = i + 1 == frames;
        let granule = (lookahead as u64) + ((i + 1) * FRAME) as u64;
        let end = if last { ogg::PacketWriteEndInfo::EndStream } else { ogg::PacketWriteEndInfo::NormalPacket };
        w.write_packet(packet[..n as usize].to_vec(), serial, end, granule).map_err(pe)?;
    }
    unsafe { (l.enc_destroy)(enc) };
    Ok(())
}

/// The shape WhatsApp draws a voice message as: 64 heights, 0 to 100.
pub fn waveform(samples: &[f32]) -> Vec<i32> {
    let n = 64;
    if samples.is_empty() {
        return vec![0; n];
    }
    let per = samples.len().div_ceil(n).max(1);
    let rms: Vec<f32> = samples
        .chunks(per)
        .map(|c| (c.iter().map(|s| s * s).sum::<f32>() / c.len() as f32).sqrt())
        .collect();
    let top = rms.iter().cloned().fold(1e-4, f32::max);
    let mut out: Vec<i32> = rms.iter().map(|v| ((v / top).sqrt() * 100.0) as i32).collect();
    out.resize(n, 0);
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn round_trip() {
        if super::lib().is_err() {
            eprintln!("no libopus here; skipped");
            return;
        }
        let dir = std::env::temp_dir().join(format!("chats-voice-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // A second and a half of a 440 Hz tone.
        let samples: Vec<f32> = (0..72_000).map(|i| (i as f32 / 48_000.0 * 440.0 * std::f32::consts::TAU).sin() * 0.4).collect();
        let ogg = dir.join("v.ogg");
        super::encode(&samples, &ogg).unwrap();
        let head = std::fs::read(&ogg).unwrap();
        assert_eq!(&head[..4], b"OggS");
        assert!(head.len() < 20_000, "a voice message should be small: {} bytes", head.len());
        let wav = super::playable(&ogg, &dir).unwrap();
        let data = std::fs::read(&wav).unwrap();
        let frames = (data.len() - 44) / 2;
        assert!((70_000..74_000).contains(&frames), "{frames} samples back");
        // The tone survives: loud in the middle.
        let mid: Vec<i16> = data[44 + 2 * 30_000..44 + 2 * 31_000].chunks(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
        assert!(mid.iter().map(|v| v.unsigned_abs()).max().unwrap() > 8_000);
        let wave = super::waveform(&samples);
        assert_eq!(wave.len(), 64);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
