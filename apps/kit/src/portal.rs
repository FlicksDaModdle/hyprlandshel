//! The desktop's own file chooser, through xdg-desktop-portal — the same
//! dialog every other app gets (the shell has its own portal backend), so
//! the Rust apps need no file dialog of their own.
//!
//! Blocking: call from a worker thread (kit::spawn).

use std::collections::HashMap;
use std::path::PathBuf;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedValue, Value};

/// A filter: a name and its glob patterns, e.g. ("PDF", &["*.pdf"]).
pub type Filter<'a> = (&'a str, &'a [&'a str]);

fn chooser(method: &str, title: &str, filters: &[Filter], folder: bool, multiple: bool) -> Vec<PathBuf> {
    chooser_with(method, title, filters, folder, multiple, None, None)
}

fn chooser_with(
    method: &str,
    title: &str,
    filters: &[Filter],
    folder: bool,
    multiple: bool,
    name: Option<&str>,
    in_folder: Option<&std::path::Path>,
) -> Vec<PathBuf> {
    let Ok(conn) = Connection::session() else { return Vec::new() };
    let token = format!("hyprshell{}", std::process::id());
    let mut opts: HashMap<&str, Value> = HashMap::new();
    opts.insert("handle_token", Value::from(token.clone()));
    opts.insert("modal", Value::from(true));
    if multiple {
        opts.insert("multiple", Value::from(true));
    }
    if folder {
        opts.insert("directory", Value::from(true));
    }
    if let Some(n) = name {
        opts.insert("current_name", Value::from(n.to_string()));
    }
    // A byte string with its NUL, as the spec has it.
    if let Some(d) = in_folder {
        use std::os::unix::ffi::OsStrExt;
        let mut b = d.as_os_str().as_bytes().to_vec();
        b.push(0);
        opts.insert("current_folder", Value::from(b));
    }
    if !filters.is_empty() {
        let list: Vec<(String, Vec<(u32, String)>)> = filters
            .iter()
            .map(|(name, globs)| (name.to_string(), globs.iter().map(|g| (0u32, g.to_string())).collect()))
            .collect();
        opts.insert("filters", Value::from(list));
    }
    // Listen before asking: the answer can come before the call returns.
    let sender = conn.unique_name().map(|n| n.trim_start_matches(':').replace('.', "_")).unwrap_or_default();
    let handle = format!("/org/freedesktop/portal/desktop/request/{sender}/{token}");
    let Ok(rule) = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.freedesktop.portal.Request")
        .and_then(|b| b.member("Response"))
        .and_then(|b| b.path(handle.as_str()))
        .map(|b| b.build())
    else {
        return Vec::new();
    };
    let Ok(mut iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(4)) else { return Vec::new() };
    let r = conn.call_method(
        Some("org.freedesktop.portal.Desktop"),
        "/org/freedesktop/portal/desktop",
        Some("org.freedesktop.portal.FileChooser"),
        method,
        &("", title, opts),
    );
    if r.is_err() {
        return Vec::new();
    }
    let Some(Ok(msg)) = iter.next() else { return Vec::new() };
    let Ok((code, results)) = msg.body().deserialize::<(u32, HashMap<String, OwnedValue>)>() else { return Vec::new() };
    if code != 0 {
        return Vec::new();
    }
    let uris: Vec<String> = results.get("uris").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default();
    uris.iter().filter_map(|u| uri_to_path(u)).collect()
}

/// file:///home/you/My%20File.pdf → /home/you/My File.pdf
pub fn uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?, 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    use std::os::unix::ffi::OsStringExt;
    Some(PathBuf::from(std::ffi::OsString::from_vec(out)))
}

/// One file to open, or None if the dialog was closed.
pub fn open_file(title: &str, filters: &[Filter]) -> Option<PathBuf> {
    chooser("OpenFile", title, filters, false, false).into_iter().next()
}

/// Several files to open.
pub fn open_files(title: &str, filters: &[Filter]) -> Vec<PathBuf> {
    chooser("OpenFile", title, filters, false, true)
}

/// A folder.
pub fn open_folder(title: &str) -> Option<PathBuf> {
    chooser("OpenFile", title, &[], true, false).into_iter().next()
}

/// Where to save a file: the chooser opened on `folder`, offering `name`.
pub fn save_file(title: &str, name: &str, folder: Option<&std::path::Path>) -> Option<PathBuf> {
    chooser_with("SaveFile", title, &[], false, false, Some(name), folder).into_iter().next()
}
