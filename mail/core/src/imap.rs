// IMAP: connecting and signing in, keeping a cache of each folder, IDLE for
// mail the moment it arrives, and the actions (flags, moves, deletes).
//
// Each account has two connections: one that waits in IDLE on the inbox,
// and one that syncs and carries out actions, taking turns behind a lock.
//
// What is kept: the last `sync_days` days of every folder (60 by default),
// up to 2000 messages a folder; whole messages up to 512 KB, headers only
// above that (the rest is fetched when opened). Gmail's All Mail and
// Starred are left out — they are other views of the same mail.

use crate::account::Account;
use crate::db::{self, now};
use crate::oauth;
use crate::parse;
use crate::secrets;
use crate::state::{AccountRt, State};
use async_imap::types::{Fetch, Flag, NameAttribute};
use futures::TryStreamExt;
use rusqlite::params;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

// ── the connection ────────────────────────────────────────────────────────
#[derive(Debug)]
pub enum Conn {
    Plain(TcpStream),
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl AsyncRead for Conn {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Conn::Plain(s) => Pin::new(s).poll_read(cx, buf),
            Conn::Tls(s) => Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}
impl AsyncWrite for Conn {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Conn::Plain(s) => Pin::new(s).poll_write(cx, buf),
            Conn::Tls(s) => Pin::new(s.as_mut()).poll_write(cx, buf),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Conn::Plain(s) => Pin::new(s).poll_flush(cx),
            Conn::Tls(s) => Pin::new(s.as_mut()).poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Conn::Plain(s) => Pin::new(s).poll_shutdown(cx),
            Conn::Tls(s) => Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
}

pub type Session = async_imap::Session<Conn>;

pub fn tls_config() -> Arc<rustls::ClientConfig> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    for c in rustls_native_certs::load_native_certs().certs {
        let _ = roots.add(c);
    }
    Arc::new(rustls::ClientConfig::builder().with_root_certificates(roots).with_no_client_auth())
}

async fn tls(host: &str, tcp: TcpStream) -> Result<Conn, String> {
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|e| e.to_string())?;
    let s = tokio_rustls::TlsConnector::from(tls_config())
        .connect(name, tcp)
        .await
        .map_err(|e| format!("Secure connection to {} failed: {}", host, e))?;
    Ok(Conn::Tls(Box::new(s)))
}

pub enum Auth {
    Password(String),
    OAuth(String),
}

struct XOAuth2(String, u32);
impl async_imap::Authenticator for XOAuth2 {
    type Response = String;
    fn process(&mut self, _challenge: &[u8]) -> String {
        self.1 += 1;
        // A second challenge is the server's error report; it wants an
        // empty answer before it says no.
        if self.1 == 1 {
            self.0.clone()
        } else {
            String::new()
        }
    }
}

fn friendly(e: impl std::fmt::Display) -> String {
    let s = e.to_string();
    if s.contains("AUTHENTICATIONFAILED") || s.contains("Invalid credentials") || s.contains("LOGIN failed") {
        "The server refused the password. For Gmail, use an app password (Google Account → Security → App passwords)."
            .to_string()
    } else {
        s
    }
}

/// The credentials to sign in with: the password from the keyring, or a
/// current access token.
pub async fn credentials(state: &State, a: &Account) -> Result<Auth, String> {
    if a.auth == "oauth" {
        {
            let tokens = state.tokens.lock().await;
            if let Some((t, exp)) = tokens.get(&a.id) {
                if *exp > now() {
                    return Ok(Auth::OAuth(t.clone()));
                }
            }
        }
        let (cid, secret) = oauth_client(state, &a.oauth_provider);
        let t = oauth::refresh(&a.id, &a.oauth_provider, &cid, &secret).await?;
        state.tokens.lock().await.insert(a.id.clone(), (t.access.clone(), t.expires));
        Ok(Auth::OAuth(t.access))
    } else {
        let p = secrets::load(&a.id, "password").await?.ok_or("No password saved for this account")?;
        Ok(Auth::Password(p))
    }
}

pub fn oauth_client(state: &State, provider: &str) -> (String, String) {
    let db = state.db.lock().unwrap();
    (
        db.setting(&format!("oauth.{}.clientId", provider)).map(|s| s.trim_matches('"').to_string()).unwrap_or_default(),
        db.setting(&format!("oauth.{}.clientSecret", provider)).map(|s| s.trim_matches('"').to_string()).unwrap_or_default(),
    )
}

