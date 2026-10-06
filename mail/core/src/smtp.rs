// Sending: a message built from what the compose window gives, sent by SMTP
// and filed in Sent.

use crate::account::Account;
use crate::imap::Auth;
use lettre::message::header::{ContentType, HeaderName, HeaderValue};
use lettre::message::{Attachment, Mailbox, MultiPart, SinglePart};
use lettre::transport::smtp::authentication::{Credentials, Mechanism};
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
use serde_json::Value;
use std::time::Duration;

fn mailbox(v: &Value) -> Result<Mailbox, String> {
    let email = v.get("email").and_then(|e| e.as_str()).or_else(|| v.as_str()).unwrap_or("").trim();
    let name = v.get("name").and_then(|e| e.as_str()).unwrap_or("").trim();
    let addr = email.parse().map_err(|_| format!("\"{}\" is not an email address", email))?;
    Ok(Mailbox::new(if name.is_empty() { None } else { Some(name.to_string()) }, addr))
}

fn mailboxes(v: Option<&Value>) -> Result<Vec<Mailbox>, String> {
    match v {
        Some(Value::Array(a)) => a.iter().map(mailbox).collect(),
        Some(Value::String(s)) if !s.trim().is_empty() => s
            .split(',')
            .map(|x| mailbox(&Value::String(x.trim().to_string())))
            .collect(),
        _ => Ok(vec![]),
    }
}

/// The recipients, for the contacts list.
pub fn recipients(req: &Value) -> Vec<(String, String)> {
    let mut out = vec![];
    for k in ["to", "cc", "bcc"] {
        if let Ok(list) = mailboxes(req.get(k)) {
            for m in list {
                out.push((m.name.unwrap_or_default(), m.email.to_string()));
            }
        }
    }
    out
}

/// The message itself. `req`: { to, cc, bcc, subject, text, html,
/// attachments: [path], inReplyTo, references: [id], calendar: {method, ics} }
pub fn build(a: &Account, req: &Value) -> Result<Message, String> {
    let from = Mailbox::new(
        if a.display_name.is_empty() { None } else { Some(a.display_name.clone()) },
        a.email.parse().map_err(|_| "This account's address is not valid".to_string())?,
    );
    let mut b = Message::builder().from(from).subject(req.get("subject").and_then(|s| s.as_str()).unwrap_or(""));
    let to = mailboxes(req.get("to"))?;
    let cc = mailboxes(req.get("cc"))?;
    let bcc = mailboxes(req.get("bcc"))?;
    if to.is_empty() && cc.is_empty() && bcc.is_empty() {
        return Err("Add someone to send it to".into());
    }
    for m in to {
        b = b.to(m);
    }
    for m in cc {
        b = b.cc(m);
    }
    for m in bcc {
        b = b.bcc(m);
    }
    if let Some(r) = req.get("inReplyTo").and_then(|s| s.as_str()).filter(|s| !s.is_empty()) {
        b = b.in_reply_to(format!("<{}>", r.trim_matches(|c| c == '<' || c == '>')));
    }
    if let Some(Value::Array(refs)) = req.get("references") {
        let r: Vec<String> = refs
            .iter()
            .filter_map(|x| x.as_str())
            .map(|x| format!("<{}>", x.trim_matches(|c| c == '<' || c == '>')))
            .collect();
        if !r.is_empty() {
            b = b.references(r.join(" "));
        }
    }
    b = b.header(XMailer(String::from("Hyprshell Mail")));
    // Its own Message-ID, on the sender's domain, so replies can find it.
    let domain = a.email.rsplit('@').next().unwrap_or("localhost");
    b = b.message_id(Some(format!("<{:016x}{:08x}@{}>", rand::random::<u64>(), crate::db::now() as u32, domain)));

    let text = req.get("text").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let html = req.get("html").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let body = if html.is_empty() {
        MultiPart::alternative().singlepart(SinglePart::plain(text))
    } else {
        MultiPart::alternative().singlepart(SinglePart::plain(text)).singlepart(SinglePart::html(html))
    };
    // An invitation answer goes as a calendar part beside the text, which
    // is how calendars recognise it.
    let body = match req.get("calendar") {
        Some(c) => {
            let method = c.get("method").and_then(|m| m.as_str()).unwrap_or("REPLY");
            let ics = c.get("ics").and_then(|m| m.as_str()).unwrap_or("").to_string();
            let ct = ContentType::parse(&format!("text/calendar; charset=UTF-8; method={}", method)).map_err(|e| e.to_string())?;
            body.singlepart(SinglePart::builder().header(ct).body(ics))
        }
        None => body,
    };

    let files: Vec<String> = match req.get("attachments") {
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect(),
        _ => vec![],
    };
    let msg = if files.is_empty() {
        b.multipart(body)
    } else {
        let mut mixed = MultiPart::mixed().multipart(body);
        for f in files {
            let path = f.strip_prefix("file://").unwrap_or(&f).to_string();
            let bytes = std::fs::read(&path).map_err(|e| format!("Could not attach {}: {}", path, e))?;
            let name = std::path::Path::new(&path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "attachment".into());
            let ct = ContentType::parse(guess_mime(&name)).unwrap_or(ContentType::parse("application/octet-stream").unwrap());
            mixed = mixed.singlepart(Attachment::new(name).body(bytes, ct));
        }
        b.multipart(mixed)
    };
    msg.map_err(|e| e.to_string())
}

#[derive(Clone)]
struct XMailer(String);
impl lettre::message::header::Header for XMailer {
    fn name() -> HeaderName {
        HeaderName::new_from_ascii_str("X-Mailer")
    }
    fn parse(s: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        Ok(XMailer(s.to_string()))
    }
    fn display(&self) -> HeaderValue {
        HeaderValue::new(Self::name(), self.0.clone())
    }
}

fn guess_mime(name: &str) -> &'static str {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "txt" | "md" => "text/plain",
        "html" | "htm" => "text/html",
        "csv" => "text/csv",
        "zip" => "application/zip",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "ics" => "text/calendar",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    }
}

pub async fn send(a: &Account, auth: &Auth, msg: &Message) -> Result<(), String> {
    let host = a.smtp_host.trim();
    if host.is_empty() {
        return Err("No SMTP server set".into());
    }
    let creds = match auth {
        Auth::Password(p) => Credentials::new(a.login().to_string(), p.clone()),
        Auth::OAuth(t) => Credentials::new(a.login().to_string(), t.clone()),
    };
    let mechs = match auth {
        Auth::Password(_) => vec![Mechanism::Plain, Mechanism::Login],
        Auth::OAuth(_) => vec![Mechanism::Xoauth2],
    };
    let builder = match a.smtp_security.as_str() {
        "starttls" => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(host).map_err(|e| e.to_string())?,
        "none" => {
            if !Account::is_local_host(host) {
                return Err("An unencrypted connection is only allowed to this computer".into());
            }
            AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
        }
        _ => AsyncSmtpTransport::<Tokio1Executor>::relay(host).map_err(|e| e.to_string())?,
    };
    let mut builder = builder.port(a.smtp_port).timeout(Some(Duration::from_secs(60)));
    // A local test server without authentication takes none.
    if !(a.smtp_security == "none" && matches!(auth, Auth::Password(p) if p.is_empty())) {
        builder = builder.credentials(creds).authentication(mechs);
    }
    let transport = builder.build();
    transport.send(msg.clone()).await.map_err(|e| {
        let s = e.to_string();
        if s.contains("535") || s.contains("authentication") {
            "The mail server refused to send: sign-in failed".to_string()
        } else {
            format!("Could not send: {}", s)
        }
    })?;
    Ok(())
}
