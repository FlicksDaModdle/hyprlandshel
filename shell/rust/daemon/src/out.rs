//! Events to the shell: one JSON object per line on stdout.

use serde_json::Value;
use std::io::Write;
use std::sync::Mutex;

static OUT: Mutex<()> = Mutex::new(());

pub fn emit(v: Value) {
    let _guard = OUT.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = std::io::stdout().lock();
    // A shell that has gone away is the end of this process too (main sees
    // stdin close); nothing to do about a failed write here.
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}