pub struct Imap {
    pub sess: Session,
    pub selected: Option<String>,
    pub can_move: bool,
    pub can_idle: bool,
}

pub async fn open(a: &Account, auth: &Auth) -> Result<Imap, String> {
    let host = a.imap_host.trim();
    if host.is_empty() {
        return Err("No IMAP server set".into());
    }
    let tcp = tokio::time::timeout(Duration::from_secs(20), TcpStream::connect((host, a.imap_port)))
        .await
        .map_err(|_| format!("{} did not answer", host))?
        .map_err(|e| {
            let s = e.to_string();
            if s.contains("lookup address") || s.contains("not known") || s.contains("No address") {
                format!("There is no server called {}. If this address's mail is on Microsoft 365 (Outlook) or Google, go Back and pick Microsoft or Google instead.", host)
            } else {
                format!("Could not reach {}: {}", host, s)
            }
        })?;
    let _ = tcp.set_nodelay(true);
    let client = match a.imap_security.as_str() {
        "starttls" => {
            let mut c = async_imap::Client::new(Conn::Plain(tcp));
            c.read_response().await.map_err(|e| e.to_string())?;
            c.run_command_and_check_ok("STARTTLS", None).await.map_err(|e| format!("STARTTLS: {}", e))?;
            let Conn::Plain(tcp) = c.into_inner() else { unreachable!() };
            async_imap::Client::new(tls(host, tcp).await?)
        }
        "none" => {
            if !Account::is_local_host(host) {
                return Err("An unencrypted connection is only allowed to this computer".into());
            }
            let mut c = async_imap::Client::new(Conn::Plain(tcp));
            c.read_response().await.map_err(|e| e.to_string())?;
            c
        }
        _ => {
            let mut c = async_imap::Client::new(tls(host, tcp).await?);
            c.read_response().await.map_err(|e| e.to_string())?;
            c
        }
    };
    let mut sess = match auth {
        Auth::Password(p) => client.login(a.login(), p).await.map_err(|(e, _)| friendly(e))?,
        Auth::OAuth(t) => client
            .authenticate("XOAUTH2", XOAuth2(oauth::xoauth2(a.login(), t), 0))
            .await
            .map_err(|(e, _)| friendly(e))?,
    };
    let caps = sess.capabilities().await.map_err(|e| e.to_string())?;
    Ok(Imap {
        can_move: caps.has_str("MOVE"),
        can_idle: caps.has_str("IDLE"),
        sess,
        selected: None,
    })
}

impl Imap {
    pub async fn select(&mut self, folder: &str) -> Result<async_imap::types::Mailbox, String> {
        let mb = self.sess.select(folder).await.map_err(|e| format!("{}: {}", folder, e))?;
        self.selected = Some(folder.to_string());
        Ok(mb)
    }
    async fn ensure(&mut self, folder: &str) -> Result<(), String> {
        if self.selected.as_deref() != Some(folder) {
            self.select(folder).await?;
        }
        Ok(())
    }

    pub async fn store(&mut self, folder: &str, uids: &[u32], what: &str) -> Result<(), String> {
        self.ensure(folder).await?;
        let s = self.sess.uid_store(set(uids), what).await.map_err(|e| e.to_string())?;
        let _: Vec<Fetch> = s.try_collect().await.map_err(|e| e.to_string())?;
        Ok(())
    }

