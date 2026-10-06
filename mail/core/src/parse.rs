// From a message's raw source to what the app shows: a summary for lists,
// and the whole of it — HTML with its inline images, text, attachments, an
// invitation — for the reader.

use base64::Engine;
use mail_parser::{Address, HeaderValue, MessageParser, MimeHeaders, PartType};
use serde_json::{json, Value};

pub struct Summary {
    pub msgid: String,
    /// What it answers, oldest first: References, then In-Reply-To.
    pub refs: Vec<String>,
    pub subject: String,
    pub from_name: String,
    pub from_addr: String,
    pub to: Vec<(String, String)>,
    pub cc: Vec<(String, String)>,
    pub date: i64,
    pub snippet: String,
    pub has_att: bool,
    pub invite: bool,
    /// Plain text for the search index.
    pub body: String,
}

fn list(v: &HeaderValue) -> Vec<String> {
    match v {
        HeaderValue::Text(t) => t.split_whitespace().map(|s| s.trim_matches(|c| c == '<' || c == '>').to_string()).collect(),
        HeaderValue::TextList(l) => l.iter().map(|s| s.trim_matches(|c| c == '<' || c == '>').to_string()).collect(),
        _ => vec![],
    }
}

pub fn addrs(a: Option<&Address>) -> Vec<(String, String)> {
    match a {
        Some(a) => a
            .iter()
            .filter_map(|x| {
                x.address().map(|addr| (x.name().unwrap_or("").to_string(), addr.to_string()))
            })
            .collect(),
        None => vec![],
    }
}

pub fn addrs_json(v: &[(String, String)]) -> Value {
    Value::Array(v.iter().map(|(n, a)| json!({ "name": n, "email": a })).collect())
}

fn is_real_attachment(p: &mail_parser::MessagePart) -> bool {
    let disp_inline = p
        .content_disposition()
        .map(|d| d.ctype().eq_ignore_ascii_case("inline"))
        .unwrap_or(false);
    let is_cal = p
        .content_type()
        .map(|c| c.ctype().eq_ignore_ascii_case("text") && c.subtype().map(|s| s.eq_ignore_ascii_case("calendar")).unwrap_or(false))
        .unwrap_or(false);
    // An image referred to from the HTML is part of the message, not
    // something attached to it.
    !(p.content_id().is_some() && (disp_inline || p.attachment_name().is_none())) && !is_cal
}

fn has_calendar(m: &mail_parser::Message) -> bool {
    m.parts.iter().any(|p| {
        p.content_type()
            .map(|c| c.ctype().eq_ignore_ascii_case("text") && c.subtype().map(|s| s.eq_ignore_ascii_case("calendar")).unwrap_or(false))
            .unwrap_or(false)
    })
}

pub fn summarize(raw: &[u8]) -> Option<Summary> {
    let m = MessageParser::default().parse(raw)?;
    let mut refs = list(m.references());
    for r in list(m.in_reply_to()) {
        if !refs.contains(&r) {
            refs.push(r);
        }
    }
    let from = addrs(m.from());
    let (from_name, from_addr) = from.first().cloned().unwrap_or_default();
    let body = m.body_text(0).map(|t| t.to_string()).unwrap_or_default();
    let snippet: String = body
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('>'))
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(200)
        .collect();
    let has_att = m.attachments().any(is_real_attachment);
    Some(Summary {
        msgid: m.message_id().unwrap_or("").to_string(),
        refs,
        subject: m.subject().unwrap_or("").to_string(),
        from_name,
        from_addr,
        to: addrs(m.to()),
        cc: addrs(m.cc()),
        date: m.date().map(|d| d.to_timestamp()).unwrap_or(0),
        snippet,
        has_att,
        invite: has_calendar(&m),
        body: body.chars().take(20000).collect(),
    })
}

/// A part's content, decoded.
fn contents<'a>(p: &'a mail_parser::MessagePart) -> &'a [u8] {
    match &p.body {
        PartType::Text(t) | PartType::Html(t) => t.as_bytes(),
        PartType::Binary(b) | PartType::InlineBinary(b) => b.as_ref(),
        PartType::Message(m) => m.raw_message(),
        PartType::Multipart(_) => &[],
    }
}

