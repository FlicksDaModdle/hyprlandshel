'use strict';
// Chats Web: WhatsApp Web in a window of its own, dressed as a Hyprshell app.
// (Chats, in apps/chats, is the native client; this is for what it can't
// do, calls above all.)
//
// The window is the kit apps' frame (a title row with the accent tick, the
// glyph, the name and the window's buttons) over WhatsApp Web, which runs
// unmodified in its own sandboxed view; theme.js recolours it into the
// shell's palette and keeps following the palette as it changes.
//
// Also: unread count in the title row, the window title and the tray; close
// hides to the tray (Quit is in the tray's menu, or Ctrl+Q); notifications,
// microphone for voice messages, links open in the browser, downloads go to
// ~/Downloads; zoom with Ctrl +/-/0; one instance.

const { app, BaseWindow, WebContentsView, ipcMain, nativeTheme, shell, Menu, Tray,
        nativeImage, Notification, clipboard, net, session } = require('electron');
const fs = require('fs');
const path = require('path');
const theme = require('./theme');
const icon = require('./icon');

// The test suite points this at a stand-in page; nothing else should.
const HOME = process.env.HYPRSHELL_CHATS_URL || 'https://web.whatsapp.com/';
const ORIGIN = new URL(HOME).origin;
const BAR = 46;

app.setName('hyprshell-chats-web');
app.setDesktopName('hyprshell-chats-web.desktop');
// WhatsApp Web only serves browsers it knows: the Chrome this Electron is
// built on, without the "Electron/…" that would give it away.
const UA = `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${process.versions.chrome} Safari/537.36`;
app.userAgentFallback = UA;

if (!app.requestSingleInstanceLock()) {
    app.quit();
    process.exit(0);
}

// ── settings ────────────────────────────────────────────────────────────────

const SETTINGS = path.join(app.getPath('userData'), 'settings.json');
let settings = { zoom: 0, width: 1180, height: 780, maximized: false, closeToTray: true };
try { Object.assign(settings, JSON.parse(fs.readFileSync(SETTINGS, 'utf8'))); } catch { /* first run */ }
let saveTimer = null;
function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
        try {
            fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
            fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2));
        } catch { /* a read-only home is not worth failing over */ }
    }, 400);
}

// ── state ───────────────────────────────────────────────────────────────────

let P = theme.load();
let map = theme.mapper(P);
let win = null, bar = null, web = null, off = null, tray = null;
let quitting = false;
let unread = 0;
let offline = null;           // the error text while the page can't load
let cssKey = null;            // what insertCSS gave back, to replace it
let sheets = [];              // [{ href } | { text }], in document order
const fetched = new Map();    // href → stylesheet text
const mapped = new Map();     // text → overrides, for the current palette

function isOurs(url) {
    try { return new URL(url).origin === ORIGIN; } catch { return false; }
}
// Where WhatsApp's stylesheets may come from: its own page and its CDN.
function sheetAllowed(url) {
    try {
        const u = new URL(url);
        if (u.origin === ORIGIN) return true;
        return u.protocol === 'https:' && /(^|\.)whatsapp\.(net|com)$/.test(u.hostname);
    } catch { return false; }
}

// ── the window ──────────────────────────────────────────────────────────────

function uiPrefs() {
    return { preload: path.join(__dirname, 'preload-ui.js'), sandbox: true, contextIsolation: true, nodeIntegration: false };
}

