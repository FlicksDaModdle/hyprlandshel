// The local store: accounts (everything but their secrets, which live in
// the keyring), folders, messages with their raw source, a full-text index,
// contacts, templates, snoozes and the outbox.
//
// One SQLite file in ~/.local/share/hyprshell/mail. Opened once and shared
// behind a mutex: every query here is short, and SQLite would serialise the
// writers anyway.

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::path::Path;

pub struct Db {
    pub conn: Connection,
}

const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS accounts (
    id          TEXT PRIMARY KEY,
    data        TEXT NOT NULL,          -- JSON: see account.rs
    position    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS folders (
    account     TEXT NOT NULL,
    path        TEXT NOT NULL,
    name        TEXT NOT NULL,
    delim       TEXT,
    role        TEXT NOT NULL DEFAULT '',   -- inbox sent drafts trash junk archive all flagged
    uidvalidity INTEGER NOT NULL DEFAULT 0,
    unread      INTEGER NOT NULL DEFAULT 0,
    total       INTEGER NOT NULL DEFAULT 0,
    selectable  INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (account, path)
);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY,
    account     TEXT NOT NULL,
    folder      TEXT NOT NULL,
    uid         INTEGER NOT NULL,
    msgid       TEXT NOT NULL DEFAULT '',
    thread      TEXT NOT NULL DEFAULT '',
    subject     TEXT NOT NULL DEFAULT '',
    from_name   TEXT NOT NULL DEFAULT '',
    from_addr   TEXT NOT NULL DEFAULT '',
    to_json     TEXT NOT NULL DEFAULT '[]',
    cc_json     TEXT NOT NULL DEFAULT '[]',
    date        INTEGER NOT NULL DEFAULT 0,
    sort_date   INTEGER NOT NULL DEFAULT 0,  -- date, or when a snooze ended
    snippet     TEXT NOT NULL DEFAULT '',
    seen        INTEGER NOT NULL DEFAULT 0,
    flagged     INTEGER NOT NULL DEFAULT 0,
    answered    INTEGER NOT NULL DEFAULT 0,
    has_att     INTEGER NOT NULL DEFAULT 0,
    invite      INTEGER NOT NULL DEFAULT 0,
    size        INTEGER NOT NULL DEFAULT 0,
    full        INTEGER NOT NULL DEFAULT 0,  -- raw holds the whole message, not just its header
    raw         BLOB,
    UNIQUE (account, folder, uid)
);
CREATE INDEX IF NOT EXISTS messages_folder ON messages (account, folder, sort_date DESC);
CREATE INDEX IF NOT EXISTS messages_thread ON messages (account, thread);
CREATE INDEX IF NOT EXISTS messages_msgid ON messages (msgid);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5 (
    subject, people, body, tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TABLE IF NOT EXISTS contacts (
    email       TEXT PRIMARY KEY COLLATE NOCASE,
    name        TEXT NOT NULL DEFAULT '',
    score       REAL NOT NULL DEFAULT 0,
    last_used   INTEGER NOT NULL DEFAULT 0,
    manual      INTEGER NOT NULL DEFAULT 0,
    hidden      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS templates (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    subject     TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS snoozed (
    message     INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    until       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox (
    id          INTEGER PRIMARY KEY,
    account     TEXT NOT NULL,
    send_at     INTEGER NOT NULL,
    payload     TEXT NOT NULL,          -- the send request, as given
    summary     TEXT NOT NULL DEFAULT '',
    error       TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS drafts (
    id          INTEGER PRIMARY KEY,
    account     TEXT NOT NULL DEFAULT '',
    payload     TEXT NOT NULL,
    updated     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    uid         TEXT PRIMARY KEY,       -- calendar events from accepted invites
    data        TEXT NOT NULL
);
"#;

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// What a message looks like in a list.
pub const SUMMARY_COLS: &str = "m.id, m.account, m.folder, m.uid, m.thread, m.subject, m.from_name, \
     m.from_addr, m.to_json, m.date, m.sort_date, m.snippet, m.seen, m.flagged, m.answered, m.has_att, \
     m.invite, m.msgid";

pub fn summary_row(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, i64>(0)?,
        "account": r.get::<_, String>(1)?,
        "folder": r.get::<_, String>(2)?,
        "uid": r.get::<_, i64>(3)?,
        "thread": r.get::<_, String>(4)?,
        "subject": r.get::<_, String>(5)?,
        "fromName": r.get::<_, String>(6)?,
        "fromAddr": r.get::<_, String>(7)?,
        "to": serde_json::from_str::<Value>(&r.get::<_, String>(8)?).unwrap_or(json!([])),
        "date": r.get::<_, i64>(9)?,
        "sortDate": r.get::<_, i64>(10)?,
        "snippet": r.get::<_, String>(11)?,
        "seen": r.get::<_, i64>(12)? != 0,
        "flagged": r.get::<_, i64>(13)? != 0,
        "answered": r.get::<_, i64>(14)? != 0,
        "attachments": r.get::<_, i64>(15)? != 0,
        "invite": r.get::<_, i64>(16)? != 0,
        "msgid": r.get::<_, String>(17)?,
    }))
}

impl Db {
    pub fn open(path: &Path) -> rusqlite::Result<Db> {
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Db { conn })
    }

    // ── settings ──────────────────────────────────────────────────────────
    pub fn setting(&self, key: &str) -> Option<String> {
        self.conn
            .query_row("SELECT value FROM settings WHERE key = ?", [key], |r| r.get(0))
            .optional()
            .ok()
            .flatten()
    }
    pub fn set_setting(&self, key: &str, value: &str) {
        let _ = self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        );
    }
    pub fn settings(&self) -> Value {
        let mut out = serde_json::Map::new();
        if let Ok(mut st) = self.conn.prepare("SELECT key, value FROM settings") {
            let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)));
            if let Ok(rows) = rows {
                for (k, v) in rows.flatten() {
                    out.insert(k, serde_json::from_str(&v).unwrap_or(Value::String(v)));
                }
            }
        }
        Value::Object(out)
    }

    // ── folders ───────────────────────────────────────────────────────────
    pub fn folder_role(&self, account: &str, role: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT path FROM folders WHERE account = ? AND role = ? LIMIT 1",
                params![account, role],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn folders(&self, account: Option<&str>) -> Vec<Value> {
        let mut out = vec![];
        let sql = "SELECT account, path, name, delim, role, unread, total, selectable FROM folders \
                   WHERE (?1 IS NULL OR account = ?1) ORDER BY account, \
                   CASE role WHEN 'inbox' THEN 0 WHEN 'flagged' THEN 1 WHEN 'drafts' THEN 2 WHEN 'sent' THEN 3 \
                   WHEN 'archive' THEN 4 WHEN 'all' THEN 5 WHEN 'junk' THEN 6 WHEN 'trash' THEN 7 ELSE 8 END, path";
        if let Ok(mut st) = self.conn.prepare(sql) {
            let rows = st.query_map(params![account], |r| {
                Ok(json!({
                    "account": r.get::<_, String>(0)?,
                    "path": r.get::<_, String>(1)?,
                    "name": r.get::<_, String>(2)?,
                    "delim": r.get::<_, Option<String>>(3)?,
                    "role": r.get::<_, String>(4)?,
                    "unread": r.get::<_, i64>(5)?,
                    "total": r.get::<_, i64>(6)?,
                    "selectable": r.get::<_, i64>(7)? != 0,
                }))
            });
            if let Ok(rows) = rows {
                out.extend(rows.flatten());
            }
        }
        out
    }

    /// Unread in every account's inbox, not counting snoozed mail.
    pub fn unread_inbox(&self) -> i64 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages m JOIN folders f ON f.account = m.account AND f.path = m.folder \
                 WHERE f.role = 'inbox' AND m.seen = 0 \
                 AND NOT EXISTS (SELECT 1 FROM snoozed s WHERE s.message = m.id AND s.until > ?)",
                [now()],
                |r| r.get(0),
            )
            .unwrap_or(0)
    }

    pub fn unread_by_account(&self) -> Value {
        let mut out = serde_json::Map::new();
        if let Ok(mut st) = self.conn.prepare(
            "SELECT m.account, COUNT(*) FROM messages m JOIN folders f ON f.account = m.account AND f.path = m.folder \
             WHERE f.role = 'inbox' AND m.seen = 0 GROUP BY m.account",
        ) {
            if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))) {
                for (a, n) in rows.flatten() {
                    out.insert(a, json!(n));
                }
            }
        }
        Value::Object(out)
    }

    // ── messages ──────────────────────────────────────────────────────────
    pub fn message_key(&self, id: i64) -> Option<(String, String, u32)> {
        self.conn
            .query_row("SELECT account, folder, uid FROM messages WHERE id = ?", [id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as u32))
            })
            .optional()
            .ok()
            .flatten()
    }

    pub fn delete_message(&self, id: i64) {
        let _ = self.conn.execute("DELETE FROM messages_fts WHERE rowid = ?", [id]);
        let _ = self.conn.execute("DELETE FROM messages WHERE id = ?", [id]);
    }

    pub fn known_uids(&self, account: &str, folder: &str) -> Vec<(u32, i64)> {
        let mut out = vec![];
        if let Ok(mut st) = self.conn.prepare("SELECT uid, id FROM messages WHERE account = ? AND folder = ?") {
            if let Ok(rows) = st.query_map(params![account, folder], |r| {
                Ok((r.get::<_, i64>(0)? as u32, r.get::<_, i64>(1)?))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    /// The thread a message belongs to: the thread of anything it refers to
    /// that is already here, or else the first message it refers to, or
    /// itself.
    pub fn thread_for(&self, account: &str, refs: &[String], own: &str) -> String {
        for r in refs.iter().rev() {
            if let Ok(Some(t)) = self
                .conn
                .query_row(
                    "SELECT thread FROM messages WHERE account = ? AND msgid = ? LIMIT 1",
                    params![account, r],
                    |row| row.get::<_, String>(0),
                )
                .optional()
            {
                if !t.is_empty() {
                    return t;
                }
            }
        }
        if let Some(first) = refs.first() {
            return first.clone();
        }
        if !own.is_empty() {
            own.to_string()
        } else {
            format!("local-{}", rand::random::<u64>())
        }
    }

    pub fn remember_contact(&self, email: &str, name: &str, weight: f64) {
        let email = email.trim();
        if email.is_empty() || !email.contains('@') {
            return;
        }
        let lower = email.to_ascii_lowercase();
        if lower.contains("noreply") || lower.contains("no-reply") || lower.contains("donotreply") {
            return;
        }
        let _ = self.conn.execute(
            "INSERT INTO contacts (email, name, score, last_used) VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(email) DO UPDATE SET score = score + excluded.score, \
             last_used = MAX(last_used, excluded.last_used), \
             name = CASE WHEN contacts.manual = 1 OR excluded.name = '' THEN contacts.name ELSE excluded.name END",
            params![email, name.trim(), weight, now()],
        );
    }
}