fn mime_of(p: &mail_parser::MessagePart) -> String {
    p.content_type()
        .map(|c| format!("{}/{}", c.ctype(), c.subtype().unwrap_or("octet-stream")).to_ascii_lowercase())
        .unwrap_or_else(|| "application/octet-stream".into())
}

fn name_of(p: &mail_parser::MessagePart, i: usize) -> String {
    if let Some(n) = p.attachment_name() {
        return n.to_string();
    }
    if let PartType::Message(m) = &p.body {
        if let Some(s) = m.subject() {
            return format!("{}.eml", s);
        }
    }
    let ext = match mime_of(p).as_str() {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "application/pdf" => "pdf",
        "text/calendar" => "ics",
        "message/rfc822" => "eml",
        _ => "bin",
    };
    format!("attachment-{}.{}", i + 1, ext)
}

/// Everything the reader needs.
pub fn full(raw: &[u8], have_body: bool) -> Value {
    let Some(m) = MessageParser::default().parse(raw) else {
        return json!({ "error": "This message could not be read" });
    };
    let original_html = m.html_part(0).map(|p| p.is_text_html()).unwrap_or(false);
    let mut html = if original_html {
        m.body_html(0).map(|h| h.to_string()).unwrap_or_default()
    } else {
        String::new()
    };
    let text = m.body_text(0).map(|t| t.to_string()).unwrap_or_default();

    // Inline images become data: URLs, so the viewer never has to fetch
    // anything to show what the message itself carries.
    let mut budget: usize = 20 * 1024 * 1024;
    let mut attachments = vec![];
    for (i, p) in m.attachments().enumerate() {
        let data = contents(p);
        if let Some(cid) = p.content_id() {
            let cid = cid.trim_matches(|c| c == '<' || c == '>');
            let needle = format!("cid:{}", cid);
            if !html.is_empty() && html.contains(&needle) && data.len() <= budget {
                budget -= data.len();
                let uri = format!(
                    "data:{};base64,{}",
                    mime_of(p),
                    base64::engine::general_purpose::STANDARD.encode(data)
                );
                html = html.replace(&needle, &uri);
                if !is_real_attachment(p) {
                    continue;
                }
            }
        }
        if !is_real_attachment(p) {
            continue;
        }
        attachments.push(json!({
            "index": i,
            "name": name_of(p, i),
            "mime": mime_of(p),
            "size": data.len(),
        }));
    }

    // An invitation, from the first text/calendar part.
    let invite = m
        .parts
        .iter()
        .find(|p| mime_of(p) == "text/calendar")
        .and_then(|p| std::str::from_utf8(contents(p)).ok().map(|s| s.to_string()))
        .and_then(|ics| crate::ics::parse(&ics));

    let unsubscribe = list(m.list_unsubscribe())
        .into_iter()
        .chain(match m.list_unsubscribe() {
            HeaderValue::Address(a) => a.iter().filter_map(|x| x.address().map(|s| s.to_string())).collect(),
            _ => vec![],
        })
        .find(|u| u.starts_with("http") || u.starts_with("mailto:"));

    let reply_to = addrs(m.reply_to());
    json!({
        "subject": m.subject().unwrap_or(""),
        "from": addrs_json(&addrs(m.from())),
        "to": addrs_json(&addrs(m.to())),
        "cc": addrs_json(&addrs(m.cc())),
        "replyTo": addrs_json(&reply_to),
        "date": m.date().map(|d| d.to_timestamp()).unwrap_or(0),
        "msgid": m.message_id().unwrap_or(""),
        "references": list(m.references()),
        "html": html,
        "text": text,
        "hasBody": have_body,
        "attachments": attachments,
        "invite": invite,
        "unsubscribe": unsubscribe,
    })
}

/// One attachment: its name, type and bytes.
pub fn part(raw: &[u8], index: usize) -> Option<(String, String, Vec<u8>)> {
    let m = MessageParser::default().parse(raw)?;
    let p = m.attachments().nth(index)?;
    Some((name_of(p, index), mime_of(p), contents(p).to_vec()))
}

/// The raw text/calendar part, for answering an invitation.
pub fn calendar(raw: &[u8]) -> Option<String> {
    let m = MessageParser::default().parse(raw)?;
    m.parts
        .iter()
        .find(|p| mime_of(p) == "text/calendar")
        .and_then(|p| std::str::from_utf8(contents(p)).ok().map(|s| s.to_string()))
}
