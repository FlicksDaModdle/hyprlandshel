//! Audio devices through PulseAudio's own protocol (pipewire-pulse answers
//! it), in place of running `pactl -f json list …` and `pactl subscribe`.
//!
//! Volumes and mutes are not here — Quickshell's PipeWire binding has those.
//! This is what it lacks: cards and their modes, ports, formats and
//! latency, which output each app plays to, and the commands that change
//! them. The snapshot keeps pactl's JSON field names, so the shell reads
//! either the same way.
//!
//! Commands:  pa-watch {on}         follow changes, emitting snapshots
//!            pa-snapshot           one snapshot now
//!            pa-profile {card, profile}
//!            pa-port {kind: "sink"|"source", name, port}
//!            pa-move-input {index, sink}
//!            pa-move-output {index, source}
//!            pa-latency {card, port, usec}
//!            pa-load {module, args, tag}   → pa-module {tag, index}
//!            pa-unload {index}
//! Events:    pa {available, cards, sinks, sources, sinkInputs, sourceOutputs}
//!            pa-done {op, ok}

use crate::out;
use libpulse_binding as pulse;
use pulse::callbacks::ListResult;
use pulse::context::introspect::{CardInfo, SinkInfo, SinkInputInfo, SourceInfo, SourceOutputInfo};
use pulse::context::subscribe::InterestMaskSet;
use pulse::context::{Context, FlagSet, State};
use pulse::def::PortAvailable;
use pulse::mainloop::threaded::Mainloop;
use pulse::proplist::Proplist;
use serde_json::{json, Map, Value as Json};
use std::cell::RefCell;
use std::ops::Deref;
use std::rc::Rc;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn props(p: &Proplist) -> Json {
    let mut m = Map::new();
    for k in p.iter() {
        if let Some(v) = p.get_str(&k) {
            m.insert(k, Json::String(v));
        }
    }
    Json::Object(m)
}

fn avail(a: PortAvailable) -> &'static str {
    match a {
        PortAvailable::Yes => "available",
        PortAvailable::No => "not available",
        _ => "availability unknown",
    }
}

fn opt(s: &Option<std::borrow::Cow<'_, str>>) -> String {
    s.as_deref().unwrap_or("").to_string()
}

fn card_json(c: &CardInfo) -> Json {
    json!({
        "index": c.index,
        "name": opt(&c.name),
        "properties": props(&c.proplist),
        "profiles": c.profiles.iter().map(|p| json!({
            "name": opt(&p.name), "description": opt(&p.description),
            "priority": p.priority, "available": p.available
        })).collect::<Vec<_>>(),
        "active_profile": c.active_profile.as_ref().map(|p| opt(&p.name)).unwrap_or_default(),
        "ports": c.ports.iter().map(|p| json!({
            "name": opt(&p.name), "description": opt(&p.description),
            "latency_offset": p.latency_offset, "availability": avail(p.available)
        })).collect::<Vec<_>>()
    })
}

fn sink_json(s: &SinkInfo) -> Json {
    use pulse::def::SinkState::*;
    json!({
        "index": s.index,
        "name": opt(&s.name),
        "description": opt(&s.description),
        "state": match s.state { Running => "RUNNING", Idle => "IDLE", Suspended => "SUSPENDED", _ => "INVALID" },
        "card": s.card,
        "sample_specification": s.sample_spec.print(),
        "channel_map": s.channel_map.print(),
        "latency": { "actual": s.latency.0 },
        "properties": props(&s.proplist),
        "ports": s.ports.iter().map(|p| json!({
            "name": opt(&p.name), "description": opt(&p.description), "availability": avail(p.available)
        })).collect::<Vec<_>>(),
        "active_port": s.active_port.as_ref().map(|p| opt(&p.name)).unwrap_or_default()
    })
}

