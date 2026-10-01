import QtQuick
import Hyprshell
import Hyprshell.Backend

// 7-Zip's windows, in this one: which of them is app.archiveSheet's
// `mode`.
//
//   { mode: "compress", names, dir? }                   "Add to Archive"
//   { mode: "extract", archive, name, paths?, password?, from? }
//                                                        "Extract"
//   { mode: "extractNow", opts, back? }                  extracting, after
//        asking only what 7-Zip would (Confirm File Replace, a password)
//   { mode: "browse", archive, name, listing?, prefix?, password? }
//                                                        7-Zip File Manager
//   { mode: "checksum", dir, names, method }            "Checksum information"
//
// The work is Archives.qml's; this lays out its questions the way 7-Zip
// does — label and drop-down, two columns, group boxes, OK and Cancel —
// in the shell's colours. Progress is ArchiveProgress.qml's.
PanelSurface {
    id: sheet

    required property var app
    readonly property var svc: FilesService
    readonly property var arc: Archives
    readonly property var spec: sheet.app.archiveSheet
    readonly property string mode: sheet.spec ? sheet.spec.mode : ""
    property real maxWidth: 1000
    property real maxHeight: 640

    // A question put up over whatever is showing, as 7-Zip's message boxes
    // are: { kind: replace | password | message | confirm | info, … }.
    property var ask: null

    showSeam: false
    color: Appearance.dialog
    visible: sheet.spec !== null && (sheet.mode !== "extractNow" || sheet.ask !== null)
    z: 950
    implicitWidth: sheet.mode === "extractNow" ? askBox.width
                 : sheet.mode === "browse" ? Math.min(sheet.maxWidth, 940)
                 : sheet.mode === "compress" ? Math.min(sheet.maxWidth, 700)
                 : sheet.mode === "checksum" ? Math.min(sheet.maxWidth, 600)
                 : Math.min(sheet.maxWidth, 560)
    implicitHeight: sheet.mode === "extractNow" ? askBox.height
                  : sheet.mode === "browse" ? Math.min(sheet.maxHeight, 600)
                  : Math.min(sheet.maxHeight, titleBar.height + body.implicitHeight + 28)
    clip: true

    function close() { sheet.ask = null; sheet.app.archiveSheet = null; }

    // Bumped whenever the sheet changes, so an answer that arrives for one
    // that has since gone is dropped.
    property int serial: 0

    onSpecChanged: {
        sheet.serial++;
        sheet.ask = null;
        if (!sheet.spec) return;
        // The spec's own mode, not `sheet.mode`: that binding may not have
        // caught up yet while this handler runs.
        const s = sheet.spec;
        if (s.mode === "compress") sheet.resetCompress(s);
        else if (s.mode === "extract") sheet.resetExtract(s);
        else if (s.mode === "extractNow") sheet.runExtract(s.opts, s.back || null);
        else if (s.mode === "browse") sheet.resetBrowse(s);
        else if (s.mode === "checksum") sheet.runChecksum(s);
    }

    // ── shared ────────────────────────────────────────────────────────────
    function expand(p) {
        p = String(p || "").trim();
        if (p === "~") return sheet.svc.home;
        if (p.indexOf("~/") === 0) p = sheet.svc.home + p.slice(1);
        return p.replace(/(.)\/+$/, "$1");
    }
    // 7-Zip writes sizes in bytes, grouped: 1 234 567.
    function grouped(n) {
        let t = String(Math.round(n || 0)), out = "";
        while (t.length > 3) { out = " " + t.slice(-3) + out; t = t.slice(0, -3); }
        return t + out;
    }
    function stamp(t) {
        if (!t) return "";
        const d = new Date(t * 1000), p = n => (n < 10 ? "0" : "") + n;
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
    }

    // The "…" buttons: this program again, as its own file dialog.
    property Proc picker: Proc {
        property var then: null
        onFinished: (code, out) => {
            const p = String(out).split("\n")[0];
            if (code === 0 && p && sheet.picker.then) sheet.picker.then(p);
        }
    }
    function pick(args, then) {
        if (sheet.picker.running) return;
        sheet.picker.then = then;
        sheet.picker.command = [Sys.appPath(), "--pick"].concat(args);
        sheet.picker.running = true;
    }

    // ══ Add to Archive ════════════════════════════════════════════════════
    property string cDir: ""
    property string cName: ""
    property string cFormat: "7z"
    property int cLevel: 5
    property string cMethod: "LZMA2"
    property string cDict: ""
    property int cWord: 0
    property string cSolid: "Non-solid"
    property int cThreads: 4
    property string cVolume: ""
    property string cParams: ""
    property string cUpdate: "add"
    property string cPathMode: "relative"
    property bool cShared: false
    property bool cDelete: false
    property string cPassword: ""
    property string cPassword2: ""
    property bool cShow: false
    property string cEncMethod: "AES-256"
    property bool cEncryptNames: false

    readonly property var cFmt: sheet.arc.format(sheet.cFormat)
    readonly property bool cStore: !!sheet.cFmt.store
    readonly property bool cTar: !!sheet.cFmt.tar
    readonly property bool cSeven: sheet.cFormat === "7z" || sheet.cFormat === "zip"
    readonly property bool cBlocked: !sheet.arc.hasSevenZip && !sheet.cTar && sheet.cFormat !== "tar"

    function knownExt(name) {
        const l = String(name).toLowerCase();
        // Longest first, so "x.tar.gz" is not taken for a ".gz".
        const exts = sheet.arc.formats.map(f => "." + f.value).sort((a, b) => b.length - a.length);
        for (const e of exts) if (l.endsWith(e)) return e;
        return "";
    }
    function resetCompress(s) {
        const names = s.names || [];
        sheet.cDir = s.dir || sheet.app.cwd;
        // 7-Zip's own default: one thing is named after itself, several
        // after the folder they are in.
        const base = names.length === 1 ? (names[0].replace(/\.[^./]+$/, "") || names[0])
                                        : (sheet.svc.basename(sheet.cDir) || "Archive");
        sheet.cFormat = sheet.arc.hasSevenZip ? "7z" : "tar.zst";
        sheet.cName = base + "." + sheet.cFormat;
        sheet.cLevel = 5;
        sheet.cMethod = sheet.cFmt.methods[0] || "";
        sheet.cThreads = sheet.arc.cpus;
        sheet.cVolume = ""; sheet.cParams = ""; sheet.cUpdate = "add"; sheet.cPathMode = "relative";
        sheet.cShared = false; sheet.cDelete = false;
        sheet.cPassword = ""; sheet.cPassword2 = ""; sheet.cShow = false;
        sheet.cEncMethod = sheet.cFmt.enc[0] || "AES-256"; sheet.cEncryptNames = false;
        sheet.applyDefaults();
    }
    function applyDefaults() {
        const d = sheet.arc.defaults(sheet.cFormat, sheet.cMethod, sheet.cLevel);
        sheet.cDict = d.dict; sheet.cWord = d.word; sheet.cSolid = d.solid;
    }
    function setFormat(v) {
        const ext = sheet.knownExt(sheet.cName);
        sheet.cName = (ext ? sheet.cName.slice(0, sheet.cName.length - ext.length) : sheet.cName) + "." + v;
        sheet.cFormat = v;
        const f = sheet.arc.format(v);
        sheet.cMethod = f.methods[0] || "";
        if (f.enc.indexOf(sheet.cEncMethod) < 0) sheet.cEncMethod = f.enc[0] || "AES-256";
        if (f.tar && sheet.cLevel === 0) sheet.cLevel = 5;
        sheet.applyDefaults();
    }

    readonly property var cDictModel: {
        const m = sheet.cMethod;
        if (m === "LZMA2" || m === "LZMA") return sheet.arc.dictSizes;
        if (m === "PPMd") return ["1 MB", "2 MB", "4 MB", "8 MB", "16 MB", "32 MB", "64 MB", "128 MB", "192 MB", "256 MB", "512 MB", "1024 MB"];
        if (m === "BZip2") return ["900 KB"];
        if (m === "Deflate") return ["32 KB"];
        if (m === "Deflate64") return ["64 KB"];
        return [];
    }
    readonly property var cWordModel: {
        const m = sheet.cMethod;
        if (m === "LZMA2" || m === "LZMA") return sheet.arc.wordSizes;
        if (m === "PPMd") return [2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32];
        if (m === "Deflate" || m === "Deflate64") return [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 257];
        return [];
    }
    readonly property var cThreadModel: {
        const out = [];
        for (let i = 1; i <= sheet.arc.cpus * 2; i++) out.push(i);
        return out;
    }
    readonly property var cMemory: sheet.arc.memory(sheet.cFormat, sheet.cTar || sheet.cStore ? "" : sheet.cMethod,
                                                    sheet.cDict, sheet.cThreads, sheet.cLevel)

    function submitCompress() {
        if (sheet.cBlocked) {
            sheet.ask = { kind: "message", title: "7-Zip", text: "7-Zip is not installed.\nInstall the 7zip package (or p7zip) for this format; the tar formats work without it." };
            return;
        }
        const name = sheet.cName.trim();
        if (name === "") return;
        const enc = sheet.cFmt.enc.length > 0 && sheet.cPassword !== "";
        if (enc && !sheet.cShow && sheet.cPassword !== sheet.cPassword2) {
            sheet.ask = { kind: "message", title: "Add to Archive", text: "Passwords do not match" };
            return;
        }
        const full = name.indexOf("/") === 0 || name.indexOf("~") === 0 ? sheet.expand(name) : sheet.svc.join(sheet.cDir, name);
        sheet.arc.compress({
            dir: sheet.spec.dir || sheet.app.cwd, names: sheet.spec.names, archive: full, format: sheet.cFormat,
            level: sheet.cStore ? 0 : sheet.cLevel, method: sheet.cMethod, dict: sheet.cDict, word: sheet.cWord,
            solid: sheet.cSolid, threads: sheet.cThreads, volume: sheet.cSeven ? sheet.cVolume : "",
            params: sheet.cSeven ? sheet.cParams : "", update: sheet.cUpdate, pathMode: sheet.cPathMode,
            deleteAfter: sheet.cDelete, shared: sheet.cShared, password: enc ? sheet.cPassword : "",
            encMethod: sheet.cEncMethod, encryptNames: sheet.cEncryptNames
        });
        if (sheet.svc.parent(full) === sheet.app.cwd) sheet.app.pendingSelect = sheet.svc.basename(full);
        sheet.close();
    }

    // ══ Extract ═══════════════════════════════════════════════════════════
    property string xBase: ""
    property bool xUseFolder: true
    property string xFolder: ""
    property string xPathMode: "full"
    property bool xElim: true
    property string xOverwrite: "ask"
    property string xPassword: ""
    property bool xShow: false

    function resetExtract(s) {
        sheet.xBase = sheet.svc.parent(s.archive).replace(/\/?$/, "/");
        sheet.xUseFolder = true;
        sheet.xFolder = sheet.arc.stem(s.name);
        sheet.xPathMode = "full";
        sheet.xElim = true;
        sheet.xOverwrite = "ask";
        sheet.xPassword = s.password || "";
        sheet.xShow = false;
    }
    function submitExtract() {
        const base = sheet.expand(sheet.xBase) || sheet.app.cwd;
        const dest = sheet.xUseFolder && sheet.xFolder.trim() !== "" ? sheet.svc.join(base, sheet.xFolder.trim()) : base;
        sheet.app.archiveSheet = {
            mode: "extractNow", back: sheet.spec.from || null,
            opts: { archive: sheet.spec.archive, dest: dest, paths: sheet.spec.paths || [], password: sheet.xPassword,
                    pathMode: sheet.xPathMode, eliminateRoot: sheet.xElim, overwrite: sheet.xOverwrite }
        };
    }

    // Lists it first when anything depends on what is inside: the
    // overwrite question, the root folder, the size for the progress
    // window. Then extracts, or asks.
    function runExtract(o, back) {
        const token = sheet.serial;
        const finish = () => { sheet.ask = null; sheet.app.archiveSheet = back || null; };
        const go = opts => { sheet.arc.extract(opts); finish(); };
        const tar = sheet.arc.isTar(o.archive);
        // A tar is read through entirely to be listed; only for a reason.
        if (tar && o.overwrite !== "ask" && !o.eliminateRoot) { go(o); return; }
        sheet.arc.list(o.archive, o.password, r => {
            if (token !== sheet.serial) return;
            if (r.error !== "") {
                if (r.needsPassword) {
                    sheet.ask = { kind: "password", title: "Enter password", wrong: !!o.password,
                                  then: pw => sheet.runExtract(Object.assign({}, o, { password: pw }), back),
                                  cancel: finish };
                    return;
                }
                // Let 7-Zip itself say what is wrong, in its window.
                go(Object.assign({}, o, { overwrite: o.overwrite === "ask" ? "rename" : o.overwrite }));
                return;
            }
            const sel = o.paths || [];
            const files = r.entries.filter(e => !e.dir && (sel.length === 0 || sel.some(p => e.path === p || e.path.indexOf(p + "/") === 0)));
            let dest = o.dest;
            // Eliminate duplication of root folder: everything in one
            // folder, being extracted into a folder of the same name.
            if (o.eliminateRoot && o.pathMode === "full" && files.length > 0) {
                const top = files[0].path.split("/")[0];
                if (files.every(e => e.path.indexOf(top + "/") === 0) && sheet.svc.basename(dest) === top)
                    dest = sheet.svc.parent(dest);
            }
            const total = files.reduce((a, e) => a + e.size, 0);
            const opts = Object.assign({}, o, { dest: dest, total: total });
            if (o.overwrite !== "ask") { go(opts); return; }
            const rel = e => o.pathMode === "none" ? e.path.split("/").pop() : e.path.replace(/^\/+/, "");
            const byRel = {};
            for (const e of files) byRel[rel(e)] = e;
            sheet.arc.clashes(dest, Object.keys(byRel), found => {
                if (token !== sheet.serial) return;
                if (found.length === 0) { go(Object.assign({}, opts, { overwrite: "overwrite" })); return; }
                sheet.ask = { kind: "replace", opts: opts, back: back, at: 0, skip: [],
                              queue: found.map(f => ({ old: f, item: byRel[f.path] || { path: f.path, size: 0, mtime: 0 } })) };
            });
        });
    }
    // Confirm File Replace's buttons.
    function answer(how) {
        const a = sheet.ask;
        if (!a || a.kind !== "replace") return;
        const back = a.back;
        const go = (mode, skip) => {
            sheet.arc.extract(Object.assign({}, a.opts, { overwrite: mode, exclude: skip }));
            sheet.ask = null;
            sheet.app.archiveSheet = back || null;
        };
        const rest = a.queue.slice(a.at).map(q => q.item.path);
        if (how === "cancel") { sheet.ask = null; sheet.app.archiveSheet = back || null; return; }
        if (how === "yesAll") { go("overwrite", a.skip); return; }
        if (how === "noAll") { go("overwrite", a.skip.concat(rest)); return; }
        if (how === "rename") { go("rename", a.skip); return; }
        const skip = how === "no" ? a.skip.concat([a.queue[a.at].item.path]) : a.skip;
        if (a.at + 1 >= a.queue.length) { go("overwrite", skip); return; }
        sheet.ask = Object.assign({}, a, { at: a.at + 1, skip: skip });
    }

    // ══ 7-Zip File Manager ════════════════════════════════════════════════
    property var listing: null          // { entries, info, needsPassword, error }, null while reading
    property string prefix: ""          // the folder inside, "" at the top
    property string password: ""
    property var picked: []             // paths
    property string anchorPath: ""
    property string sortKey: "name"
    property bool sortAsc: true

    function resetBrowse(s) {
        sheet.picked = s.picked || []; sheet.anchorPath = "";
        sheet.prefix = s.prefix || "";
        sheet.password = s.password || "";
        if (s.listing) sheet.listing = s.listing;
        else sheet.load();
    }
    function load() {
        const token = sheet.serial;
        sheet.listing = null;
        const archive = sheet.spec.archive;
        sheet.arc.list(archive, sheet.password, r => {
            if (token !== sheet.serial) return;
            sheet.listing = r;
            if (r.needsPassword)
                sheet.ask = { kind: "password", title: "Enter password", wrong: sheet.password !== "",
                              then: pw => { sheet.password = pw; sheet.load(); }, cancel: () => {} };
        });
    }
    // What this spec should come back as, from Extract or after a job.
    function browseState() {
        return { mode: "browse", archive: sheet.spec.archive, name: sheet.spec.name, listing: sheet.listing,
                 prefix: sheet.prefix, password: sheet.password, picked: sheet.picked.slice() };
    }

    // Folder totals, as 7-Zip shows them in a folder's own row.
    readonly property var dirStats: {
        const out = {};
        const l = sheet.listing;
        if (!l || !l.entries) return out;
        for (const e of l.entries) {
            if (e.dir) continue;
            const parts = e.path.split("/");
            for (let i = 0; i < parts.length; i++) {
                const k = parts.slice(0, i).join("/");
                const s = out[k] || (out[k] = { size: 0, packed: 0, files: 0 });
                s.size += e.size; s.packed += e.packed; s.files++;
            }
        }
        return out;
    }
    readonly property var here: {
        const l = sheet.listing;
        if (!l || !l.entries) return [];
        const pre = sheet.prefix === "" ? "" : sheet.prefix + "/";
        const out = [];
        for (const e of l.entries) {
            if (pre !== "" && e.path.indexOf(pre) !== 0) continue;
            const rest = e.path.slice(pre.length);
            if (rest === "" || rest.indexOf("/") >= 0) continue;
            const st = e.dir ? (sheet.dirStats[e.path] || { size: 0, packed: 0 }) : null;
            out.push(Object.assign({}, e, { name: rest, size: st ? st.size : e.size, packed: st ? st.packed : e.packed }));
        }
        const k = sheet.sortKey, dir = sheet.sortAsc ? 1 : -1;
        out.sort((a, b) => {
            if (a.dir !== b.dir) return a.dir ? -1 : 1;
            const x = a[k], y = b[k];
            const c = typeof x === "string" ? x.localeCompare(y) : (x > y) - (x < y);
            return (c || a.name.localeCompare(b.name)) * dir;
        });
        return sheet.prefix === "" ? out : [{ up: true, name: "..", path: "", dir: true }].concat(out);
    }
    function sortBy(k) {
        if (sheet.sortKey === k) sheet.sortAsc = !sheet.sortAsc;
        else { sheet.sortKey = k; sheet.sortAsc = true; }
    }
    function enter(e) {
        if (e.up) { sheet.goUp(); return; }
        if (e.dir) { sheet.prefix = e.path; sheet.picked = []; return; }
        if (e.encrypted && sheet.password === "") {
            const archive = sheet.spec.archive;
            sheet.ask = { kind: "password", title: "Enter password", wrong: false,
                          then: pw => { sheet.password = pw; sheet.arc.openInside(archive, e.path, pw); },
                          cancel: () => {} };
            return;
        }
        sheet.arc.openInside(sheet.spec.archive, e.path, sheet.password);
    }
    function goUp() {
        if (sheet.prefix === "") return;
        const was = sheet.prefix;
        sheet.prefix = was.indexOf("/") >= 0 ? was.slice(0, was.lastIndexOf("/")) : "";
        sheet.picked = [was];
    }
    function click(e, mods) {
        if (e.up) { sheet.picked = []; return; }
        if ((mods & Qt.ShiftModifier) && sheet.anchorPath !== "") {
            const paths = sheet.here.filter(x => !x.up).map(x => x.path);
            const a = paths.indexOf(sheet.anchorPath), b = paths.indexOf(e.path);
            if (a >= 0 && b >= 0) { sheet.picked = paths.slice(Math.min(a, b), Math.max(a, b) + 1); return; }
        }
        if (mods & Qt.ControlModifier) {
            const p = sheet.picked.slice(), i = p.indexOf(e.path);
            if (i >= 0) p.splice(i, 1); else p.push(e.path);
            sheet.picked = p;
        } else sheet.picked = [e.path];
        sheet.anchorPath = e.path;
    }
    readonly property var pickedStats: {
        let size = 0, packed = 0, last = null;
        for (const e of sheet.here) if (!e.up && sheet.picked.indexOf(e.path) >= 0) { size += e.size; packed += e.packed; last = e; }
        return { size: size, packed: packed, one: sheet.picked.length === 1 ? last : null };
    }

    function extractPicked() {
        sheet.app.archiveSheet = { mode: "extract", archive: sheet.spec.archive, name: sheet.spec.name,
                                   paths: sheet.picked.slice(), password: sheet.password, from: sheet.browseState() };
    }
    function testArchive() { sheet.arc.test(sheet.spec.archive, sheet.password, (sheet.dirStats[""] || {}).size || 0); }
    function deletePicked() {
        if (sheet.picked.length === 0) return;
        if (sheet.arc.isTar(sheet.spec.archive)) {
            sheet.ask = { kind: "message", title: "7-Zip", text: "Operation is not supported for this archive type." };
            return;
        }
        const n = sheet.picked.length;
        const archive = sheet.spec.archive, paths = sheet.picked.slice(), pw = sheet.password;
        sheet.ask = {
            kind: "confirm", title: n === 1 ? "Confirm File Delete" : "Confirm Multiple File Delete",
            text: n === 1 ? "Are you sure you want to delete '" + paths[0].split("/").pop() + "'?"
                          : "Are you sure you want to delete these " + n + " items?",
            then: () => {
                const token = sheet.serial;
                sheet.arc.remove(archive, paths, pw, j => {
                    if (token === sheet.serial && j.state === "done") { sheet.picked = []; sheet.load(); }
                });
            }
        };
    }
    function showInfo() {
        const l = sheet.listing;
        if (!l || !l.entries) return;
        const t = sheet.dirStats[""] || { size: 0, packed: 0, files: 0 };
        let folders = 0;
        for (const e of l.entries) if (e.dir) folders++;
        const i = l.info || {};
        const rows = [["Path", sheet.spec.archive], ["Type", i["Type"] || ""]];
        if (i["Physical Size"]) rows.push(["Physical Size", sheet.grouped(parseInt(i["Physical Size"]))]);
        if (i["Headers Size"]) rows.push(["Headers Size", sheet.grouped(parseInt(i["Headers Size"]))]);
        if (i["Method"]) rows.push(["Method", i["Method"]]);
        if (i["Solid"]) rows.push(["Solid", i["Solid"]]);
        if (i["Blocks"]) rows.push(["Blocks", i["Blocks"]]);
        rows.push(["Folders", String(folders)], ["Files", String(t.files)], ["Size", sheet.grouped(t.size)]);
        if (t.packed) rows.push(["Packed Size", sheet.grouped(t.packed)]);
        if (i["Characteristics"]) rows.push(["Characteristics", i["Characteristics"]]);
        sheet.ask = { kind: "info", title: "Properties", rows: rows };
    }

    readonly property var allCols: [
        { k: "size", t: "Size", w: 92, right: true },
        { k: "packed", t: "Packed Size", w: 92, right: true },
        { k: "mtime", t: "Modified", w: 128 },
        { k: "attrs", t: "Attributes", w: 100 },
        { k: "encrypted", t: "Encrypted", w: 74 },
        { k: "crc", t: "CRC", w: 78 },
        { k: "method", t: "Method", w: 120 }
    ]
    // What fits, in 7-Zip's order, leaving the name at least 220 px; a
    // column the archive has nothing for (a tar's CRC) is left out.
    readonly property var cols: {
        const l = sheet.listing;
        const has = { size: true, mtime: true, attrs: true, packed: false, encrypted: false, crc: false, method: false };
        if (l && l.entries && !sheet.arc.isTar(sheet.spec ? sheet.spec.archive : ""))
            for (const e of l.entries) {
                if (e.packed) has.packed = true;
                if (e.crc) has.crc = true;
                if (e.method) has.method = true;
                has.encrypted = true;
            }
        let room = table.width - 220;
        const out = [];
        for (const c of sheet.allCols) if (has[c.k] && room >= c.w) { out.push(c); room -= c.w; }
        return out;
    }
    readonly property real nameWidth: table.width - sheet.cols.reduce((a, c) => a + c.w, 0)
    function cell(e, k) {
        if (e.up) return "";
        if (k === "size" || k === "packed") return e.dir && !e[k] ? "" : sheet.grouped(e[k]);
        if (k === "mtime") return sheet.stamp(e.mtime);
        if (k === "encrypted") return e.dir ? "" : e.encrypted ? "+" : "-";
        return String(e[k] || "");
    }

    // ══ CRC SHA ═══════════════════════════════════════════════════════════
    property var hashes: null           // Archives.checksum's result, null while working

    function runChecksum(s) {
        const token = sheet.serial;
        sheet.hashes = null;
        sheet.arc.checksum(s.dir, s.names, s.method, r => { if (token === sheet.serial) sheet.hashes = r; });
    }
    // The window's text, as 7-Zip words it.
    readonly property string hashText: {
        const r = sheet.hashes;
        if (!r) return "";
        if (r.error) return r.error;
        const lines = [];
        const sizeLine = n => "Size: " + sheet.grouped(n) + " bytes (" + sheet.svc.humanSize(n) + ")";
        const single = r.files.length === 1 && !r.summary.some(s => s.label === "Folders" && parseInt(s.value) > 0);
        if (single) {
            const f = r.files[0];
            lines.push("Name: " + f.name, sizeLine(f.size));
            for (const h of f.hashes) lines.push(h.label + ": " + h.value);
        } else {
            for (const s of r.summary) {
                if (s.label === "Size") lines.push(sizeLine(parseInt(s.value)));
                else lines.push(s.label + ": " + s.value);
            }
            lines.push("");
            for (const f of r.files) {
                lines.push(f.name);
                for (const h of f.hashes) lines.push("    " + h.label + ": " + h.value);
            }
        }
        return lines.join("\n");
    }

    // ── pieces ────────────────────────────────────────────────────────────
    component Lbl: StyledText {
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink
    }
    component Check: Item {
        id: check
        property bool checked: false
        property bool active: true
        property string label: ""
        signal toggled(bool on)
        implicitWidth: checkRow.implicitWidth
        implicitHeight: 22
        opacity: check.active ? 1 : 0.45
        Row {
            id: checkRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7
            Rectangle {
                width: 15; height: 15
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: check.checked ? Appearance.accent : Appearance.ground
                border.width: check.checked ? 0 : 1
                border.color: Appearance.edge
                StyledText {
                    anchors.centerIn: parent
                    visible: check.checked
                    text: "✓"
                    font.pixelSize: Appearance.fs(11)
                    font.weight: Font.Bold
                    color: Appearance.inkOnAccent
                }
            }
            StyledText {
                visible: check.label !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: check.label
                font.pixelSize: Appearance.fs(12)
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: check.active
            cursorShape: Qt.PointingHandCursor
            onClicked: check.toggled(!check.checked)
        }
    }
    component Field: Rectangle {
        id: field
        property alias text: input.text
        property bool secret: false
        property bool active: true
        property bool mono: false
        signal accepted()
        signal edited(string text)
        implicitHeight: 28
        radius: 4
        opacity: field.active ? 1 : 0.45
        color: Appearance.ground
        border.width: input.activeFocus ? 2 : 1
        border.color: input.activeFocus ? Appearance.accent : Appearance.rule
        function focusIn() { input.forceActiveFocus(); input.selectAll(); }
        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            verticalAlignment: Text.AlignVCenter
            clip: true
            readOnly: !field.active
            color: Appearance.ink
            selectionColor: Appearance.accent
            selectedTextColor: Appearance.inkOnAccent
            font.family: field.mono ? "monospace" : Appearance.fontFamily
            font.pixelSize: Appearance.fs(12)
            echoMode: field.secret ? TextInput.Password : TextInput.Normal
            selectByMouse: true
            onTextEdited: field.edited(text)
            // Enter is the field's, and goes no further: let through, the
            // window behind took it as "open the selected file".
            Keys.onReturnPressed: e => { e.accepted = true; field.accepted(); }
            Keys.onEnterPressed: e => { e.accepted = true; field.accepted(); }
        }
    }
    component ComboRow: Item {
        id: cr
        property string label: ""
        property real labelWidth: 160
        property alias model: combo.model
        property alias value: combo.value
        property alias active: combo.active
        property string suffix: ""
        signal picked(var v)
        implicitHeight: 28
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: cr.labelWidth - 6
            elide: Text.ElideRight
            text: cr.label
            font.pixelSize: Appearance.fs(12)
            opacity: combo.active ? 1 : 0.45
        }
        SevenCombo {
            id: combo
            x: cr.labelWidth
            width: cr.width - cr.labelWidth - (sfx.visible ? sfx.implicitWidth + 8 : 0)
            height: 28
            onPicked: v => cr.picked(v)
        }
        StyledText {
            id: sfx
            visible: cr.suffix !== ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: cr.suffix
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink2
        }
    }
    // A group box's frame and title; what is in it is laid over it.
    component GroupFrame: Item {
        id: gf
        property string title: ""
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 8
            radius: 5
            color: "transparent"
            border.width: 1
            border.color: Appearance.edge
        }
        Rectangle {
            x: 8
            width: gfText.implicitWidth + 8
            height: 16
            color: Appearance.dialog
            StyledText {
                id: gfText
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                text: gf.title
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink2
            }
        }
    }
    component Tool: Item {
        id: tool
        property string icon: ""
        property string label: ""
        property bool active: true
        signal clicked()
        width: Math.max(58, toolText.implicitWidth + 16)
        height: 52
        opacity: tool.active ? 1 : 0.4
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: toolArea.containsMouse && tool.active ? Appearance.hover : "transparent"
        }
        MonoIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 6
            name: tool.icon
            size: 22
            inkColor: Appearance.ink
            accentColor: Appearance.accent
        }
        StyledText {
            id: toolText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            text: tool.label
            font.pixelSize: Appearance.fs(11)
        }
        MouseArea {
            id: toolArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: tool.active
            cursorShape: Qt.PointingHandCursor
            onClicked: tool.clicked()
        }
    }

    // ── the title bar ─────────────────────────────────────────────────────
    Item {
        id: titleBar
        width: parent.width
        height: 38
        visible: sheet.mode !== "extractNow"
        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: closeX.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideMiddle
            text: sheet.mode === "compress" ? "Add to Archive"
                : sheet.mode === "extract" ? "Extract : " + (sheet.spec ? sheet.arc.shortPath(sheet.spec.archive) : "")
                : sheet.mode === "browse" ? (sheet.spec ? sheet.arc.shortPath(sheet.spec.archive) + "/" + (sheet.prefix ? sheet.prefix + "/" : "") : "")
                : sheet.mode === "checksum" ? "Checksum information"
                : ""
            font.pixelSize: Appearance.fs(12.5)
            font.weight: Font.DemiBold
        }
        Rectangle {
            id: closeX
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 26; height: 26; radius: 5
            color: closeArea.containsMouse ? Appearance.accent : "transparent"
            MonoIcon {
                anchors.centerIn: parent
                name: "x"
                size: 14
                inkColor: closeArea.containsMouse ? Appearance.inkOnAccent : Appearance.ink2
                accentColor: inkColor
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sheet.mode === "extract" && sheet.spec.from ? sheet.app.archiveSheet = sheet.spec.from : sheet.close()
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    Item {
        id: body
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        visible: sheet.mode !== "extractNow"
        implicitHeight: sheet.mode === "compress" ? compressForm.implicitHeight
                      : sheet.mode === "extract" ? extractForm.implicitHeight
                      : sheet.mode === "checksum" ? checksumView.implicitHeight
                      : 0

        // ══ Add to Archive ════════════════════════════════════════════════
        Column {
            id: compressForm
            visible: sheet.mode === "compress"
            width: parent.width
            spacing: 10

            Column {
                width: parent.width
                spacing: 4
                Lbl { text: "Archive:" }
                StyledText {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: sheet.cDir.replace(/\/?$/, "/")
                    font.pixelSize: Appearance.fs(11)
                    color: Appearance.ink3
                }
                Row {
                    width: parent.width
                    spacing: 6
                    SevenCombo {
                        width: parent.width - 42
                        editable: true
                        text: sheet.cName
                        model: sheet.arc.formats.map(f => sheet.cName.slice(0, sheet.cName.length - sheet.knownExt(sheet.cName).length) + "." + f.value)
                        onEdited: t => sheet.cName = t
                        onPicked: v => { const ext = sheet.knownExt(v); if (ext) sheet.setFormat(ext.slice(1)); }
                    }
                    DialogButton {
                        width: 36
                        height: 28
                        text: "…"
                        onTriggered: sheet.pick(["--save", "--start", sheet.cDir, "--name", sheet.cName], p => {
                            sheet.cDir = sheet.svc.parent(p);
                            sheet.cName = sheet.svc.basename(p);
                            const ext = sheet.knownExt(p);
                            if (ext && ext.slice(1) !== sheet.cFormat) sheet.setFormat(ext.slice(1));
                        })
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 18

                // ── left: how ────────────────────────────────────────────
                Column {
                    width: (parent.width - 18) / 2
                    spacing: 7
                    ComboRow {
                        width: parent.width
                        label: "Archive format:"
                        model: sheet.arc.formats.map(f => f.value)
                        value: sheet.cFormat
                        onPicked: v => sheet.setFormat(v)
                    }
                    ComboRow {
                        width: parent.width
                        label: "Compression level:"
                        active: !sheet.cStore
                        model: sheet.cTar ? sheet.arc.levels.filter(l => l.value > 0) : sheet.arc.levels
                        value: sheet.cStore ? 0 : sheet.cLevel
                        onPicked: v => { sheet.cLevel = v; sheet.applyDefaults(); }
                    }
                    ComboRow {
                        width: parent.width
                        label: "Compression method:"
                        active: !sheet.cStore && sheet.cLevel > 0 && sheet.cFmt.methods.length > 1
                        model: sheet.cFmt.methods.map((m, i) => ({ label: (i === 0 ? "* " : "") + m, value: m }))
                        value: sheet.cMethod
                        onPicked: v => { sheet.cMethod = v; sheet.applyDefaults(); }
                    }
                    ComboRow {
                        width: parent.width
                        label: "Dictionary size:"
                        active: sheet.cSeven && sheet.cLevel > 0 && sheet.cDictModel.length > 1
                        model: sheet.cDictModel
                        value: sheet.cDict
                        onPicked: v => sheet.cDict = v
                    }
                    ComboRow {
                        width: parent.width
                        label: "Word size:"
                        active: sheet.cSeven && sheet.cLevel > 0 && sheet.cWordModel.length > 0
                        model: sheet.cWordModel
                        value: sheet.cWordModel.length ? sheet.cWord : ""
                        onPicked: v => sheet.cWord = v
                    }
                    ComboRow {
                        width: parent.width
                        label: "Solid Block size:"
                        active: sheet.cFormat === "7z" && sheet.cLevel > 0
                        model: sheet.arc.solidSizes
                        value: sheet.cFormat === "7z" ? sheet.cSolid : ""
                        onPicked: v => sheet.cSolid = v
                    }
                    ComboRow {
                        width: parent.width
                        label: "Number of CPU threads:"
                        active: !sheet.cStore && sheet.cFormat !== "tar.gz" && sheet.cFormat !== "tar.bz2"
                        model: sheet.cThreadModel
                        value: sheet.cThreads
                        suffix: "/ " + sheet.arc.cpus
                        onPicked: v => sheet.cThreads = v
                    }
                    Item {
                        width: parent.width
                        height: 40
                        opacity: sheet.cSeven ? 1 : 0.45
                        Lbl { y: 2; text: "Memory usage for Compressing:" }
                        Lbl { y: 2; anchors.right: parent.right; text: sheet.grouped(sheet.cMemory.pack) + " MB" }
                        Lbl { y: 22; text: "Memory usage for Decompressing:" }
                        Lbl { y: 22; anchors.right: parent.right; text: sheet.grouped(sheet.cMemory.unpack) + " MB" }
                    }
                    Column {
                        width: parent.width
                        spacing: 4
                        Lbl { text: "Split to volumes, bytes:"; opacity: sheet.cSeven ? 1 : 0.45 }
                        SevenCombo {
                            width: parent.width
                            editable: true
                            active: sheet.cSeven
                            text: sheet.cVolume
                            model: sheet.arc.volumeSizes
                            onEdited: t => sheet.cVolume = t
                        }
                    }
                    Column {
                        width: parent.width
                        spacing: 4
                        Lbl { text: "Parameters:"; opacity: sheet.cSeven ? 1 : 0.45 }
                        Field {
                            width: parent.width
                            active: sheet.cSeven
                            mono: true
                            text: sheet.cParams
                            onEdited: t => sheet.cParams = t
                            onAccepted: sheet.submitCompress()
                        }
                    }
                }

                // ── right: what and how safe ─────────────────────────────
                Column {
                    width: (parent.width - 18) / 2
                    spacing: 7
                    ComboRow {
                        width: parent.width
                        labelWidth: 100
                        label: "Update mode:"
                        active: sheet.cSeven
                        model: [{ label: "Add and replace files", value: "add" }, { label: "Update and add files", value: "update" }]
                        value: sheet.cUpdate
                        onPicked: v => sheet.cUpdate = v
                    }
                    ComboRow {
                        width: parent.width
                        labelWidth: 100
                        label: "Path mode:"
                        active: sheet.cSeven || sheet.cFormat === "wim"
                        model: [{ label: "Relative pathnames", value: "relative" }, { label: "Full pathnames", value: "full" },
                                { label: "Absolute pathnames", value: "absolute" }]
                        value: sheet.cPathMode
                        onPicked: v => sheet.cPathMode = v
                    }
                    Item {
                        width: parent.width
                        height: optCol.implicitHeight + 30
                        GroupFrame { anchors.fill: parent; title: "Options" }
                        Column {
                            id: optCol
                            x: 12; y: 22
                            spacing: 4
                            Check { label: "Create SFX archive"; active: false }
                            Check {
                                label: "Compress shared files"
                                active: sheet.arc.hasSevenZip && !sheet.cTar
                                checked: sheet.cShared
                                onToggled: on => sheet.cShared = on
                            }
                            Check {
                                label: "Delete files after compression"
                                active: sheet.arc.hasSevenZip && !sheet.cTar
                                checked: sheet.cDelete
                                onToggled: on => sheet.cDelete = on
                            }
                        }
                    }
                    Item {
                        width: parent.width
                        height: encCol.implicitHeight + 30
                        GroupFrame { anchors.fill: parent; title: "Encryption" }
                        Column {
                            id: encCol
                            x: 12; y: 22
                            width: parent.width - 24
                            spacing: 5
                            opacity: sheet.cFmt.enc.length > 0 ? 1 : 0.45
                            Lbl { text: "Enter password:" }
                            Field {
                                width: parent.width
                                active: sheet.cFmt.enc.length > 0
                                secret: !sheet.cShow
                                text: sheet.cPassword
                                onEdited: t => sheet.cPassword = t
                                onAccepted: sheet.submitCompress()
                            }
                            Lbl { visible: !sheet.cShow; text: "Reenter password:" }
                            Field {
                                visible: !sheet.cShow
                                width: parent.width
                                active: sheet.cFmt.enc.length > 0
                                secret: true
                                text: sheet.cPassword2
                                onEdited: t => sheet.cPassword2 = t
                                onAccepted: sheet.submitCompress()
                            }
                            Check {
                                label: "Show Password"
                                active: sheet.cFmt.enc.length > 0
                                checked: sheet.cShow
                                onToggled: on => sheet.cShow = on
                            }
                            ComboRow {
                                width: parent.width
                                labelWidth: 130
                                label: "Encryption method:"
                                active: sheet.cFmt.enc.length > 1
                                model: sheet.cFmt.enc
                                value: sheet.cFmt.enc.length ? sheet.cEncMethod : ""
                                onPicked: v => sheet.cEncMethod = v
                            }
                            Check {
                                label: "Encrypt file names"
                                active: sheet.cFormat === "7z"
                                checked: sheet.cEncryptNames && sheet.cFormat === "7z"
                                onToggled: on => sheet.cEncryptNames = on
                            }
                        }
                    }
                }
            }

            StyledText {
                visible: sheet.cBlocked
                width: parent.width
                wrapMode: Text.WordWrap
                text: "7-Zip is not installed — install the 7zip package (or p7zip). The tar formats work without it."
                font.pixelSize: Appearance.fs(11)
                color: Appearance.accent
            }
            Item {
                width: parent.width
                height: 34
                Row {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 8
                    DialogButton { text: "OK"; primary: true; enabled: sheet.cName.trim() !== ""; onTriggered: sheet.submitCompress() }
                    DialogButton { text: "Cancel"; onTriggered: sheet.close() }
                }
            }
        }

        // ══ Extract ═══════════════════════════════════════════════════════
        Column {
            id: extractForm
            visible: sheet.mode === "extract"
            width: parent.width
            spacing: 10

            Column {
                width: parent.width
                spacing: 5
                Lbl { text: "Extract to:" }
                Row {
                    width: parent.width
                    spacing: 6
                    SevenCombo {
                        width: parent.width - 42
                        editable: true
                        text: sheet.xBase
                        model: {
                            const out = [sheet.app.cwd.replace(/\/?$/, "/")];
                            if (sheet.spec && sheet.spec.archive) {
                                const own = sheet.svc.parent(sheet.spec.archive).replace(/\/?$/, "/");
                                if (out.indexOf(own) < 0) out.unshift(own);
                            }
                            return out;
                        }
                        onEdited: t => sheet.xBase = t
                    }
                    DialogButton {
                        width: 36
                        height: 28
                        text: "…"
                        onTriggered: sheet.pick(["--directory", "--start", sheet.expand(sheet.xBase) || sheet.app.cwd],
                                                p => sheet.xBase = p.replace(/\/?$/, "/"))
                    }
                }
                Row {
                    width: parent.width
                    spacing: 8
                    Check {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: sheet.xUseFolder
                        onToggled: on => sheet.xUseFolder = on
                    }
                    Field {
                        width: parent.width - 30
                        active: sheet.xUseFolder
                        text: sheet.xFolder
                        onEdited: t => sheet.xFolder = t
                        onAccepted: sheet.submitExtract()
                    }
                }
                StyledText {
                    visible: !!(sheet.spec && sheet.spec.paths && sheet.spec.paths.length)
                    text: sheet.spec && sheet.spec.paths ? sheet.spec.paths.length + " selected object(s)" : ""
                    font.pixelSize: Appearance.fs(11)
                    color: Appearance.ink3
                }
            }

            Row {
                width: parent.width
                spacing: 18
                Column {
                    width: (parent.width - 18) * 0.55
                    spacing: 6
                    Lbl { text: "Path mode:" }
                    SevenCombo {
                        width: parent.width
                        model: [{ label: "Full pathnames", value: "full" }, { label: "No pathnames", value: "none" },
                                { label: "Absolute pathnames", value: "absolute" }]
                        value: sheet.xPathMode
                        onPicked: v => sheet.xPathMode = v
                    }
                    Check {
                        label: "Eliminate duplication of root folder"
                        active: sheet.xPathMode === "full"
                        checked: sheet.xElim
                        onToggled: on => sheet.xElim = on
                    }
                    Item { width: 1; height: 2 }
                    Lbl { text: "Overwrite mode:" }
                    SevenCombo {
                        width: parent.width
                        model: [{ label: "Ask before overwrite", value: "ask" },
                                { label: "Overwrite without prompt", value: "overwrite" },
                                { label: "Skip existing files", value: "skip" },
                                { label: "Auto rename", value: "rename" },
                                { label: "Auto rename existing files", value: "renameExisting" }]
                        value: sheet.xOverwrite
                        onPicked: v => sheet.xOverwrite = v
                    }
                    Check { label: "Restore file security"; active: false }
                }
                Item {
                    width: (parent.width - 18) * 0.45
                    height: pwCol.implicitHeight + 32
                    GroupFrame { anchors.fill: parent; title: "Password" }
                    Column {
                        id: pwCol
                        x: 12; y: 24
                        width: parent.width - 24
                        spacing: 6
                        opacity: sheet.spec && sheet.arc.isTar(sheet.spec.archive) ? 0.45 : 1
                        Field {
                            width: parent.width
                            active: !(sheet.spec && sheet.arc.isTar(sheet.spec.archive))
                            secret: !sheet.xShow
                            text: sheet.xPassword
                            onEdited: t => sheet.xPassword = t
                            onAccepted: sheet.submitExtract()
                        }
                        Check {
                            label: "Show Password"
                            checked: sheet.xShow
                            onToggled: on => sheet.xShow = on
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: 34
                Row {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 8
                    DialogButton { text: "OK"; primary: true; onTriggered: sheet.submitExtract() }
                    DialogButton {
                        text: "Cancel"
                        onTriggered: sheet.app.archiveSheet = sheet.spec.from || null
                    }
                }
            }
        }

        // ══ 7-Zip File Manager ════════════════════════════════════════════
        Item {
            id: browser
            visible: sheet.mode === "browse"
            anchors.fill: parent

            Row {
                id: toolbar
                spacing: 2
                Tool {
                    icon: "download"; label: "Extract"
                    active: !!sheet.listing && sheet.listing.error === ""
                    onClicked: sheet.extractPicked()
                }
                Tool {
                    icon: "check"; label: "Test"
                    active: !!sheet.listing && sheet.listing.error === ""
                    onClicked: sheet.testArchive()
                }
                Tool {
                    icon: "x"; label: "Delete"
                    active: sheet.picked.length > 0 && !!sheet.spec && !sheet.arc.isTar(sheet.spec.archive)
                    onClicked: sheet.deletePicked()
                }
                Tool {
                    icon: "info"; label: "Info"
                    active: !!sheet.listing && sheet.listing.error === ""
                    onClicked: sheet.showInfo()
                }
            }

            // Where in the archive: up, and the path.
            Row {
                id: pathRow
                anchors.top: toolbar.bottom
                anchors.topMargin: 6
                width: parent.width
                spacing: 6
                Rectangle {
                    width: 28; height: 26; radius: 4
                    opacity: sheet.prefix !== "" ? 1 : 0.4
                    color: upArea.containsMouse && sheet.prefix !== "" ? Appearance.hover : Appearance.ground
                    border.width: 1
                    border.color: Appearance.rule
                    MonoIcon {
                        anchors.centerIn: parent
                        name: "chevronUp"
                        size: 14
                        inkColor: Appearance.ink
                        accentColor: Appearance.ink
                    }
                    MouseArea {
                        id: upArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sheet.goUp()
                    }
                }
                Rectangle {
                    width: parent.width - 34
                    height: 26
                    radius: 4
                    color: Appearance.ground
                    border.width: 1
                    border.color: Appearance.rule
                    StyledText {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideLeft
                        text: sheet.spec && sheet.mode === "browse"
                              ? sheet.arc.shortPath(sheet.spec.archive) + "/" + (sheet.prefix ? sheet.prefix + "/" : "") : ""
                        font.pixelSize: Appearance.fs(12)
                    }
                }
            }

            Rectangle {
                id: table
                anchors.top: pathRow.bottom
                anchors.topMargin: 6
                anchors.bottom: status.top
                anchors.bottomMargin: 6
                width: parent.width
                radius: 4
                color: Appearance.ground
                border.width: 1
                border.color: Appearance.rule
                clip: true

                // Column headings, which sort.
                Row {
                    id: heads
                    x: 1; y: 1
                    height: 24
                    Repeater {
                        model: [{ k: "name", t: "Name", w: sheet.nameWidth - 2 }].concat(sheet.cols)
                        Rectangle {
                            required property var modelData
                            width: modelData.w
                            height: 24
                            color: headArea.containsMouse ? Appearance.hover : Appearance.surface
                            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Appearance.rule }
                            StyledText {
                                anchors.fill: parent
                                anchors.leftMargin: 7
                                anchors.rightMargin: 7
                                verticalAlignment: Text.AlignVCenter
                                horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                                elide: Text.ElideRight
                                text: modelData.t + (sheet.sortKey === modelData.k ? (sheet.sortAsc ? "  ▴" : "  ▾") : "")
                                font.pixelSize: Appearance.fs(11.5)
                                color: Appearance.ink2
                            }
                            MouseArea {
                                id: headArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sheet.sortBy(modelData.k)
                            }
                        }
                    }
                }
                Rectangle { anchors.top: heads.bottom; width: parent.width; height: 1; color: Appearance.rule }

                ListView {
                    id: rows
                    anchors.top: heads.bottom
                    anchors.topMargin: 1
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 1
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: sheet.mode === "browse" ? sheet.here : []
                    delegate: Rectangle {
                        id: rowItem
                        required property var modelData
                        readonly property bool chosen: !modelData.up && sheet.picked.indexOf(modelData.path) >= 0
                        readonly property color fg: chosen ? Appearance.inkOnAccent : Appearance.ink
                        width: rows.width
                        height: 24
                        color: chosen ? Appearance.accent : rowArea.containsMouse ? Appearance.hover : "transparent"

                        Item {
                            width: sheet.nameWidth - 2
                            height: parent.height
                            MonoIcon {
                                id: glyph
                                x: 6
                                anchors.verticalCenter: parent.verticalCenter
                                name: rowItem.modelData.up ? "chevronUp" : rowItem.modelData.dir ? "folder" : "file"
                                size: 15
                                inkColor: rowItem.fg
                                accentColor: rowItem.chosen ? rowItem.fg : Appearance.accent
                            }
                            StyledText {
                                anchors.left: glyph.right
                                anchors.leftMargin: 6
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideMiddle
                                text: rowItem.modelData.name + (rowItem.modelData.encrypted && !rowItem.modelData.dir ? " *" : "")
                                font.pixelSize: Appearance.fs(12)
                                color: rowItem.fg
                            }
                        }
                        Row {
                            x: sheet.nameWidth - 2
                            height: parent.height
                            Repeater {
                                model: sheet.cols
                                StyledText {
                                    required property var modelData
                                    width: modelData.w
                                    height: rowItem.height
                                    leftPadding: 7
                                    rightPadding: 7
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                                    elide: Text.ElideRight
                                    text: sheet.cell(rowItem.modelData, modelData.k)
                                    font.pixelSize: Appearance.fs(11.5)
                                    color: rowItem.chosen ? rowItem.fg : Appearance.ink2
                                }
                            }
                        }
                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: m => sheet.click(rowItem.modelData, m.modifiers)
                            onDoubleClicked: sheet.enter(rowItem.modelData)
                        }
                    }
                }

                StyledText {
                    anchors.centerIn: rows
                    width: rows.width - 40
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text !== ""
                    text: !sheet.listing ? "Reading…"
                        : sheet.listing.error !== "" ? (sheet.listing.needsPassword ? "Can not open encrypted archive. Wrong password?" : sheet.listing.error)
                        : sheet.here.length === 0 ? "The archive is empty." : ""
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink3
                }
            }

            // Status bar: 7-Zip's counts and sizes.
            Row {
                id: status
                anchors.bottom: parent.bottom
                width: parent.width
                height: 22
                Repeater {
                    model: [
                        { w: 0.34, t: sheet.picked.length + " / " + sheet.here.filter(e => !e.up).length + " object(s) selected" },
                        { w: 0.18, t: sheet.picked.length ? sheet.grouped(sheet.pickedStats.size) : "" },
                        { w: 0.18, t: sheet.picked.length && sheet.pickedStats.packed ? sheet.grouped(sheet.pickedStats.packed) : "" },
                        { w: 0.30, t: sheet.pickedStats.one ? sheet.stamp(sheet.pickedStats.one.mtime) : "" }
                    ]
                    Rectangle {
                        required property var modelData
                        width: status.width * modelData.w
                        height: status.height
                        color: "transparent"
                        border.width: 1
                        border.color: Appearance.rule
                        StyledText {
                            anchors.fill: parent
                            anchors.leftMargin: 7
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: modelData.t
                            font.pixelSize: Appearance.fs(11)
                            color: Appearance.ink2
                        }
                    }
                }
            }
        }

        // ══ Checksum information ══════════════════════════════════════════
        Column {
            id: checksumView
            visible: sheet.mode === "checksum"
            width: parent.width
            spacing: 10

            Rectangle {
                width: parent.width
                height: Math.min(Math.max(hashEdit.implicitHeight + 16, 90), sheet.maxHeight - 140)
                radius: 4
                color: Appearance.ground
                border.width: 1
                border.color: Appearance.rule
                clip: true
                Flickable {
                    anchors.fill: parent
                    anchors.margins: 8
                    contentWidth: hashEdit.implicitWidth
                    contentHeight: hashEdit.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    TextEdit {
                        id: hashEdit
                        readOnly: true
                        selectByMouse: true
                        text: sheet.hashes ? sheet.hashText : "Calculating…"
                        color: sheet.hashes && sheet.hashes.error ? Appearance.accent : Appearance.ink
                        selectionColor: Appearance.accent
                        selectedTextColor: Appearance.inkOnAccent
                        font.family: "monospace"
                        font.pixelSize: Appearance.fs(12)
                    }
                }
            }
            Item {
                width: parent.width
                height: 34
                Row {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 8
                    DialogButton {
                        text: "Copy"
                        enabled: !!sheet.hashes && !sheet.hashes.error
                        onTriggered: sheet.svc.copyPathToClipboard([sheet.hashText])
                    }
                    DialogButton { text: "OK"; primary: true; onTriggered: sheet.close() }
                }
            }
        }
    }

    // ══ message boxes ═════════════════════════════════════════════════════
    // Over the window they belong to, which waits; or, extracting from the
    // menu with no window of its own, the whole sheet.
    Item {
        anchors.fill: parent
        visible: sheet.ask !== null
        z: 1500

        Rectangle {
            anchors.fill: parent
            visible: sheet.mode !== "extractNow"
            color: Qt.rgba(0, 0, 0, 0.32)
            MouseArea { anchors.fill: parent; hoverEnabled: true }
        }

        Rectangle {
            id: askBox
            readonly property var a: sheet.ask || ({})
            readonly property var cur: askBox.a.kind === "replace" && askBox.a.queue ? askBox.a.queue[askBox.a.at] : null
            property string pw: ""
            property bool showPw: false
            anchors.centerIn: parent
            width: askBox.a.kind === "replace" ? 640 : askBox.a.kind === "info" ? 460 : 400
            height: askCol.implicitHeight + 64
            radius: sheet.mode === "extractNow" ? sheet.radius : 8
            color: Appearance.dialog
            border.width: sheet.mode === "extractNow" ? 0 : 1
            border.color: Appearance.edge

            Connections {
                target: sheet
                function onAskChanged() {
                    askBox.pw = ""; askBox.showPw = false;
                    if (sheet.ask && sheet.ask.kind === "password") pwTimer.restart();
                }
            }
            Timer { id: pwTimer; interval: 30; onTriggered: askPw.focusIn() }

            function done(ok) {
                const a = sheet.ask;
                // Read before the box goes: putting it away clears it.
                const pw = askBox.pw;
                if (!a) return;
                sheet.ask = null;
                if (a.kind === "password") { if (ok && pw !== "") a.then(pw); else if (a.cancel) a.cancel(); }
                else if (a.kind === "confirm") { if (ok) a.then(); }
            }

            Item {
                id: askTitle
                width: parent.width
                height: 36
                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: askBox.a.kind === "replace" ? "Confirm File Replace" : (askBox.a.title || "7-Zip")
                    font.pixelSize: Appearance.fs(12.5)
                    font.weight: Font.DemiBold
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
            }

            Column {
                id: askCol
                anchors.top: askTitle.bottom
                anchors.topMargin: 12
                x: 16
                width: parent.width - 32
                spacing: 10

                // ── Confirm File Replace ──
                Column {
                    visible: askBox.a.kind === "replace"
                    width: parent.width
                    spacing: 8
                    Lbl { text: "Destination folder already contains processed file." }
                    Lbl { text: "Would you like to replace the existing file" }
                    Row {
                        spacing: 10
                        leftPadding: 10
                        MonoIcon { name: "file"; size: 30; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                        Column {
                            spacing: 2
                            Lbl { width: askCol.width - 60; elide: Text.ElideMiddle; text: askBox.cur ? askBox.cur.old.path : "" }
                            Lbl { text: askBox.cur ? sheet.grouped(askBox.cur.old.size) + " bytes" : ""; color: Appearance.ink2 }
                            Lbl { text: askBox.cur ? "modified on " + sheet.stamp(askBox.cur.old.mtime) : ""; color: Appearance.ink2 }
                        }
                    }
                    Lbl { text: "with this one?" }
                    Row {
                        spacing: 10
                        leftPadding: 10
                        MonoIcon { name: "file"; size: 30; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                        Column {
                            spacing: 2
                            Lbl { width: askCol.width - 60; elide: Text.ElideMiddle; text: askBox.cur ? askBox.cur.item.path : "" }
                            Lbl { text: askBox.cur ? sheet.grouped(askBox.cur.item.size) + " bytes" : ""; color: Appearance.ink2 }
                            Lbl { text: askBox.cur && askBox.cur.item.mtime ? "modified on " + sheet.stamp(askBox.cur.item.mtime) : ""; color: Appearance.ink2 }
                        }
                    }
                    StyledText {
                        visible: !!askBox.a.queue && askBox.a.queue.length > 1
                        text: askBox.a.queue ? (askBox.a.at + 1) + " of " + askBox.a.queue.length + " files already there" : ""
                        font.pixelSize: Appearance.fs(11)
                        color: Appearance.ink3
                    }
                    Flow {
                        width: parent.width
                        spacing: 6
                        layoutDirection: Qt.RightToLeft
                        DialogButton { text: "Cancel"; onTriggered: sheet.answer("cancel") }
                        DialogButton { text: "Auto Rename"; onTriggered: sheet.answer("rename") }
                        DialogButton { text: "No to All"; onTriggered: sheet.answer("noAll") }
                        DialogButton { text: "No"; onTriggered: sheet.answer("no") }
                        DialogButton { text: "Yes to All"; onTriggered: sheet.answer("yesAll") }
                        DialogButton { text: "Yes"; primary: true; onTriggered: sheet.answer("yes") }
                    }
                }

                // ── Enter password ──
                Column {
                    visible: askBox.a.kind === "password"
                    width: parent.width
                    spacing: 7
                    Lbl {
                        visible: !!askBox.a.wrong
                        text: "Wrong password?"
                        color: Appearance.accent
                    }
                    Lbl { text: "Enter password:" }
                    Field {
                        id: askPw
                        width: parent.width
                        secret: !askBox.showPw
                        text: askBox.pw
                        onEdited: t => askBox.pw = t
                        onAccepted: askBox.done(true)
                    }
                    Check {
                        label: "Show password"
                        checked: askBox.showPw
                        onToggled: on => askBox.showPw = on
                    }
                    Item {
                        width: parent.width
                        height: 32
                        Row {
                            anchors.right: parent.right
                            spacing: 8
                            DialogButton { text: "OK"; primary: true; enabled: askBox.pw !== ""; onTriggered: askBox.done(true) }
                            DialogButton { text: "Cancel"; onTriggered: askBox.done(false) }
                        }
                    }
                }

                // ── a message, or a yes-or-no ──
                Column {
                    visible: askBox.a.kind === "message" || askBox.a.kind === "confirm"
                    width: parent.width
                    spacing: 14
                    Lbl { width: parent.width; wrapMode: Text.WordWrap; text: askBox.a.text || "" }
                    Item {
                        width: parent.width
                        height: 32
                        Row {
                            anchors.right: parent.right
                            spacing: 8
                            DialogButton {
                                text: askBox.a.kind === "confirm" ? "Yes" : "OK"
                                primary: true
                                onTriggered: askBox.done(true)
                            }
                            DialogButton {
                                visible: askBox.a.kind === "confirm"
                                text: "No"
                                onTriggered: askBox.done(false)
                            }
                        }
                    }
                }

                // ── Properties ──
                Column {
                    visible: askBox.a.kind === "info"
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: askBox.a.kind === "info" ? askBox.a.rows : []
                        Item {
                            required property var modelData
                            width: askCol.width
                            height: Math.max(20, infoVal.implicitHeight)
                            Lbl { text: modelData[0]; color: Appearance.ink2 }
                            Lbl {
                                id: infoVal
                                x: 130
                                width: parent.width - 130
                                wrapMode: Text.WrapAnywhere
                                text: modelData[1]
                            }
                        }
                    }
                    Item {
                        width: parent.width
                        height: 40
                        DialogButton { anchors.right: parent.right; anchors.bottom: parent.bottom; text: "OK"; primary: true; onTriggered: askBox.done(true) }
                    }
                }
            }
        }
    }
}