    pub async fn move_to(&mut self, folder: &str, uids: &[u32], dest: &str) -> Result<(), String> {
        self.ensure(folder).await?;
        let s = set(uids);
        if self.can_move {
            self.sess.uid_mv(&s, dest).await.map_err(|e| e.to_string())?;
        } else {
            self.sess.uid_copy(&s, dest).await.map_err(|e| e.to_string())?;
            self.store(folder, uids, "+FLAGS.SILENT (\\Deleted)").await?;
            let st = self.sess.uid_expunge(&s).await.map_err(|e| e.to_string())?;
            let _: Vec<_> = st.try_collect().await.map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub async fn delete_forever(&mut self, folder: &str, uids: &[u32]) -> Result<(), String> {
        self.store(folder, uids, "+FLAGS.SILENT (\\Deleted)").await?;
        let st = self.sess.uid_expunge(set(uids)).await.map_err(|e| e.to_string())?;
        let _: Vec<_> = st.try_collect().await.map_err(|e| e.to_string())?;
        Ok(())
    }

    pub async fn fetch_raw(&mut self, folder: &str, uid: u32) -> Result<Vec<u8>, String> {
        self.ensure(folder).await?;
        let st = self.sess.uid_fetch(uid.to_string(), "(UID BODY.PEEK[])").await.map_err(|e| e.to_string())?;
        let v: Vec<Fetch> = st.try_collect().await.map_err(|e| e.to_string())?;
        v.into_iter()
            .find_map(|f| f.body().map(|b| b.to_vec()))
            .ok_or_else(|| "The server no longer has this message".to_string())
    }

    pub async fn append(&mut self, folder: &str, flags: &str, raw: &[u8]) -> Result<(), String> {
        self.sess.append(folder, Some(flags), None, raw).await.map_err(|e| e.to_string())
    }
}

/// A UID set, with runs as ranges: 1,2,3,7 → 1:3,7.
pub fn set(uids: &[u32]) -> String {
    let mut v: Vec<u32> = uids.to_vec();
    v.sort_unstable();
    v.dedup();
    let mut out: Vec<String> = vec![];
    let mut i = 0;
    while i < v.len() {
        let start = v[i];
        let mut end = start;
        while i + 1 < v.len() && v[i + 1] == end + 1 {
            i += 1;
            end = v[i];
        }
        out.push(if start == end { start.to_string() } else { format!("{}:{}", start, end) });
        i += 1;
    }
    out.join(",")
}

// ── connecting, for the sync loop and for actions ─────────────────────────
pub async fn session<'a>(state: &'a State, rt: &'a AccountRt) -> Result<tokio::sync::MutexGuard<'a, Option<Imap>>, String> {
    let mut g = rt.imap.lock().await;
    if let Some(i) = g.as_mut() {
        if i.sess.noop().await.is_ok() {
            return Ok(g);
        }
        *g = None;
    }
    let a = rt.account();
    let auth = credentials(state, &a).await?;
    *g = Some(open(&a, &auth).await?);
    Ok(g)
}

// ── folders ───────────────────────────────────────────────────────────────
fn role_for(name: &str, attrs: &[NameAttribute]) -> &'static str {
    for a in attrs {
        match a {
            NameAttribute::Sent => return "sent",
            NameAttribute::Drafts => return "drafts",
            NameAttribute::Trash => return "trash",
            NameAttribute::Junk => return "junk",
            NameAttribute::Archive => return "archive",
            NameAttribute::All => return "all",
            NameAttribute::Flagged => return "flagged",
            _ => {}
        }
    }
    let leaf = name.rsplit(['/', '.']).next().unwrap_or(name).to_ascii_lowercase();
    if name.eq_ignore_ascii_case("INBOX") {
        return "inbox";
    }
    match leaf.as_str() {
        "sent" | "sent items" | "sent mail" | "sent messages" => "sent",
        "drafts" | "draft" => "drafts",
        "trash" | "deleted items" | "deleted messages" | "bin" => "trash",
        "junk" | "spam" | "junk email" | "junk e-mail" => "junk",
        "archive" | "archives" => "archive",
        _ => "",
    }
}

async fn list_folders(state: &State, rt: &AccountRt) -> Result<Vec<(String, String)>, String> {
    let id = rt.id();
    let mut g = session(state, rt).await?;
    let imap = g.as_mut().unwrap();
    let names: Vec<_> = imap
        .sess
        .list(Some(""), Some("*"))
        .await
        .map_err(|e| e.to_string())?
        .try_collect()
        .await
        .map_err(|e| e.to_string())?;
    drop(g);
    let mut out = vec![];
    let db = state.db.lock().unwrap();
    let mut seen = HashSet::new();
    for n in &names {
        let path = n.name().to_string();
        let selectable = !n.attributes().iter().any(|a| matches!(a, NameAttribute::NoSelect));
        let role = role_for(&path, n.attributes());
        let shown = path.rsplit(n.delimiter().unwrap_or("/")).next().unwrap_or(&path).to_string();
        let shown = if path.eq_ignore_ascii_case("INBOX") { "Inbox".to_string() } else { shown };
        let _ = db.conn.execute(
            "INSERT INTO folders (account, path, name, delim, role, selectable) VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(account, path) DO UPDATE SET name = excluded.name, delim = excluded.delim, \
             role = excluded.role, selectable = excluded.selectable",
            params![id, path, shown, n.delimiter(), role, selectable as i64],
        );
        seen.insert(path.clone());
        let lower = path.to_ascii_lowercase();
        let skip = role == "all" || role == "flagged" || !selectable || lower == "[gmail]/important" || lower == "[gmail]";
        if !skip {
            out.push((path, role.to_string()));
        }
    }
    // Folders gone from the server.
    let known: Vec<String> = {
        let mut st = db.conn.prepare("SELECT path FROM folders WHERE account = ?").map_err(|e| e.to_string())?;
        let rows = st.query_map([&id], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?;
        rows.flatten().collect()
    };
    for k in known.into_iter().filter(|k| !seen.contains(k)) {
        let _ = db.conn.execute("DELETE FROM folders WHERE account = ? AND path = ?", params![id, k]);
        let _ = db.conn.execute(
            "DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE account = ? AND folder = ?)",
            params![id, k],
        );
        let _ = db.conn.execute("DELETE FROM messages WHERE account = ? AND folder = ?", params![id, k]);
    }
    // The inbox first, then what is looked at most.
    let rank = |r: &str| match r {
        "inbox" => 0,
        "sent" => 1,
        "drafts" => 2,
        "archive" => 3,
        "" => 4,
        "junk" => 5,
        _ => 6,
    };
    out.sort_by_key(|(_, r)| rank(r));
    Ok(out)
}

// ── keeping a folder ──────────────────────────────────────────────────────
pub fn insert_message(state: &State, account: &str, folder: &str, uid: u32, flags: &[Flag], raw: &[u8], full: bool, size: u32) -> Option<(i64, parse::Summary)> {
    let s = parse::summarize(raw)?;
    let db = state.db.lock().unwrap();
    let thread = db.thread_for(account, &s.refs, &s.msgid);
    let has = |f: &Flag| flags.iter().any(|x| std::mem::discriminant(x) == std::mem::discriminant(f));
    let date = if s.date > 0 { s.date } else { now() };
    let people = format!(
        "{} {} {}",
        s.from_name,
        s.from_addr,
        s.to.iter().map(|(n, a)| format!("{} {}", n, a)).collect::<Vec<_>>().join(" ")
    );
    let r = db.conn.execute(
        "INSERT INTO messages (account, folder, uid, msgid, thread, subject, from_name, from_addr, to_json, cc_json, \
         date, sort_date, snippet, seen, flagged, answered, has_att, invite, size, full, raw) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20) \
         ON CONFLICT(account, folder, uid) DO UPDATE SET raw = excluded.raw, full = excluded.full, \
         has_att = excluded.has_att, invite = excluded.invite, snippet = excluded.snippet",
        params![
            account, folder, uid, s.msgid, thread, s.subject, s.from_name, s.from_addr,
            parse::addrs_json(&s.to).to_string(), parse::addrs_json(&s.cc).to_string(),
            date, s.snippet, has(&Flag::Seen) as i64, has(&Flag::Flagged) as i64, has(&Flag::Answered) as i64,
            s.has_att as i64, s.invite as i64, size, full as i64, raw
        ],
    );
    if r.is_err() {
        return None;
    }
    let id: i64 = db
        .conn
        .query_row(
            "SELECT id FROM messages WHERE account = ? AND folder = ? AND uid = ?",
            params![account, folder, uid],
            |r| r.get(0),
        )
        .ok()?;
    let _ = db.conn.execute("DELETE FROM messages_fts WHERE rowid = ?", [id]);
    let _ = db.conn.execute(
        "INSERT INTO messages_fts (rowid, subject, people, body) VALUES (?, ?, ?, ?)",
        params![id, s.subject, people, s.body],
    );
    db.remember_contact(&s.from_addr, &s.from_name, 0.2);
    Some((id, s))
}

fn flag_bits(f: &Fetch) -> (bool, bool, bool) {
    let mut seen = false;
    let mut flagged = false;
    let mut answered = false;
    for x in f.flags() {
        match x {
            Flag::Seen => seen = true,
            Flag::Flagged => flagged = true,
            Flag::Answered => answered = true,
            _ => {}
        }
    }
    (seen, flagged, answered)
}

const BODY_LIMIT: u32 = 512 * 1024;
const PER_FOLDER: usize = 2000;

/// Brings one folder's cache up to date. Returns the new unread messages,
/// for notifications.
pub async fn sync_folder(state: &State, rt: &AccountRt, folder: &str) -> Result<Vec<(i64, parse::Summary)>, String> {
    let a = rt.account();
    let id = a.id.clone();
    let mut g = session(state, rt).await?;
    let imap = g.as_mut().unwrap();
    let mb = imap.select(folder).await?;
    let validity = mb.uid_validity.unwrap_or(0);
    {
        let db = state.db.lock().unwrap();
        let old: i64 = db
            .conn
            .query_row("SELECT uidvalidity FROM folders WHERE account = ? AND path = ?", params![id, folder], |r| r.get(0))
            .unwrap_or(0);
        if old != 0 && old != validity as i64 {
            // The server renumbered the folder: start it again.
            let _ = db.conn.execute(
                "DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE account = ? AND folder = ?)",
                params![id, folder],
            );
            let _ = db.conn.execute("DELETE FROM messages WHERE account = ? AND folder = ?", params![id, folder]);
        }
        let _ = db.conn.execute(
            "UPDATE folders SET uidvalidity = ?, total = ? WHERE account = ? AND path = ?",
            params![validity, mb.exists, id, folder],
        );
    }

    let since = (chrono::Utc::now() - chrono::Duration::days(a.sync_days.max(1) as i64)).format("%d-%b-%Y").to_string();
    let window: Vec<u32> = if mb.exists == 0 {
        vec![]
    } else {
        let mut w: Vec<u32> = imap
            .sess
            .uid_search(format!("SINCE {}", since))
            .await
            .map_err(|e| e.to_string())?
            .into_iter()
            .collect();
        w.sort_unstable_by(|a, b| b.cmp(a));
        w.truncate(PER_FOLDER);
        w
    };
    let unread_total = if mb.exists == 0 {
        0
    } else {
        imap.sess.uid_search("UNSEEN").await.map(|s| s.len()).unwrap_or(0)
    };

    let known: HashMap<u32, i64> = state.db.lock().unwrap().known_uids(&id, folder).into_iter().collect();

    // What the server no longer has.
    let present: HashSet<u32> = if known.is_empty() {
        HashSet::new()
    } else {
        let ks: Vec<u32> = known.keys().copied().collect();
        imap.sess.uid_search(format!("UID {}", set(&ks))).await.map_err(|e| e.to_string())?
    };
    let gone: Vec<i64> = known.iter().filter(|(u, _)| !present.contains(u)).map(|(_, id)| *id).collect();
    // What has fallen out of the window keeps, until it is deleted: the
    // cache only grows by the window, it never forgets what it has.

    // New mail.
    let wanted: Vec<u32> = window.iter().copied().filter(|u| !known.contains_key(u)).collect();
    let mut fresh = vec![];
    for chunk in wanted.chunks(100) {
        let sizes: Vec<Fetch> = imap
            .sess
            .uid_fetch(set(chunk), "(UID RFC822.SIZE)")
            .await
            .map_err(|e| e.to_string())?
            .try_collect()
            .await
            .map_err(|e| e.to_string())?;
        let mut small = vec![];
        let mut big = vec![];
        for f in &sizes {
            if let Some(u) = f.uid {
                if f.size.unwrap_or(0) <= BODY_LIMIT {
                    small.push(u)
                } else {
                    big.push(u)
                }
            }
        }
        for (uids, query, full) in [(small, "(UID FLAGS RFC822.SIZE BODY.PEEK[])", true), (big, "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER])", false)] {
            for part in uids.chunks(25) {
                let got: Vec<Fetch> = imap
                    .sess
                    .uid_fetch(set(part), query)
                    .await
                    .map_err(|e| e.to_string())?
                    .try_collect()
                    .await
                    .map_err(|e| e.to_string())?;
                for f in got {
                    let Some(uid) = f.uid else { continue };
                    let raw = if full { f.body() } else { f.header() };
                    let Some(raw) = raw else { continue };
                    let flags: Vec<Flag> = f.flags().map(|x| match x {
                        Flag::Seen => Flag::Seen,
                        Flag::Flagged => Flag::Flagged,
                        Flag::Answered => Flag::Answered,
                        _ => Flag::Recent,
                    }).collect();
                    if let Some((mid, s)) = insert_message(state, &id, folder, uid, &flags, raw, full, f.size.unwrap_or(0)) {
                        let seen = flags.iter().any(|x| matches!(x, Flag::Seen));
                        if !seen {
                            fresh.push((mid, s));
                        }
                    }
                }
            }
        }
        state.emit("changed", json!({ "account": id, "folder": folder }));
    }

    // Flags of what is already here.
    let keep: Vec<u32> = known.keys().copied().filter(|u| present.contains(u)).collect();
    let mut flag_changes = 0;
    for chunk in keep.chunks(500) {
        let got: Vec<Fetch> = imap
            .sess
            .uid_fetch(set(chunk), "(UID FLAGS)")
            .await
            .map_err(|e| e.to_string())?
            .try_collect()
            .await
            .map_err(|e| e.to_string())?;
        let db = state.db.lock().unwrap();
        for f in got {
            let Some(uid) = f.uid else { continue };
            let (s, fl, an) = flag_bits(&f);
            flag_changes += db
                .conn
                .execute(
                    "UPDATE messages SET seen = ?1, flagged = ?2, answered = ?3 WHERE account = ?4 AND folder = ?5 AND uid = ?6 \
                     AND (seen != ?1 OR flagged != ?2 OR answered != ?3)",
                    params![s as i64, fl as i64, an as i64, id, folder, uid],
                )
                .unwrap_or(0);
        }
    }
    drop(g);

    {
        let db = state.db.lock().unwrap();
        for m in &gone {
            db.delete_message(*m);
        }
        let _ = db.conn.execute(
            "UPDATE folders SET unread = ? WHERE account = ? AND path = ?",
            params![unread_total as i64, id, folder],
        );
    }
    if !gone.is_empty() || flag_changes > 0 {
        state.emit("changed", json!({ "account": id, "folder": folder }));
    }
    Ok(fresh)
}

// ── the loops ─────────────────────────────────────────────────────────────
pub fn start(state: Arc<State>, rt: Arc<AccountRt>) {
    rt.stop();
    if !rt.account().enabled {
        state.set_status(&rt, "off", "");
        return;
    }
    let s1 = state.clone();
    let r1 = rt.clone();
    let sync = tokio::spawn(async move { sync_loop(s1, r1).await });
    let s2 = state.clone();
    let r2 = rt.clone();
    let idle = tokio::spawn(async move { idle_loop(s2, r2).await });
    rt.tasks.lock().unwrap().extend([sync, idle]);
}

async fn sync_once(state: &State, rt: &AccountRt, inbox_only: bool) -> Result<(), String> {
    let folders = list_folders(state, rt).await?;
    let id = rt.id();
    for (path, role) in folders {
        if inbox_only && role != "inbox" {
            continue;
        }
        let fresh = sync_folder(state, rt, &path).await?;
        if role == "inbox" {
            let primed = *rt.primed.lock().unwrap();
            if primed && !fresh.is_empty() {
                announce(state, &id, &fresh);
            }
            *rt.primed.lock().unwrap() = true;
            state.emit_unread();
        }
        if inbox_only {
            break;
        }
    }
    state.emit("folders", json!({ "account": id }));
    Ok(())
}

async fn sync_loop(state: Arc<State>, rt: Arc<AccountRt>) {
    let mut backoff = 15u64;
    let mut inbox_only = false;
    loop {
        state.set_status(&rt, "syncing", "");
        match sync_once(&state, &rt, inbox_only).await {
            Ok(()) => {
                backoff = 15;
                state.set_status(&rt, "idle", "");
            }
            Err(e) => {
                let signin = e.contains("Signed out") || e.contains("refused the password") || e.contains("No password");
                state.set_status(&rt, if signin { "signin" } else { "error" }, &e);
                *rt.imap.lock().await = None;
                let wait = if signin { 3600 } else { backoff };
                backoff = (backoff * 2).min(600);
                tokio::select! {
                    _ = rt.wake.notified() => {}
                    _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
                }
                inbox_only = false;
                continue;
            }
        }
        // Everything every five minutes; the inbox when IDLE says so.
        tokio::select! {
            _ = rt.wake.notified() => {
                inbox_only = std::mem::take(&mut *rt.inbox_only.lock().unwrap());
            }
            _ = tokio::time::sleep(Duration::from_secs(300)) => { inbox_only = false; }
        }
    }
}

async fn idle_loop(state: Arc<State>, rt: Arc<AccountRt>) {
    // Give the first sync a head start.
    tokio::time::sleep(Duration::from_secs(5)).await;
    loop {
        let a = rt.account();
        let result: Result<(), String> = async {
            let auth = credentials(&state, &a).await?;
            let mut imap = open(&a, &auth).await?;
            if !imap.can_idle {
                // No IDLE: look at the inbox every minute instead.
                loop {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    *rt.inbox_only.lock().unwrap() = true;
                    rt.wake.notify_one();
                }
            }
            imap.select("INBOX").await?;
            // Whatever arrived since the last look and before this
            // connection was listening: IDLE only reports what comes next.
            *rt.inbox_only.lock().unwrap() = true;
            rt.wake.notify_one();
            let mut sess = imap.sess;
            loop {
                let mut h = sess.idle();
                h.init().await.map_err(|e| e.to_string())?;
                let r = {
                    let (fut, _stop) = h.wait_with_timeout(Duration::from_secs(25 * 60));
                    fut.await.map_err(|e| e.to_string())?
                };
                sess = h.done().await.map_err(|e| e.to_string())?;
                if let async_imap::extensions::idle::IdleResponse::NewData(_) = r {
                    *rt.inbox_only.lock().unwrap() = true;
                    rt.wake.notify_one();
                }
            }
        }
        .await;
        if let Err(_e) = result {
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
    }
}

/// Mail's icon for notifications: the PNG installed beside this program
/// (…/bin → …/share/icons), by path, so it shows whatever the notification
/// server can or can't draw; else the icon's name.
pub fn notify_icon() -> String {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(prefix) = exe.parent().and_then(|b| b.parent()) {
            let p = prefix.join("share/icons/hicolor/256x256/apps/hyprshell-mail.png");
            if p.exists() {
                return p.to_string_lossy().to_string();
            }
        }
    }
    "hyprshell-mail".to_string()
}

/// New mail: a notification per message, or one for several.
fn announce(state: &State, account: &str, fresh: &[(i64, parse::Summary)]) {
    let recent: Vec<&(i64, parse::Summary)> = fresh.iter().filter(|(_, s)| s.date > now() - 86400).collect();
    if recent.is_empty() {
        return;
    }
    state.emit(
        "newMail",
        json!({
            "account": account,
            "messages": recent.iter().map(|(id, s)| json!({
                "id": id, "from": if s.from_name.is_empty() { &s.from_addr } else { &s.from_name },
                "subject": s.subject, "snippet": s.snippet,
            })).collect::<Vec<_>>(),
        }),
    );
    let notify = state.db.lock().unwrap().setting("notify").map(|v| v != "false").unwrap_or(true);
    if !notify {
        return;
    }
    let (title, body, id) = if recent.len() == 1 {
        let (id, s) = recent[0];
        let who = if s.from_name.is_empty() { s.from_addr.clone() } else { s.from_name.clone() };
        (who, format!("{}\n{}", s.subject, s.snippet.chars().take(120).collect::<String>()), Some(*id))
    } else {
        (format!("{} new messages", recent.len()), recent.iter().take(4).map(|(_, s)| s.subject.clone()).collect::<Vec<_>>().join("\n"), None)
    };
    tokio::spawn(async move {
        let mut cmd = tokio::process::Command::new("notify-send");
        let icon = notify_icon();
        cmd.args(["-a", "Mail", "-i", &icon, "-h", "string:desktop-entry:hyprshell-mail", "-A", "open=Open", "--wait", &title, &body]);
        cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
        if let Ok(out) = cmd.output().await {
            if String::from_utf8_lossy(&out.stdout).trim() == "open" {
                let mut open = tokio::process::Command::new("hyprshell-mail");
                if let Some(id) = id {
                    open.arg(format!("--message={}", id));
                }
                let _ = open.spawn();
            }
        }
    });
}

pub fn summary_of(state: &State, id: i64) -> Option<serde_json::Value> {
    let db = state.db.lock().unwrap();
    db.conn
        .query_row(&format!("SELECT {} FROM messages m WHERE m.id = ?", db::SUMMARY_COLS), [id], db::summary_row)
        .ok()
}
