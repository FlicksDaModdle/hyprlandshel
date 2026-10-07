pragma Singleton
import QtQuick
import Hyprshell.Backend

// The app's state: where you are, what is listed, what is open, and every
// action, each a call to the daemon (MailClient). The daemon's events keep
// it current — new mail, flags changed elsewhere, a sync finishing.
QtObject {
    id: root

    // ── where ─────────────────────────────────────────────────────────────
    // view: inbox flagged snoozed drafts sent outbox archive junk trash
    //       attachments folder search settings
    // account: "" for every account; folder: a path, with view "folder".
    property var place: ({ view: "inbox", account: "", folder: "" })
    property string query: ""
    readonly property bool searching: root.query.trim() !== ""
    readonly property bool inSettings: root.place.view === "settings"

    // ── what there is ─────────────────────────────────────────────────────
    property var accounts: []
    property var folders: []
    property var status: ({})
    property int unread: 0
    property var unreadBy: ({})
    property var settings: ({})
    property var drafts: []
    property var outbox: []
    property var templates: []
    property var oauthClients: ({})

    // ── the list ──────────────────────────────────────────────────────────
    property var items: []
    property int total: 0
    property bool loading: false
    property int pageSize: 100
    property var selected: []          // ids of the rows picked
    property int anchorIndex: -1       // for shift-click ranges

    // ── what is open ──────────────────────────────────────────────────────
    property int openId: -1            // the conversation's newest message
    property var thread: []
    property var bodies: ({})          // message id → the whole message
    property var compose: null         // the message being written, or null

    // The window's frame, for things drawn outside their own item (the
    // reader's context menu).
    property var frameRef: null

    signal toast(string message, bool failed, string actionText, var action)
    signal raise()

    function err(e) { root.toast(String(e), true, "", null); }
    function call(cmd, args, cb) {
        MailClient.call(cmd, args || {}, (ok, r) => {
            if (!ok) root.err(r);
            if (cb) cb(ok, r);
        });
    }

    // ── settings with defaults ────────────────────────────────────────────
    function setting(k, d) { return root.settings[k] === undefined ? d : root.settings[k]; }
    function setSetting(k, v) {
        const s = Object.assign({}, root.settings); s[k] = v; root.settings = s;
        root.call("settings.set", { key: k, value: v });
    }
    readonly property bool threaded: root.setting("threads", true)
    readonly property bool darkMessages: root.setting("darkMessages", false)
    readonly property int undoSeconds: root.setting("undoSend", 5)

    // ── loading ───────────────────────────────────────────────────────────
    function loadAccounts() {
        root.call("accounts.list", {}, (ok, r) => { if (ok) root.accounts = r; });
        root.call("folders", {}, (ok, r) => { if (ok) root.folders = r; });
        root.call("status", {}, (ok, r) => {
            if (!ok) return;
            const st = {};
            for (const a of r.accounts) st[a.id] = a;
            root.status = st;
            root.unread = r.unread;
            root.unreadBy = r.byAccount;
        });
    }
    function loadSide() {
        root.call("drafts.list", {}, (ok, r) => { if (ok) root.drafts = r; });
        root.call("outbox.list", {}, (ok, r) => { if (ok) root.outbox = r; });
        root.call("templates.list", {}, (ok, r) => { if (ok) root.templates = r; });
        root.call("settings.get", {}, (ok, r) => { if (ok) root.settings = r; });
        root.call("oauth.clients", {}, (ok, r) => { if (ok) root.oauthClients = r; });
    }

    property int listSeq: 0
    function refresh(more) {
        const p = root.place;
        if (p.view === "settings" || p.view === "drafts" || p.view === "outbox") return;
        const seq = ++root.listSeq;
        const limit = more ? root.items.length + root.pageSize : Math.max(root.pageSize, root.items.length);
        root.loading = true;
        const done = (ok, r) => {
            if (seq !== root.listSeq) return;
            root.loading = false;
            if (!ok) return;
            root.items = r.items;
            root.total = r.total;
            // What was picked and is gone is not picked any more.
            const ids = r.items.map(x => x.id);
            root.selected = root.selected.filter(id => ids.indexOf(id) >= 0);
        };
        if (root.searching) {
            root.call("search", { query: root.query, limit: 300 }, done);
            return;
        }
        const args = { limit: limit, threads: root.threaded };
        if (p.view === "folder") { args.account = p.account; args.folder = p.folder; }
        else { args.view = p.view; if (p.account) args.account = p.account; }
        root.call("list", args, done);
    }

    function go(view, account, folder) {
        root.place = { view: view, account: account || "", folder: folder || "" };
        root.query = "";
        root.items = [];
        root.selected = [];
        root.closeThread();
        if (view === "drafts" || view === "outbox") root.loadSide();
        root.refresh(false);
    }
    function search(q) {
        root.query = q;
        root.selected = [];
        root.refresh(false);
    }

    // ── a conversation ────────────────────────────────────────────────────
    function open(id) {
        root.compose = null;
        root.openId = id;
        root.thread = [];
        root.call("thread", { id: id }, (ok, r) => {
            if (!ok || root.openId !== id) return;
            root.thread = r;
            // The ones to show open: the unread, and the newest.
            for (let i = 0; i < r.length; i++)
                if (!r[i].seen || i === r.length - 1) root.loadBody(r[i].id);
        });
    }
    function closeThread() { root.openId = -1; root.thread = []; }
    function loadBody(id, cb) {
        if (root.bodies[id]) { if (cb) cb(root.bodies[id]); return; }
        root.call("get", { id: id }, (ok, r) => {
            if (!ok) return;
            const b = Object.assign({}, root.bodies); b[id] = r; root.bodies = b;
            if (cb) cb(r);
        });
    }
    function forget(id) { const b = Object.assign({}, root.bodies); delete b[id]; root.bodies = b; }

    // ── acting ────────────────────────────────────────────────────────────
    // `ids` are list rows: each stands for its conversation when threaded.
    function act(cmd, ids, extra, okText, undo) {
        if (!ids || ids.length === 0) return;
        const args = Object.assign({ ids: ids, thread: root.threaded }, extra || {});
        // Gone from this list at once; the daemon's event confirms it.
        const moving = ["archive", "trash", "spam", "notSpam", "move", "deleteForever", "snooze"].indexOf(cmd) >= 0;
        if (moving) {
            root.items = root.items.filter(x => ids.indexOf(x.id) < 0);
            root.selected = [];
            if (ids.indexOf(root.openId) >= 0) root.closeThread();
        }
        root.call(cmd, args, (ok) => { if (ok && okText) root.toast(okText, false, undo ? "Undo" : "", undo || null); });
    }
    function archive(ids) {
        const inArchive = root.place.view === "archive";
        root.act(inArchive ? "notSpam" : "archive", ids, {}, (ids.length > 1 ? ids.length + " conversations " : "Conversation ") + (inArchive ? "moved to Inbox" : "archived"));
    }
    function trash(ids) {
        const forever = root.place.view === "trash";
        root.act("trash", ids, {}, forever ? "Deleted for good" : (ids.length > 1 ? ids.length + " conversations" : "Conversation") + " moved to the bin");
    }
    function spam(ids) {
        const back = root.place.view === "junk";
        root.act(back ? "notSpam" : "spam", ids, {}, back ? "Moved to Inbox" : "Marked as junk");
    }
    function moveTo(ids, account, folder) { root.act("move", ids, { to: folder }, "Moved to " + folder.split("/").pop()); }
    function setRead(ids, on) {
        root.items = root.items.map(x => ids.indexOf(x.id) >= 0 ? Object.assign({}, x, { seen: on, unreadCount: on ? 0 : x.count }) : x);
        root.act("flag", ids, { flag: "seen", value: on });
    }
    function setFlag(ids, on) {
        root.items = root.items.map(x => ids.indexOf(x.id) >= 0 ? Object.assign({}, x, { flagged: on, anyFlagged: on }) : x);
        root.act("flag", ids, { flag: "flagged", value: on });
    }
    function snooze(ids, until) {
        root.act("snooze", ids, { until: Math.round(until / 1000) }, "Snoozed until " + root.when(until), () => root.call("unsnooze", { ids: ids }));
    }
    function unsnooze(ids) { root.act("unsnooze", ids, {}, "Back in the inbox"); }

    // ── writing ───────────────────────────────────────────────────────────
    function defaultAccount() {
        const p = root.place;
        if (p.account) return p.account;
        return root.accounts.length > 0 ? root.accounts[0].id : "";
    }
    function accountById(id) { return root.accounts.find(a => a.id === id) || null; }
    function signatureFor(id) {
        const a = root.accountById(id);
        return a && a.signature ? "\n\n-- \n" + a.signature : "";
    }
    function newMessage(fields) {
        const acct = (fields && fields.account) || root.defaultAccount();
        root.compose = Object.assign({ account: acct, to: [], cc: [], bcc: [], subject: "", body: root.signatureFor(acct),
                                       attachments: [], key: Date.now() }, fields || {});
    }
    function quote(b) {
        const who = (b.from && b.from[0]) ? (b.from[0].name || b.from[0].email) : "";
        const when = Qt.formatDateTime(new Date(b.date * 1000), "ddd d MMM yyyy 'at' hh:mm");
        return "\n\nOn " + when + ", " + who + " wrote:\n" + (b.text || "").split("\n").map(l => "> " + l).join("\n");
    }
    function prefixed(p, s) {
        const re = new RegExp("^(" + p + ")\\s*:", "i");
        return re.test(s || "") ? s : p + ": " + (s || "");
    }
    function reply(b, all) {
        const me = (root.accountById(b.summary.account) || {}).email || "";
        const lower = s => (s || "").toLowerCase();
        const from = (b.replyTo && b.replyTo.length > 0) ? b.replyTo : b.from;
        let to = from.filter(x => lower(x.email) !== lower(me));
        if (to.length === 0) to = b.to;     // answering your own message: to whoever it went to
        let cc = [];
        if (all) {
            const seen = to.map(x => lower(x.email)).concat([lower(me)]);
            cc = (b.to || []).concat(b.cc || []).filter(x => { const k = lower(x.email); if (seen.indexOf(k) >= 0) return false; seen.push(k); return true; });
        }
        root.newMessage({
            account: b.summary.account, to: to, cc: cc,
            subject: root.prefixed("Re", b.subject),
            body: root.signatureFor(b.summary.account) + root.quote(b),
            inReplyTo: b.msgid, references: (b.references || []).concat([b.msgid]).filter(x => !!x),
            replyToId: b.id,
        });
    }
    function forward(b) {
        const head = "\n\n---------- Forwarded message ----------\nFrom: " + (b.from || []).map(x => (x.name ? x.name + " " : "") + "<" + x.email + ">").join(", ")
            + "\nDate: " + Qt.formatDateTime(new Date(b.date * 1000), "ddd d MMM yyyy hh:mm")
            + "\nSubject: " + b.subject + "\nTo: " + (b.to || []).map(x => x.email).join(", ") + "\n\n" + (b.text || "");
        root.newMessage({ account: b.summary.account, subject: root.prefixed("Fwd", b.subject),
                          body: root.signatureFor(b.summary.account) + head, forwardOf: b.id,
                          forwardParts: (b.attachments || []).map(a => ({ index: a.index, name: a.name, size: a.size })) });
    }

    // A queued send request back into the fields of the compose pane.
    function composeFromRequest(r) {
        const list = v => Array.isArray(v) ? v : String(v || "").split(",").map(x => x.trim()).filter(x => x).map(x => ({ name: "", email: x }));
        return { account: r.account, to: list(r.to), cc: list(r.cc), bcc: list(r.bcc), subject: r.subject || "",
                 body: r.text || "", attachments: r.attachments || [], inReplyTo: r.inReplyTo, references: r.references, replyToId: r.replyToId };
    }

    // Plain text to the HTML part sent alongside it: escaped, quotes as
    // quotes, links as links.
    function toHtml(text) {
        const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        const lines = text.split("\n");
        let out = "", depth = 0;
        for (const l of lines) {
            let d = 0, rest = l;
            while (rest.startsWith(">")) { d++; rest = rest.slice(1).replace(/^ /, ""); }
            while (depth < d) { out += '<blockquote style="margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex">'; depth++; }
            while (depth > d) { out += "</blockquote>"; depth--; }
            out += esc(rest).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1">$1</a>') + "<br>";
        }
        while (depth-- > 0) out += "</blockquote>";
        return '<div style="font-family:sans-serif;font-size:14px">' + out + "</div>";
    }

    // ── time ──────────────────────────────────────────────────────────────
    function when(ms) {
        const d = new Date(ms), now = new Date();
        const sameDay = d.toDateString() === now.toDateString();
        const tomorrow = new Date(now.getTime() + 86400000).toDateString() === d.toDateString();
        if (sameDay) return Qt.formatTime(d, "hh:mm");
        if (tomorrow) return "tomorrow " + Qt.formatTime(d, "hh:mm");
        return Qt.formatDateTime(d, "ddd d MMM hh:mm");
    }
    function shortDate(ts) {
        const d = new Date(ts * 1000), now = new Date();
        if (d.toDateString() === now.toDateString()) return Qt.formatTime(d, "hh:mm");
        const y = new Date(now.getTime() - 86400000);
        if (d.toDateString() === y.toDateString()) return "Yesterday";
        if (now - d < 6 * 86400000) return Qt.formatDate(d, "ddd");
        if (d.getFullYear() === now.getFullYear()) return Qt.formatDate(d, "d MMM");
        return Qt.formatDate(d, "d/M/yy");
    }
    function longDate(ts) { return Qt.formatDateTime(new Date(ts * 1000), "ddd d MMM yyyy, hh:mm"); }
    function size(n) {
        if (n < 1024) return n + " B";
        if (n < 1048576) return Math.round(n / 1024) + " KB";
        return (n / 1048576).toFixed(1) + " MB";
    }

    // The colour a person is drawn in: the same one every time.
    function hue(s) {
        let h = 0;
        for (let i = 0; i < (s || "").length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
        return Qt.hsla((h % 360) / 360, 0.45, 0.55, 1);
    }
    function initials(name, email) {
        const n = (name || "").replace(/["']/g, "").trim();
        if (n) {
            const p = n.split(/\s+/);
            return (p[0][0] + (p.length > 1 ? p[p.length - 1][0] : "")).toUpperCase();
        }
        return (email || "?")[0].toUpperCase();
    }

    // ── keeping up ────────────────────────────────────────────────────────
    property Timer settle: Timer {
        interval: 180
        onTriggered: {
            root.refresh(false);
            if (root.openId >= 0) {
                const id = root.openId;
                root.call("thread", { id: id }, (ok, r) => {
                    if (!ok || root.openId !== id) return;
                    if (r.length === 0) { root.closeThread(); return; }
                    root.thread = r;
                });
            }
        }
    }
    property Timer folderSettle: Timer {
        interval: 400
        onTriggered: root.loadAccounts()
    }
    property Connections events: Connections {
        target: MailClient
        function onEvent(name, data) {
            switch (name) {
            case "changed": root.settle.restart(); root.folderSettle.restart(); break;
            case "folders": case "accounts": case "status": root.folderSettle.restart(); if (name === "accounts") root.settle.restart(); break;
            case "unread": root.unread = data.total; root.unreadBy = data.byAccount; break;
            case "drafts": case "outbox": root.loadSide(); break;
            case "settings": root.call("settings.get", {}, (ok, r) => { if (ok) root.settings = r; }); break;
            case "error": root.err(data.message); break;
            case "resync": root.loadAccounts(); root.settle.restart(); break;
            }
        }
        function onConnectedChanged() {
            if (!MailClient.connected) return;
            root.loadAccounts();
            root.loadSide();
            root.refresh(false);
        }
    }
}