fn source_json(s: &SourceInfo) -> Json {
    use pulse::def::SourceState::*;
    json!({
        "index": s.index,
        "name": opt(&s.name),
        "description": opt(&s.description),
        "state": match s.state { Running => "RUNNING", Idle => "IDLE", Suspended => "SUSPENDED", _ => "INVALID" },
        "card": s.card,
        "sample_specification": s.sample_spec.print(),
        "channel_map": s.channel_map.print(),
        "latency": { "actual": s.latency.0 },
        "properties": props(&s.proplist),
        "ports": s.ports.iter().map(|p| json!({
            "name": opt(&p.name), "description": opt(&p.description), "availability": avail(p.available)
        })).collect::<Vec<_>>(),
        "active_port": s.active_port.as_ref().map(|p| opt(&p.name)).unwrap_or_default()
    })
}

fn input_json(i: &SinkInputInfo) -> Json {
    json!({ "index": i.index, "sink": i.sink, "properties": props(&i.proplist) })
}
fn output_json(o: &SourceOutputInfo) -> Json {
    json!({ "index": o.index, "source": o.source, "properties": props(&o.proplist) })
}

/// The five lists, filled in by callbacks on PulseAudio's thread; the last
/// one to finish sends the lot back to ours.
#[derive(Default)]
struct Acc {
    cards: Vec<Json>,
    sinks: Vec<Json>,
    sources: Vec<Json>,
    inputs: Vec<Json>,
    outputs: Vec<Json>,
    done: u8,
}

struct Session {
    ml: Rc<RefCell<Mainloop>>,
    ctx: Rc<RefCell<Context>>,
    tx: Sender<Json>,
}

impl Session {
    fn connect(tx: &Sender<Json>) -> Result<Session, String> {
        let ml = Rc::new(RefCell::new(Mainloop::new().ok_or("no mainloop")?));
        let mut pl = Proplist::new().ok_or("no proplist")?;
        let _ = pl.set_str(pulse::proplist::properties::APPLICATION_NAME, "hyprshell-daemon");
        let ctx = Rc::new(RefCell::new(
            Context::new_with_proplist(ml.borrow().deref(), "hyprshell-daemon", &pl).ok_or("no context")?,
        ));
        {
            let tx = tx.clone();
            ctx.borrow_mut().set_state_callback(Some(Box::new(move || {
                let _ = tx.send(json!({ "cmd": "_state" }));
            })));
        }
        {
            let tx = tx.clone();
            ctx.borrow_mut().set_subscribe_callback(Some(Box::new(move |_, _, _| {
                let _ = tx.send(json!({ "cmd": "_changed" }));
            })));
        }
        ctx.borrow_mut().connect(None, FlagSet::NOAUTOSPAWN, None).map_err(|e| format!("{e}"))?;
        ml.borrow_mut().start().map_err(|e| format!("{e}"))?;
        Ok(Session { ml, ctx, tx: tx.clone() })
    }

    fn state(&self) -> State {
        self.ml.borrow_mut().lock();
        let s = self.ctx.borrow().get_state();
        self.ml.borrow_mut().unlock();
        s
    }

    fn subscribe(&self, on: bool) {
        let mask = if on {
            InterestMaskSet::SINK | InterestMaskSet::SOURCE | InterestMaskSet::SINK_INPUT
                | InterestMaskSet::SOURCE_OUTPUT | InterestMaskSet::CARD | InterestMaskSet::SERVER
        } else {
            InterestMaskSet::NULL
        };
        self.ml.borrow_mut().lock();
        self.ctx.borrow_mut().subscribe(mask, |_| {});
        self.ml.borrow_mut().unlock();
    }

