// What the daemon holds while it runs: the store, the accounts and their
// connections, sign-in tokens in memory, and the channel events go out on.

use crate::account::Account;
use crate::db::Db;
use crate::imap::Imap;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::{broadcast, Notify, RwLock};
use tokio::task::JoinHandle;

pub struct AccountRt {
    pub acct: Mutex<Account>,
    /// The connection syncs and actions take turns on.
    pub imap: tokio::sync::Mutex<Option<Imap>>,
    /// Ask the sync loop to go round now; `inbox_only` for what IDLE saw.
    pub wake: Notify,
    pub inbox_only: Mutex<bool>,
    /// idle | syncing | error | offline | signin
    pub status: Mutex<String>,
    pub error: Mutex<String>,
    pub tasks: Mutex<Vec<JoinHandle<()>>>,
    /// The inbox has been through one sync: new mail after that is news.
    pub primed: Mutex<bool>,
}

impl AccountRt {
    pub fn new(a: Account) -> Self {
        AccountRt {
            acct: Mutex::new(a),
            imap: tokio::sync::Mutex::new(None),
            wake: Notify::new(),
            inbox_only: Mutex::new(false),
            status: Mutex::new("offline".into()),
            error: Mutex::new(String::new()),
            tasks: Mutex::new(vec![]),
            primed: Mutex::new(false),
        }
    }
    pub fn account(&self) -> Account {
        self.acct.lock().unwrap().clone()
    }
    pub fn id(&self) -> String {
        self.acct.lock().unwrap().id.clone()
    }
    pub fn stop(&self) {
        for t in self.tasks.lock().unwrap().drain(..) {
            t.abort();
        }
    }
}

pub struct State {
    pub db: Mutex<Db>,
    pub accounts: RwLock<HashMap<String, Arc<AccountRt>>>,
    pub events: broadcast::Sender<String>,
    /// Access tokens: account → (token, expires at).
    pub tokens: tokio::sync::Mutex<HashMap<String, (String, i64)>>,
    pub cache_dir: PathBuf,
}

impl State {
    pub fn emit(&self, event: &str, mut data: Value) {
        if let Value::Object(ref mut m) = data {
            m.insert("event".into(), json!(event));
        } else {
            data = json!({ "event": event, "data": data });
        }
        let _ = self.events.send(data.to_string());
    }

    pub fn set_status(&self, rt: &AccountRt, status: &str, error: &str) {
        let changed = {
            let mut s = rt.status.lock().unwrap();
            let mut e = rt.error.lock().unwrap();
            let changed = *s != status || *e != error;
            *s = status.to_string();
            *e = error.to_string();
            changed
        };
        if changed {
            self.emit("status", json!({ "account": rt.id(), "status": status, "error": error }));
        }
    }

    /// Unread counts changed: tell everyone listening (the bar's badge).
    pub fn emit_unread(&self) {
        let (total, by) = {
            let db = self.db.lock().unwrap();
            (db.unread_inbox(), db.unread_by_account())
        };
        self.emit("unread", json!({ "total": total, "byAccount": by }));
    }

    pub async fn rt(&self, id: &str) -> Option<Arc<AccountRt>> {
        self.accounts.read().await.get(id).cloned()
    }
}
