//! Settings → Login screen → Keyring (services/FaceKeyring.qml): the login keyring's
//! password kept sealed with the laptop's TPM, so a face login can open it. All of it is
//! scripts/face-keyring.sh; the password goes to it on its standard input, never on a
//! command line, and is not kept here once it has been sent.

use std::io::Write;
use std::process::{Command, Stdio};

#[derive(Clone, Default, Debug)]
pub struct Snap {
    pub probed: bool,
    pub creds_version: i64,
    pub tpm: bool,
    pub keyring_installed: bool,
    pub stored: bool,
    pub busy: bool,
    pub asking: bool,
    pub failed: bool,
    pub status: String,
}

impl Snap {
    pub fn available(&self) -> bool {
        self.creds_version >= 256 && self.tpm && self.keyring_installed
    }
}

#[derive(Clone, Debug)]
pub enum Cmd {
    Refresh,
    Ask(bool),
    Store(String),
    Forget,
}

pub enum Msg {
    Checked { creds: i64, tpm: bool, keyring: bool, stored: bool },
    Done { mode: &'static str, code: i32, said: String },
}

pub type Notify = std::sync::Arc<dyn Fn(Msg) + Send + Sync>;

fn script() -> std::path::PathBuf {
    hyprshell_kit::config_dir().join("quickshell/hyprshell/scripts/face-keyring.sh")
}

pub fn parse_check(text: &str) -> (i64, bool, bool, bool) {
    let (mut creds, mut tpm, mut keyring, mut stored) = (0, false, false, false);
    for line in text.lines() {
        let t: Vec<&str> = line.split('\t').collect();
        match t[0] {
            "creds" => creds = t.get(1).and_then(|v| v.trim().parse().ok()).unwrap_or(0),
            "tpm" => tpm = t.get(1) == Some(&"yes"),
            "keyring" => keyring = true,
            "stored" => stored = true,
            _ => {}
        }
    }
    (creds, tpm, keyring, stored)
}

#[derive(Default)]
pub struct Keyring {
    pub snap: Snap,
    notify: Option<Notify>,
}

impl Keyring {
    pub fn start(&mut self, notify: Notify) {
        self.notify = Some(notify);
        self.refresh();
    }

    pub fn refresh(&mut self) {
        let Some(n) = self.notify.clone() else { return };
        std::thread::spawn(move || {
            let out = Command::new("bash").arg(script()).arg("--check").stderr(Stdio::null()).output();
            let text = out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
            let (creds, tpm, keyring, stored) = parse_check(&text);
            n(Msg::Checked { creds, tpm, keyring, stored });
        });
    }

    pub fn command(&mut self, c: Cmd) {
        match c {
            Cmd::Refresh => self.refresh(),
            Cmd::Ask(on) => self.snap.asking = on,
            Cmd::Store(pw) => {
                if !self.snap.busy && !pw.is_empty() {
                    self.snap.busy = true;
                    self.snap.failed = false;
                    self.snap.status = "Checking it with the keyring…".into();
                    self.run("--store", "store", Some(pw));
                }
            }
            Cmd::Forget => {
                if !self.snap.busy {
                    self.snap.busy = true;
                    self.run("--forget", "forget", None);
                }
            }
        }
    }

    fn run(&mut self, flag: &'static str, mode: &'static str, password: Option<String>) {
        let Some(n) = self.notify.clone() else { return };
        std::thread::spawn(move || {
            let child = Command::new("bash").arg(script()).arg(flag).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn();
            let Ok(mut child) = child else {
                n(Msg::Done { mode, code: 127, said: "bash isn't installed".into() });
                return;
            };
            // Through the pipe only; closed straight away so the script reads to its end.
            if let Some(mut si) = child.stdin.take() {
                if let Some(pw) = password {
                    let _ = si.write_all(pw.as_bytes());
                }
            }
            let out = child.wait_with_output();
            let (code, said) = match out {
                Ok(o) => (o.status.code().unwrap_or(1), String::from_utf8_lossy(&o.stderr).trim().lines().last().unwrap_or("").replace("face-keyring.sh: ", "")),
                Err(_) => (1, String::new()),
            };
            n(Msg::Done { mode, code, said });
        });
    }

    /// True when the page should be drawn again.
    pub fn on_msg(&mut self, m: Msg) -> bool {
        match m {
            Msg::Checked { creds, tpm, keyring, stored } => {
                self.snap.creds_version = creds;
                self.snap.tpm = tpm;
                self.snap.keyring_installed = keyring;
                self.snap.stored = stored;
                self.snap.probed = true;
                if stored {
                    self.snap.asking = false;
                }
            }
            Msg::Done { mode, code, said } => {
                self.snap.busy = false;
                self.snap.failed = code != 0;
                self.snap.status = if code == 0 {
                    match mode {
                        "store" => "Stored, sealed with the TPM: your face opens the keyring now".to_string(),
                        "forget" => "Removed: after a face login, the keyring asks for your password".to_string(),
                        _ => String::new(),
                    }
                } else if said.is_empty() {
                    "That didn't work".to_string()
                } else {
                    said
                };
                self.refresh();
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_checks_lines_are_read() {
        let (creds, tpm, keyring, stored) = parse_check("creds\t257\ntpm\tyes\nkeyring\tx\nstored\n");
        assert!(creds == 257 && tpm && keyring && stored);
        let (c, t, k, s) = parse_check("creds\t255\ntpm\tno\n");
        assert!(c == 255 && !t && !k && !s);
    }

    #[test]
    fn it_needs_systemd_256_a_tpm_and_a_keyring() {
        let mut s = Snap { creds_version: 257, tpm: true, keyring_installed: true, ..Default::default() };
        assert!(s.available());
        s.tpm = false;
        assert!(!s.available());
    }
}