    fn snapshot(&self) {
        let acc = Arc::new(Mutex::new(Acc::default()));
        let finish = {
            let acc = acc.clone();
            let tx = self.tx.clone();
            move || {
                let mut a = acc.lock().unwrap();
                a.done += 1;
                if a.done == 5 {
                    let _ = tx.send(json!({
                        "cmd": "_snap",
                        "data": {
                            "cards": std::mem::take(&mut a.cards), "sinks": std::mem::take(&mut a.sinks),
                            "sources": std::mem::take(&mut a.sources), "sinkInputs": std::mem::take(&mut a.inputs),
                            "sourceOutputs": std::mem::take(&mut a.outputs)
                        }
                    }));
                }
            }
        };
        self.ml.borrow_mut().lock();
        let intro = self.ctx.borrow().introspect();
        macro_rules! list {
            ($method:ident, $field:ident, $conv:ident) => {{
                let acc = acc.clone();
                let finish = finish.clone();
                intro.$method(move |r| match r {
                    ListResult::Item(i) => acc.lock().unwrap().$field.push($conv(i)),
                    _ => finish(),
                });
            }};
        }
        list!(get_card_info_list, cards, card_json);
        list!(get_sink_info_list, sinks, sink_json);
        list!(get_source_info_list, sources, source_json);
        list!(get_sink_input_info_list, inputs, input_json);
        list!(get_source_output_info_list, outputs, output_json);
        self.ml.borrow_mut().unlock();
    }

    fn act(&self, cmd: &Json) {
        let op = cmd["cmd"].as_str().unwrap_or("").to_string();
        let done = {
            let tx = self.tx.clone();
            let op = op.clone();
            Some(Box::new(move |ok: bool| {
                let _ = tx.send(json!({ "cmd": "_done", "op": op, "ok": ok }));
            }) as Box<dyn FnMut(bool)>)
        };
        let st = |k: &str| cmd[k].as_str().unwrap_or("").to_string();
        let n = |k: &str| cmd[k].as_u64().unwrap_or(u32::MAX as u64) as u32;

        self.ml.borrow_mut().lock();
        let mut intro = self.ctx.borrow().introspect();
        match op.as_str() {
            "pa-profile" => { intro.set_card_profile_by_name(&st("card"), &st("profile"), done); }
            "pa-port" if st("kind") == "source" => { intro.set_source_port_by_name(&st("name"), &st("port"), done); }
            "pa-port" => { intro.set_sink_port_by_name(&st("name"), &st("port"), done); }
            "pa-move-input" => { intro.move_sink_input_by_name(n("index"), &st("sink"), done); }
            "pa-move-output" => { intro.move_source_output_by_name(n("index"), &st("source"), done); }
            "pa-latency" => {
                let usec = cmd["usec"].as_i64().unwrap_or(0);
                intro.set_port_latency_offset(&st("card"), &st("port"), usec, done);
            }
            "pa-load" => {
                let tx = self.tx.clone();
                let tag = cmd["tag"].clone();
                intro.load_module(&st("module"), &st("args"), move |index| {
                    // PA_INVALID_INDEX on failure.
                    let index = if index == u32::MAX { json!(-1) } else { json!(index) };
                    let _ = tx.send(json!({ "cmd": "_loaded", "tag": tag, "index": index }));
                });
            }
            "pa-unload" => {
                let tx = self.tx.clone();
                intro.unload_module(n("index"), move |ok| {
                    let _ = tx.send(json!({ "cmd": "_done", "op": "pa-unload", "ok": ok }));
                });
            }
            _ => {}
        }
        self.ml.borrow_mut().unlock();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.ml.borrow_mut().lock();
        self.ctx.borrow_mut().set_state_callback(None);
        self.ctx.borrow_mut().set_subscribe_callback(None);
        self.ctx.borrow_mut().disconnect();
        self.ml.borrow_mut().unlock();
        self.ml.borrow_mut().stop();
    }
}