function create() {
    win = new BaseWindow({
        width: settings.width, height: settings.height, minWidth: 640, minHeight: 460,
        frame: false, title: 'Chats Web', show: false, backgroundColor: P.ground,
        icon: nativeImage.createFromBuffer(icon.draw(128, P.accent, P.inkOnAccent, P.ink, false)),
    });
    bar = new WebContentsView({ webPreferences: uiPrefs() });
    web = new WebContentsView({
        webPreferences: {
            preload: path.join(__dirname, 'preload-web.js'),
            sandbox: true, contextIsolation: true, nodeIntegration: false, spellcheck: true,
        },
    });
    bar.setBackgroundColor(P.ground);
    web.setBackgroundColor(P.ground);
    win.contentView.addChildView(web);
    win.contentView.addChildView(bar);
    bar.webContents.loadFile(path.join(__dirname, 'titlebar.html'));

    // getBounds, not getContentBounds: on Wayland the content bounds lag a
    // resize the compositor made, and with no frame they are the same thing.
    const layout = () => {
        const { width, height } = win.getBounds();
        bar.setBounds({ x: 0, y: 0, width, height: BAR });
        web.setBounds({ x: 0, y: BAR, width, height: Math.max(0, height - BAR) });
        if (off) off.setBounds({ x: 0, y: BAR, width, height: Math.max(0, height - BAR) });
    };
    // Laid out again a moment after any change of size as well: on Wayland
    // the bounds can still be the old ones when the event comes (maximise,
    // a resize from the compositor), which left the page at its old size
    // inside a bigger window.
    let later = [];
    const relayout = () => {
        layout();
        for (const t of later) clearTimeout(t);
        later = [60, 250].map(ms => setTimeout(() => { if (win && !win.isDestroyed()) layout(); }, ms));
    };
    layout();
    for (const ev of ['resized', 'maximize', 'unmaximize', 'enter-full-screen', 'leave-full-screen', 'restore', 'show'])
        win.on(ev, relayout);
    win.on('resize', () => {
        relayout();
        if (!win.isMaximized()) {
            const [w, h] = win.getSize();
            settings.width = w; settings.height = h;
        }
        save();
    });
    win.on('maximize', () => { settings.maximized = true; save(); sendState(); });
    win.on('unmaximize', () => { settings.maximized = false; save(); sendState(); });
    win.on('focus', () => sendState());
    win.on('blur', () => sendState());
    win.on('close', e => {
        if (!quitting && settings.closeToTray && tray) { e.preventDefault(); win.hide(); }
    });
    win.on('closed', () => { win = null; });

    wireWeb(web.webContents);
    for (const wc of [bar.webContents, web.webContents]) wc.on('before-input-event', keys);

    web.webContents.loadURL(HOME);
    if (settings.maximized) win.maximize();
    win.show();
}

function show() {
    if (!win) { create(); return; }
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
}

function quit() { quitting = true; app.quit(); }

// ── WhatsApp's view ─────────────────────────────────────────────────────────