fn session(rx: &Receiver<Json>, tx: &Sender<Json>, watching: &mut bool) -> Result<(), String> {
    let s = Session::connect(tx)?;
    // Up, or not, within a few seconds; commands that arrive meanwhile wait.
    let mut pending = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match s.state() {
            State::Ready => break,
            State::Failed | State::Terminated => return Err("can't connect to the sound server".into()),
            _ => {}
        }
        let left = deadline.checked_duration_since(Instant::now()).ok_or("the sound server didn't answer")?;
        match rx.recv_timeout(left) {
            Ok(c) if c["cmd"] == "_state" => {}
            Ok(c) => pending.push(c),
            Err(RecvTimeoutError::Timeout) => return Err("the sound server didn't answer".into()),
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        }
    }

    if *watching {
        s.subscribe(true);
    }
    // The first snapshot goes out either way: the shell asks for details
    // the moment a stream needs moving, watched or not.
    s.snapshot();
    let mut snapshot_pending = true;
    // A change that arrived while a snapshot was already on its way: that
    // snapshot may have missed it, so another follows.
    let mut dirty = false;

    let mut queue: std::collections::VecDeque<Json> = pending.into();
    loop {
        let cmd = match queue.pop_front() {
            Some(c) => c,
            None => match rx.recv() {
                Ok(c) => c,
                Err(_) => return Ok(()),
            },
        };
        match cmd["cmd"].as_str().unwrap_or("") {
            "_state" => match s.state() {
                State::Failed | State::Terminated => return Err("the sound server went away".into()),
                _ => {}
            },
            "pa-watch" => {
                let on = cmd["on"].as_bool().unwrap_or(false);
                if on != *watching {
                    *watching = on;
                    s.subscribe(on);
                }
                if on && !snapshot_pending {
                    s.snapshot();
                    snapshot_pending = true;
                }
            }
            "pa-snapshot" => {
                if !snapshot_pending {
                    s.snapshot();
                    snapshot_pending = true;
                }
            }
            "_changed" => {
                // A burst of events — one per stream as an app starts, one
                // per tick of a volume drag — is one snapshot.
                let settle = Instant::now() + Duration::from_millis(150);
                while let Some(left) = settle.checked_duration_since(Instant::now()) {
                    match rx.recv_timeout(left) {
                        Ok(c) if c["cmd"] == "_changed" => {}
                        Ok(c) => queue.push_back(c),
                        Err(RecvTimeoutError::Timeout) => break,
                        Err(RecvTimeoutError::Disconnected) => return Ok(()),
                    }
                }
                if *watching {
                    if snapshot_pending {
                        dirty = true;
                    } else {
                        s.snapshot();
                        snapshot_pending = true;
                    }
                }
            }
            "_snap" => {
                snapshot_pending = false;
                if dirty {
                    dirty = false;
                    s.snapshot();
                    snapshot_pending = true;
                }
                let mut ev = cmd["data"].clone();
                ev["ev"] = json!("pa");
                ev["available"] = json!(true);
                out::emit(ev);
            }
            "_done" => {
                out::emit(json!({ "ev": "pa-done", "op": cmd["op"], "ok": cmd["ok"] }));
                // What changed is worth seeing straight away, watched or not.
                if !snapshot_pending {
                    s.snapshot();
                    snapshot_pending = true;
                }
            }
            "_loaded" => out::emit(json!({ "ev": "pa-module", "tag": cmd["tag"], "index": cmd["index"] })),
            _ => s.act(&cmd),
        }
    }
}

pub fn start() -> Sender<Json> {
    let (tx, rx) = channel::<Json>();
    let tx2 = tx.clone();
    std::thread::spawn(move || {
        let mut watching = false;
        let mut wait = Duration::from_secs(2);
        loop {
            let began = Instant::now();
            match session(&rx, &tx2, &mut watching) {
                Ok(()) => return,
                Err(e) => out::emit(json!({ "ev": "pa", "available": false, "message": e })),
            }
            // A session that lasted resets the backoff.
            if began.elapsed() > Duration::from_secs(60) {
                wait = Duration::from_secs(2);
            }
            let deadline = Instant::now() + wait;
            while let Some(left) = deadline.checked_duration_since(Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok(c) if c["cmd"] == "pa-watch" => watching = c["on"].as_bool().unwrap_or(false),
                    Ok(_) => {}
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            wait = (wait * 2).min(Duration::from_secs(30));
        }
    });
    tx
}