function wireWeb(wc) {
    wc.setZoomLevel(settings.zoom);
    wc.on('did-finish-load', () => wc.setZoomLevel(settings.zoom));

    // Links leave for the browser; the page itself stays on WhatsApp.
    wc.setWindowOpenHandler(({ url }) => {
        if (/^(https?|mailto|tel):/i.test(url)) shell.openExternal(url);
        return { action: 'deny' };
    });
    wc.on('will-navigate', (e, url) => {
        if (isOurs(url)) return;
        e.preventDefault();
        if (/^(https?|mailto|tel):/i.test(url)) shell.openExternal(url);
    });

    wc.on('page-title-updated', (e, title) => {
        e.preventDefault();
        const m = /^\((\d+)\)/.exec(title || '');
        const n = m ? parseInt(m[1], 10) : 0;
        if (n !== unread) { unread = n; sendState(); }
    });

    // A new page: what was inserted into the last one went with it.
    // Chromium's own error page "finishes loading" too, just after the
    // failure, so only a load with no failure in it counts as back online.
    let failed = false;
    wc.on('did-start-navigation', (e) => {
        if (e.isMainFrame && !e.isSameDocument) { cssKey = null; sheets = []; failed = false; }
    });
    wc.on('did-fail-load', (e, code, desc, url, isMain) => {
        // -3 is "aborted": WhatsApp navigating on, not a failure.
        if (!isMain || code === -3) return;
        failed = true;
        setOffline(desc || 'The page could not be loaded');
    });
    wc.on('did-finish-load', () => { if (offline && !failed && isOurs(wc.getURL())) setOffline(null); });
    wc.on('render-process-gone', (e, d) => {
        if (d.reason !== 'clean-exit') setOffline('WhatsApp stopped unexpectedly');
    });

    wc.on('context-menu', (e, p) => {
        const t = [];
        for (const s of (p.dictionarySuggestions || []).slice(0, 5)) t.push({ label: s, click: () => wc.replaceMisspelling(s) });
        if (p.misspelledWord) {
            t.push({ label: 'Add to dictionary', click: () => wc.session.addWordToSpellCheckerDictionary(p.misspelledWord) });
            t.push({ type: 'separator' });
        }
        if (p.linkURL && /^(https?|mailto):/i.test(p.linkURL)) {
            t.push({ label: 'Open link', click: () => shell.openExternal(p.linkURL) });
            t.push({ label: 'Copy link', click: () => clipboard.writeText(p.linkURL) });
            t.push({ type: 'separator' });
        }
        if (p.mediaType === 'image' && p.srcURL) {
            t.push({ label: 'Copy image', click: () => wc.copyImageAt(p.x, p.y) });
            t.push({ label: 'Save image', click: () => wc.downloadURL(p.srcURL) });
            t.push({ type: 'separator' });
        }
        if (p.isEditable) {
            t.push({ role: 'undo' }, { role: 'redo' }, { type: 'separator' },
                   { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' });
        } else if (p.selectionText) {
            t.push({ role: 'copy' });
        }
        while (t.length && t[t.length - 1].type === 'separator') t.pop();
        if (t.length && win) Menu.buildFromTemplate(t).popup({ window: win });
    });
}

// ── offline ─────────────────────────────────────────────────────────────────

let retryTimer = null;
function setOffline(text) {
    offline = text;
    if (text && !off && win) {
        off = new WebContentsView({ webPreferences: uiPrefs() });
        off.setBackgroundColor(P.ground);
        off.webContents.loadFile(path.join(__dirname, 'offline.html'));
        off.webContents.on('before-input-event', keys);
        win.contentView.addChildView(off);
        const { width, height } = win.getBounds();
        off.setBounds({ x: 0, y: BAR, width, height: Math.max(0, height - BAR) });
    } else if (!text && off) {
        if (win) win.contentView.removeChildView(off);
        off.webContents.close();
        off = null;
    }
    clearInterval(retryTimer);
    retryTimer = null;
    // Back by itself when the connection is: every fifteen seconds.
    if (text) retryTimer = setInterval(() => { if (net.isOnline()) retry(); }, 15000);
    sendState();
}
function retry() { if (web) web.webContents.loadURL(HOME); }

// ── keys ────────────────────────────────────────────────────────────────────

function zoom(by) {
    settings.zoom = by === 0 ? 0 : Math.max(-3, Math.min(4, settings.zoom + by));
    if (web) web.webContents.setZoomLevel(settings.zoom);
    save();
    sendState();
}

function keys(e, input) {
    if (input.type !== 'keyDown') return;
    const ctrl = input.control || input.meta;
    const k = input.key;
    let done = true;
    if (ctrl && (k === 'q' || k === 'Q')) quit();
    else if (ctrl && (k === 'w' || k === 'W')) win && win.close();
    else if ((ctrl && (k === 'r' || k === 'R')) || k === 'F5') retry();
    else if (ctrl && (k === '=' || k === '+')) zoom(0.5);
    else if (ctrl && k === '-') zoom(-0.5);
    else if (ctrl && k === '0') zoom(0);
    else if (k === 'F11' && win) win.setFullScreen(!win.isFullScreen());
    else done = false;
    if (done) e.preventDefault();
}

// ── the title row and the offline page ─────────────────────────────────────

function state() {
    return {
        unread, offline,
        maximized: !!(win && win.isMaximized()),
        focused: !!(win && win.isFocused()),
        zoom: Math.round(Math.pow(1.2, settings.zoom) * 100),
    };
}
function sendState() {
    const s = state();
    for (const v of [bar, off]) if (v && !v.webContents.isDestroyed()) v.webContents.send('chats:state', s);
    if (win) win.setTitle(unread > 0 ? `(${unread}) Chats Web` : 'Chats Web');
    updateTray();
}
function sendPalette() {
    for (const v of [bar, off]) if (v && !v.webContents.isDestroyed()) v.webContents.send('chats:palette', P);
}

ipcMain.on('chats:ui-ready', e => {
    e.sender.send('chats:palette', P);
    e.sender.send('chats:state', state());
});
ipcMain.on('chats:act', (e, what) => {
    if (!win || (e.sender !== bar?.webContents && e.sender !== off?.webContents)) return;
    switch (what) {
    case 'minimize': win.minimize(); break;
    case 'maximize': win.isMaximized() ? win.unmaximize() : win.maximize(); break;
    case 'close': win.close(); break;
    case 'reload': case 'retry': retry(); break;
    case 'zoom-reset': zoom(0); break;
    }
});
// A notification was clicked: bring the window up.
ipcMain.on('chats:show', e => { if (e.sender === web?.webContents) show(); });

// ── theming WhatsApp ────────────────────────────────────────────────────────

ipcMain.on('chats:sheets', (e, list) => {
    if (!web || e.sender !== web.webContents || !Array.isArray(list)) return;
    if (!isOurs(web.webContents.getURL())) return;
    sheets = list.slice(0, 400).map(s => (s && typeof s.href === 'string' ? { href: s.href }
        : { text: String((s && s.text) || '').slice(0, 4 << 20) }));
    restyle();
});

async function sheetText(href) {
    if (fetched.has(href)) return fetched.get(href);
    if (!sheetAllowed(href)) return '';
    let text = '';
    try {
        const r = await web.webContents.session.fetch(href);
        if (r.ok) text = (await r.text()).slice(0, 8 << 20);
    } catch { /* offline: the next scan tries again */ return ''; }
    fetched.set(href, text);
    return text;
}

let styling = Promise.resolve();
function restyle() {
    styling = styling.then(async () => {
        if (!web) return;
        const wc = web.webContents;
        const parts = [];
        for (const s of sheets) {
            const text = s.href ? await sheetText(s.href) : s.text;
            if (!text) continue;
            let out = mapped.get(text);
            if (out === undefined) {
                out = theme.recolor(text, map);
                mapped.set(text, out);
            }
            if (out) parts.push(out);
        }
        parts.push(theme.base(P));
        const css = parts.join('\n');
        try {
            const key = await wc.insertCSS(css, { cssOrigin: 'user' });
            if (cssKey) await wc.removeInsertedCSS(cssKey).catch(() => {});
            cssKey = key;
        } catch { /* the page went while this ran */ }
    }).catch(() => {});
}

function applyPalette() {
    P = theme.load();
    map = theme.mapper(P);
    mapped.clear();
    nativeTheme.themeSource = P.dark ? 'dark' : 'light';
    if (win) win.setBackgroundColor(P.ground);
    for (const v of [bar, web, off]) if (v) v.setBackgroundColor(P.ground);
    sendPalette();
    updateTray(true);
    restyle();
}

// ── tray ────────────────────────────────────────────────────────────────────

let trayKey = '';
function updateTray(force) {
    if (!tray) return;
    const key = `${P.accent}${P.ink}${unread > 0}`;
    if (key !== trayKey || force) {
        trayKey = key;
        tray.setImage(nativeImage.createFromBuffer(icon.draw(64, P.accent, P.inkOnAccent, P.ink, unread > 0)));
    }
    tray.setToolTip(unread > 0 ? `Chats Web — ${unread} unread` : 'Chats Web');
}

function createTray() {
    try {
        tray = new Tray(nativeImage.createFromBuffer(icon.draw(64, P.accent, P.inkOnAccent, P.ink, false)));
    } catch { tray = null; return; }
    tray.setContextMenu(Menu.buildFromTemplate([
        { label: 'Show Chats Web', click: show },
        { type: 'separator' },
        { label: 'Quit', click: quit },
    ]));
    tray.on('click', () => (win && win.isVisible() && win.isFocused() ? win.hide() : show()));
    updateTray(true);
}

// ── downloads and permissions ───────────────────────────────────────────────

function unique(dir, name) {
    const ext = path.extname(name), stem = path.basename(name, ext) || 'download';
    let p = path.join(dir, stem + ext);
    for (let i = 2; fs.existsSync(p); i++) p = path.join(dir, `${stem} (${i})${ext}`);
    return p;
}

function setupSession(ses) {
    ses.setUserAgent(UA);
    const ALLOW = new Set(['notifications', 'media', 'clipboard-read', 'clipboard-sanitized-write', 'fullscreen']);
    // What WhatsApp Web uses — notifications, the microphone and camera
    // (voice messages, calls), the clipboard — and only for WhatsApp.
    ses.setPermissionRequestHandler((wc, perm, cb, details) => {
        cb(ALLOW.has(perm) && isOurs(details.requestingUrl || wc.getURL()));
    });
    ses.setPermissionCheckHandler((wc, perm, origin) => ALLOW.has(perm) && isOurs(origin));
    ses.on('will-download', (e, item) => {
        const dir = app.getPath('downloads');
        const file = unique(dir, path.basename(item.getFilename() || 'download'));
        item.setSavePath(file);
        item.once('done', (ev, st) => {
            if (st !== 'completed' || !Notification.isSupported()) return;
            const n = new Notification({ title: 'Downloaded', body: path.basename(file), silent: true });
            n.on('click', () => shell.showItemInFolder(file));
            n.show();
        });
    });
}

// ── start ───────────────────────────────────────────────────────────────────

app.on('second-instance', show);
app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', () => { if (!tray || quitting) app.quit(); });

app.whenReady().then(() => {
    Menu.setApplicationMenu(null);
    nativeTheme.themeSource = P.dark ? 'dark' : 'light';
    setupSession(session.defaultSession);
    if (!process.argv.includes('--no-tray')) createTray();
    create();
    if (process.argv.includes('--hidden') && tray) win.hide();

    // The palette, as the shell changes it: the file, polled like the kit
    // apps do, and the hour for "auto".
    let lastDark = P.dark;
    fs.watchFile(theme.THEME, { interval: 1500 }, applyPalette);
    setInterval(() => {
        const next = theme.load();
        if (next.dark !== lastDark) { lastDark = next.dark; applyPalette(); }
    }, 60000);
});
