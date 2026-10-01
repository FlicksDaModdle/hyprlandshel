pragma Singleton
import QtQuick
import Hyprshell.Backend

// Archives, the 7-Zip way: what its Explorer menu, its "Add to Archive" and
// "Extract" dialogs, its progress window and its file manager do, done by
// 7-Zip itself — `7zz` (the official 7-Zip, Arch's `7zip`) or `7z` (p7zip).
// tar.gz / tar.xz / tar.zst / tar.bz2 go through GNU tar, which compresses a
// tar in one pass where 7-Zip needs two.
//
// Passwords are written to the tool's stdin, never put in its arguments:
// /proc/PID/cmdline is readable by everyone on the machine. 7-Zip asks for
// one itself when it needs it, and reads the answer from there.
//
// Every operation is a job — see start() — shown as 7-Zip's progress window
// while it is in front, or as a card in the corner once sent to the
// background.
QtObject {
    id: root

    // ── tools ─────────────────────────────────────────────────────────────
    property string sevenZip: ""
    property int cpus: 4
    readonly property bool hasSevenZip: sevenZip !== ""

    property Proc probe: Proc {
        command: ["sh", "-c", "for b in 7zz 7z 7za; do command -v \"$b\" >/dev/null 2>&1 && { echo \"$b\"; break; }; done; nproc 2>/dev/null || echo 4"]
        onFinished: (code, out) => {
            const l = out.trim().split("\n");
            if (l.length > 1) { root.sevenZip = l[0]; root.cpus = parseInt(l[1]) || 4; }
            else root.cpus = parseInt(l[0]) || 4;
        }
    }
    Component.onCompleted: probe.running = true

    // ── what is an archive ────────────────────────────────────────────────
    readonly property var tarSuffixes: [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".tzst",
                                        ".tar.bz2", ".tbz", ".tbz2", ".tar.lz", ".tar.lzma", ".tar"]
    readonly property var sevenSuffixes: [".zip", ".7z", ".rar", ".iso", ".cab", ".wim", ".jar", ".apk",
                                          ".deb", ".rpm", ".cpio", ".lzh", ".lha", ".arj", ".xpi",
                                          ".epub", ".gz", ".bz2", ".xz", ".lzma", ".z", ".001", ".dmg", ".vhd", ".msi"]
    function lower(n) { return String(n || "").toLowerCase(); }
    function isTar(name) { const n = lower(name); return tarSuffixes.some(s => n.endsWith(s)); }
    function isArchive(name) { const n = lower(name); return isTar(name) || sevenSuffixes.some(s => n.endsWith(s)); }
    function stem(name) {
        const n = String(name), l = lower(n);
        for (const s of tarSuffixes.concat(sevenSuffixes))
            if (l.endsWith(s)) return n.slice(0, n.length - s.length) || n;
        return n;
    }
    function canRead(name) { return isTar(name) || hasSevenZip; }

    // ── the "Add to Archive" dialog's choices ─────────────────────────────
    readonly property var levels: [
        { value: 0, label: "0 - Store" }, { value: 1, label: "1 - Fastest" }, { value: 3, label: "3 - Fast" },
        { value: 5, label: "5 - Normal" }, { value: 7, label: "7 - Maximum" }, { value: 9, label: "9 - Ultra" }]
    readonly property var formats: [
        { value: "7z", methods: ["LZMA2", "LZMA", "PPMd", "BZip2"], enc: ["AES-256"], solid: true, dict: true },
        { value: "zip", methods: ["Deflate", "Deflate64", "BZip2", "LZMA", "PPMd"], enc: ["ZipCrypto", "AES-256"], solid: false, dict: true },
        { value: "tar", methods: [], enc: [], store: true },
        { value: "wim", methods: [], enc: [], store: true },
        { value: "tar.gz", methods: ["GZip"], enc: [], tar: true },
        { value: "tar.xz", methods: ["XZ"], enc: [], tar: true },
        { value: "tar.zst", methods: ["Zstandard"], enc: [], tar: true },
        { value: "tar.bz2", methods: ["BZip2"], enc: [], tar: true }
    ]
    function format(v) { return root.formats.find(f => f.value === v) || root.formats[0]; }

    readonly property var dictSizes: ["64 KB", "256 KB", "1 MB", "2 MB", "4 MB", "8 MB", "16 MB", "32 MB",
                                      "64 MB", "128 MB", "256 MB", "512 MB", "1024 MB", "1536 MB"]
    readonly property var wordSizes: [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    readonly property var solidSizes: ["Non-solid", "1 MB", "2 MB", "4 MB", "8 MB", "16 MB", "32 MB", "64 MB",
                                       "128 MB", "256 MB", "512 MB", "1 GB", "2 GB", "4 GB", "8 GB", "16 GB",
                                       "32 GB", "64 GB", "Solid"]
    readonly property var volumeSizes: ["", "10M", "100M", "1000M", "650M - CD", "700M - CD", "4092M - FAT",
                                        "4480M - DVD", "8128M - DVD DL", "23040M - BD"]

    // 7-Zip's own defaults for a level: what the dialog fills in when the
    // level changes.
    function defaults(fmt, method, level) {
        const lv = { 0: 0, 1: 1, 3: 2, 5: 3, 7: 4, 9: 5 }[level];
        const i = lv === undefined ? 3 : lv;
        if (fmt === "7z" && (method === "LZMA2" || method === "LZMA"))
            return { dict: ["64 KB", "64 KB", "1 MB", "16 MB", "32 MB", "64 MB"][i], word: [32, 32, 32, 32, 64, 64][i],
                     solid: ["Non-solid", "8 MB", "128 MB", "2 GB", "4 GB", "4 GB"][i] };
        if (fmt === "7z" && method === "PPMd")
            return { dict: ["1 MB", "4 MB", "4 MB", "16 MB", "64 MB", "192 MB"][i], word: [4, 4, 4, 6, 16, 32][i],
                     solid: ["Non-solid", "8 MB", "128 MB", "2 GB", "4 GB", "4 GB"][i] };
        if (fmt === "7z" && method === "BZip2")
            return { dict: "900 KB", word: 0, solid: ["Non-solid", "8 MB", "128 MB", "2 GB", "4 GB", "4 GB"][i] };
        if (fmt === "zip" && (method === "Deflate" || method === "Deflate64"))
            return { dict: method === "Deflate" ? "32 KB" : "64 KB", word: [0, 32, 32, 32, 64, 128][i], solid: "Non-solid" };
        if (fmt === "zip" && method === "LZMA")
            return { dict: ["64 KB", "64 KB", "1 MB", "16 MB", "32 MB", "64 MB"][i], word: [32, 32, 32, 32, 64, 64][i], solid: "Non-solid" };
        return { dict: "", word: 0, solid: "Non-solid" };
    }
    function bytes(sz) {
        const m = /^([\d.]+)\s*(B|KB|MB|GB)?/i.exec(String(sz));
        if (!m) return 0;
        const k = { B: 1, KB: 1024, MB: 1048576, GB: 1073741824 }[(m[2] || "B").toUpperCase()];
        return parseFloat(m[1]) * k;
    }
    // "16 MB" → "16m", for -md and -ms.
    function switchSize(sz) {
        const m = /^([\d.]+)\s*(KB|MB|GB)/i.exec(String(sz));
        return m ? m[1] + m[2][0].toLowerCase() : "";
    }
    // Roughly 7-Zip's own estimate: LZMA's match finder needs about 11.5x
    // the dictionary per pair of threads; unpacking needs the dictionary.
    function memory(fmt, method, dict, threads, level) {
        if (level === 0 || !method) return { pack: 1, unpack: 1 };
        const d = root.bytes(dict) / 1048576;
        if (method === "LZMA2" || method === "LZMA") {
            const pairs = method === "LZMA" ? 1 : Math.max(1, Math.ceil(threads / 2));
            return { pack: Math.round(pairs * (d * 11.5 + 6) + 2), unpack: Math.round(d + 2) };
        }
        if (method === "PPMd") return { pack: Math.round(d + 2), unpack: Math.round(d + 2) };
        if (method === "BZip2") return { pack: Math.round(threads * 9 + 2), unpack: 7 };
        return { pack: Math.round(threads * 5 + 2), unpack: 2 };
    }

    // ── jobs ──────────────────────────────────────────────────────────────
    // { id, kind: compress | extract | test, phase, title, archive, percent
    //   (-1 unknown), files, current, total, outputSize, started, paused,
    //   background, state: running | done | failed | password | cancelled,
    //   error, output, retry }
    property var jobs: []
    property int nextId: 1
    signal finished(var job)

    function update(id, changes) { root.jobs = root.jobs.map(j => j.id === id ? Object.assign({}, j, changes) : j); }
    function job(id) { return root.jobs.find(j => j.id === id) || null; }
    function dismiss(id) { root.jobs = root.jobs.filter(j => j.id !== id); }

    property Component procComponent: Component { Proc { streaming: true } }
    property var procs: ({})

    // What to call when a job ends, by id: kept out of the job itself,
    // which is copied on every change.
    property var thens: ({})

    function start(spec) {
        const id = root.nextId++;
        root.jobs = root.jobs.concat([{
            id: id, kind: spec.kind, phase: spec.phase || "", title: spec.title, archive: spec.archive || "",
            percent: spec.indeterminate ? -1 : 0, files: 0, current: "",
            total: spec.total || 0, outputSize: 0, started: Date.now(), paused: false, pausedAt: 0, pausedFor: 0,
            background: !!spec.background, state: "running", error: "", output: spec.output || "",
            retry: spec.retry || null, cleanup: spec.cleanup || "", watch: spec.watch || "", ended: 0
        }]);
        if (spec.then) root.thens[id] = spec.then;
        const p = root.procComponent.createObject(root);
        root.procs[id] = p;
        p.line.connect(text => {
            // 7-Zip: "42% 12 + path/being/added" (or "- path" extracting).
            const m = /(\d{1,3})%(?:\s+(\d+))?(?:\s+[+\-UT=]\s+(.*))?/.exec(text);
            const cur = root.job(id);
            if (!m || !cur) return;
            const ch = {};
            if (cur.percent >= 0) ch.percent = parseInt(m[1]);
            if (m[2]) ch.files = parseInt(m[2]);
            if (m[3]) ch.current = m[3].trim();
            root.update(id, ch);
        });
        p.finished.connect((code, out, err) => {
            delete root.procs[id];
            p.destroy();
            const cur = root.job(id);
            if (!cur || cur.state === "cancelled") return;
            if (code === 0) {
                root.update(id, { state: "done", percent: 100, paused: false, ended: Date.now() });
            } else {
                const e = root.explain(err || out, code);
                root.update(id, { state: e.password ? "password" : "failed", error: e.text, paused: false,
                                  ended: Date.now(), log: root.errorLines(err || out) });
                if (cur.cleanup) root.removePartial(cur.cleanup);
            }
            const then = root.thens[id];
            delete root.thens[id];
            if (then) then(root.job(id));
            root.finished(root.job(id));
        });
        p.command = ["sh", "-c", 'cd -- "$1" || exit 1; shift; exec "$@"', "sh", spec.dir].concat(spec.argv);
        p.writeStdin(spec.input || "");
        p.running = true;
        if (spec.sizeOf) root.measure(id, spec.dir, spec.sizeOf);
        return id;
    }

    function cancel(id) {
        const p = root.procs[id];
        const cur = root.job(id);
        root.update(id, { state: "cancelled" });
        delete root.thens[id];
        if (p) { p.sendSignal(18); p.running = false; delete root.procs[id]; p.destroy(); }
        if (cur && cur.cleanup) root.removePartial(cur.cleanup);
        root.dismiss(id);
    }
    function pause(id, on) {
        const p = root.procs[id];
        if (!p) return;
        const cur = root.job(id);
        if (!cur || cur.paused === on) return;
        p.sendSignal(on ? 19 : 18);     // SIGSTOP / SIGCONT
        root.update(id, on ? { paused: true, pausedAt: Date.now() }
                           : { paused: false, pausedFor: cur.pausedFor + Date.now() - cur.pausedAt });
    }
    // How long it has been working, not counting time spent paused.
    function elapsed(j, now) {
        if (!j) return 0;
        const end = j.ended || now;
        return Math.max(0, end - j.started - j.pausedFor - (j.paused ? end - j.pausedAt : 0));
    }
    function background(id, on) { root.update(id, { background: on }); }

    property Proc remover: Proc {}
    function removePartial(path) {
        remover.command = ["sh", "-c", 'rm -f -- "$1" "$1".[0-9][0-9][0-9]', "sh", path];
        remover.running = true;
    }

    // How much there is to do, for the progress window's sizes and speed.
    property Component sizeComponent: Component { Proc {} }
    function measure(id, dir, names) {
        const p = root.sizeComponent.createObject(root);
        p.finished.connect((code, out) => {
            p.destroy();
            const m = /(\d+)\s+total\s*$/.exec(out.trim());
            if (m && root.job(id)) root.update(id, { total: parseInt(m[1]) });
        });
        p.command = ["sh", "-c", 'cd -- "$1" && shift && du -sbc -- "$@" 2>/dev/null | tail -n1', "sh", dir].concat(names);
        p.running = true;
    }
    // What has been written so far, polled while compressing.
    property Proc sizer: Proc {
        onFinished: (code, out) => {
            for (const line of out.split("\n")) {
                const t = line.split("\t");
                if (t.length === 2 && root.job(parseInt(t[0]))) root.update(parseInt(t[0]), { outputSize: parseInt(t[1]) || 0 });
            }
        }
    }
    property Timer sizeTick: Timer {
        interval: 1000
        repeat: true
        running: root.jobs.some(j => j.state === "running" && j.watch !== "")
        onTriggered: {
            if (root.sizer.running) return;
            const args = [];
            for (const j of root.jobs) if (j.state === "running" && j.watch) args.push(String(j.id), j.watch);
            root.sizer.command = ["sh", "-c",
                'while [ $# -ge 2 ]; do s=$(cat -- "$2" "$2".[0-9][0-9][0-9] 2>/dev/null | wc -c); printf "%s\\t%s\\n" "$1" "$s"; shift 2; done',
                "sh"].concat(args);
            root.sizer.running = true;
        }
    }

    // 7-Zip's own words about what went wrong, for the error list.
    function errorLines(text) {
        return String(text || "").split("\n").map(l => l.replace(/[\b\r]/g, "").trim())
            .filter(l => l && !/^7-Zip|^p7zip|^Copyright|bit locale|^Scanning|^\d+%|^$/.test(l)).slice(0, 40);
    }

    function explain(text, code) {
        const t = String(text || "");
        // "Break signaled": 7-Zip asked for a password and found nothing on
        // stdin to read. (A cancel never gets this far.)
        if (/Wrong password|Cannot open encrypted archive|encrypted|password|Break signaled/i.test(t))
            return { password: true, text: "Enter password" + (/Wrong password/i.test(t) ? " — the one given was wrong." : ".") };
        if (/not found/i.test(t) && (code === 127 || code === -1))
            return { password: false, text: "The tool for this isn't installed: " + t.trim() };
        if (/No space left/i.test(t)) return { password: false, text: "There is not enough space on the disk." };
        if (/Permission denied/i.test(t)) return { password: false, text: "Access is denied." };
        if (/Can not open the file as archive|Cannot open the file as archive|not in gzip format|Unexpected end/i.test(t))
            return { password: false, text: "Cannot open the file as archive." };
        if (/CRC Failed|Data Error|Headers Error/i.test(t))
            return { password: false, text: "Data error: the archive is damaged." };
        const lines = t.split("\n").map(l => l.replace(/[\b\r]/g, "").trim())
                       .filter(l => l && !/^7-Zip|^p7zip|^Copyright|bit locale|^Scanning|^\d+%/.test(l));
        return { password: false, text: lines.slice(-2).join(" ") || ("Exited with code " + code) };
    }

    // ── Add to Archive ────────────────────────────────────────────────────
    // o: { dir, names, archive (full path), format, level, method, dict,
    //      word, solid, threads, volume, params, update: add | update,
    //      pathMode: relative | full | absolute, deleteAfter, shared,
    //      password, encMethod, encryptNames }
    function compress(o) {
        const f = root.format(o.format);
        // Never clean up an archive that was there before: adding to it
        // and failing must not delete it.
        const fresh = !Sys.exists(o.archive);
        const name = String(o.archive).split("/").pop();
        const title = "Compressing " + name;
        if (f.tar) {
            const level = Math.max(1, o.level || 1);
            const prog = o.format === "tar.zst" ? "zstd -T" + (o.threads || 0) + " -" + Math.min(19, Math.round(1 + level * 2.1))
                       : o.format === "tar.xz" ? "xz -T" + (o.threads || 0) + " -" + level
                       : o.format === "tar.bz2" ? "bzip2 -" + level
                       : "gzip -" + level;
            return root.start({ kind: "compress", phase: "Compressing", title: title, archive: o.archive, dir: o.dir,
                                indeterminate: true, output: o.archive, cleanup: fresh ? o.archive : "", watch: o.archive, sizeOf: o.names,
                                argv: ["tar", "-I", prog, "-cf", o.archive, "--"].concat(o.names) });
        }
        if (!root.hasSevenZip) {
            if (o.format === "tar")
                return root.start({ kind: "compress", phase: "Compressing", title: title, archive: o.archive, dir: o.dir,
                                    indeterminate: true, output: o.archive, cleanup: fresh ? o.archive : "", watch: o.archive,
                                    argv: ["tar", "-cf", o.archive, "--"].concat(o.names) });
            root.failNow("compress", title, "7-Zip is not installed — install the 7zip package (or p7zip).");
            return;
        }
        const argv = [root.sevenZip, o.update === "update" ? "u" : "a", "-t" + o.format, "-bsp1", "-bso0", "-bse2", "-y"];
        if (!f.store) {
            argv.push("-mx=" + o.level);
            if (o.level > 0 && o.method) {
                if (o.format === "7z") {
                    argv.push("-m0=" + o.method);
                    if (o.dict && o.method !== "BZip2") argv.push("-md=" + root.switchSize(o.dict));
                    if (o.word && (o.method === "LZMA2" || o.method === "LZMA")) argv.push("-mfb=" + o.word);
                    if (o.word && o.method === "PPMd") argv.push("-mo=" + o.word);
                    argv.push("-ms=" + (o.solid === "Non-solid" ? "off" : o.solid === "Solid" ? "on" : root.switchSize(o.solid)));
                } else if (o.format === "zip") {
                    argv.push("-mm=" + o.method);
                    if (o.method === "LZMA" && o.dict) argv.push("-md=" + root.switchSize(o.dict));
                    if (o.word && (o.method === "Deflate" || o.method === "Deflate64" || o.method === "LZMA")) argv.push("-mfb=" + o.word);
                }
            }
            if (o.threads) argv.push("-mmt=" + o.threads);
        }
        if (o.pathMode === "full") argv.push("-spf2");
        else if (o.pathMode === "absolute") argv.push("-spf");
        if (o.deleteAfter) argv.push("-sdel");
        if (o.shared) argv.push("-ssw");
        let input = "";
        if (o.password && f.enc.length > 0) {
            argv.push("-p");                       // asked for on stdin, twice when creating
            if (o.format === "zip") argv.push("-mem=" + (o.encMethod === "ZipCrypto" ? "ZipCrypto" : "AES256"));
            if (o.format === "7z" && o.encryptNames) argv.push("-mhe=on");
            input = o.password + "\n" + o.password + "\n";
        }
        const vol = String(o.volume || "").split(" ")[0];
        if (vol) argv.push("-v" + vol.replace(/M$/i, "m").replace(/K$/i, "k").replace(/G$/i, "g"));
        for (const p of String(o.params || "").split(/\s+/)) if (p) argv.push(p);
        argv.push("--", o.archive);
        return root.start({ kind: "compress", phase: o.update === "update" ? "Updating" : "Adding", title: title,
                            archive: o.archive, dir: o.dir, argv: argv.concat(o.names), input: input,
                            output: o.archive, cleanup: fresh ? o.archive : "",
                            watch: o.archive, sizeOf: o.names });
    }

    // "Add to "name.7z"" and "Add to "name.zip"": the dialog's defaults,
    // without the dialog.
    function quickAdd(dir, names, archive, fmt) {
        const method = root.format(fmt).methods[0] || "";
        const d = root.defaults(fmt, method, 5);
        return root.compress({ dir: dir, names: names, archive: archive, format: fmt, level: 5, method: method,
                               dict: d.dict, word: d.word, solid: d.solid, threads: root.cpus, volume: "",
                               params: "", update: "add", pathMode: "relative" });
    }

    function failNow(kind, title, text) {
        const id = root.nextId++;
        root.jobs = root.jobs.concat([{ id: id, kind: kind, phase: "", title: title, archive: "", percent: 0, files: 0,
                                        current: "", total: 0, outputSize: 0, started: Date.now(), paused: false,
                                        pausedAt: 0, pausedFor: 0, background: false, state: "failed",
                                        error: text, output: "", ended: Date.now(), log: [text] }]);
    }

    // ── what is inside ────────────────────────────────────────────────────
    // then({ entries: [{ path, size, packed, mtime, ctime, dir, encrypted,
    //                    attrs, crc, method }], info: { Type, … },
    //        needsPassword, error })
    property Component listComponent: Component { Proc {} }
    function list(path, password, then) {
        const p = root.listComponent.createObject(root);
        const tar = root.isTar(path);
        p.finished.connect((code, out, err) => {
            p.destroy();
            if (code !== 0) {
                const e = root.explain(err || out, code);
                then({ entries: [], info: {}, needsPassword: e.password, error: e.text });
                return;
            }
            if (tar) then({ entries: root.parseTar(out), info: { Type: "tar" }, needsPassword: false, error: "" });
            else then(Object.assign({ needsPassword: false, error: "" }, root.parseSeven(out)));
        });
        p.command = tar ? ["tar", "-tvf", path, "--full-time"]
                        : [root.sevenZip || "7z", "l", "-slt", "--", path];
        p.writeStdin(password ? password + "\n" : "");
        p.running = true;
    }

    function parseSeven(out) {
        const cut = out.indexOf("\n----------\n");
        const head = cut >= 0 ? out.slice(0, cut) : "";
        const body = cut >= 0 ? out.slice(cut + 12) : out;
        const info = {};
        for (const line of head.split("\n")) {
            const i = line.indexOf(" = ");
            if (i > 0) info[line.slice(0, i).trim()] = line.slice(i + 3);
        }
        const entries = [];
        const when = s => s ? Date.parse(s.replace(" ", "T").slice(0, 19)) / 1000 : 0;
        for (const block of body.split(/\n\s*\n/)) {
            const f = {};
            for (const line of block.split("\n")) {
                const i = line.indexOf(" = ");
                if (i > 0) f[line.slice(0, i).trim()] = line.slice(i + 3);
            }
            if (!f["Path"]) continue;
            const attr = f["Attributes"] || "";
            entries.push({
                path: f["Path"].replace(/\\/g, "/").replace(/\/+$/, ""),
                size: parseInt(f["Size"]) || 0,
                packed: parseInt(f["Packed Size"]) || 0,
                mtime: when(f["Modified"]),
                ctime: when(f["Created"]),
                dir: f["Folder"] === "+" || /^D/.test(attr),
                encrypted: f["Encrypted"] === "+",
                attrs: attr,
                crc: f["CRC"] || "",
                method: f["Method"] || ""
            });
        }
        return { entries: root.withParents(entries), info: info };
    }
    function parseTar(out) {
        const entries = [];
        for (const line of out.split("\n")) {
            const m = /^(\S{10})\s+\S+\s+(\d+)\s+(\d{4}-\d\d-\d\d \d\d:\d\d(?::\d\d)?)\s+(.+)$/.exec(line);
            if (!m) continue;
            entries.push({ path: m[4].replace(/ -> .*$/, "").replace(/\/+$/, ""), size: parseInt(m[2]) || 0, packed: 0,
                           mtime: Date.parse(m[3].replace(" ", "T")) / 1000 || 0, ctime: 0, dir: m[1][0] === "d",
                           encrypted: false, attrs: m[1], crc: "", method: "" });
        }
        return root.withParents(entries);
    }
    function withParents(entries) {
        const have = {};
        for (const e of entries) have[e.path] = true;
        const out = entries.slice();
        for (const e of entries) {
            const parts = e.path.split("/");
            for (let i = 1; i < parts.length; i++) {
                const p = parts.slice(0, i).join("/");
                if (!have[p]) {
                    have[p] = true;
                    out.push({ path: p, size: 0, packed: 0, mtime: 0, ctime: 0, dir: true, encrypted: false,
                               attrs: "D", crc: "", method: "" });
                }
            }
        }
        return out;
    }

    // ── Extract ───────────────────────────────────────────────────────────
    // o: { archive, dest, paths, password, pathMode: full | none | absolute,
    //      eliminateRoot, overwrite: overwrite | skip | rename |
    //      renameExisting, exclude: [archive paths], total, background,
    //      then }
    // "Eliminate duplication of root folder" is the caller's: it is a
    // choice of `dest` (7-Zip's GUI decides it, not its -spe switch, which
    // does nothing of the kind).
    function extract(o) {
        const name = String(o.archive).split("/").pop();
        const title = "Extracting " + name;
        if (root.isTar(o.archive)) {
            // tar can't give the new file another name; it can move the
            // old one aside (file.~1~), which is the nearest it has.
            const argv = ["tar", "-xf", o.archive].concat(
                o.overwrite === "overwrite" ? ["--overwrite"]
              : o.overwrite === "skip" ? ["--skip-old-files"]
              : ["--backup=numbered", "--overwrite"]);
            if (o.pathMode === "none") argv.push("--transform=s,.*/,,");
            if ((o.exclude || []).length) {
                argv.push("--anchored", "--no-wildcards");
                for (const x of o.exclude) argv.push("--exclude=" + x);
            }
            argv.push("-C", o.dest, "--");
            return root.start({ kind: "extract", phase: "Extracting", title: title, archive: o.archive, dir: "/",
                                indeterminate: true, output: o.dest, total: o.total || 0,
                                background: o.background, then: o.then,
                                argv: ["sh", "-c", 'mkdir -p -- "$1" && shift && exec "$@"', "sh", o.dest]
                                      .concat(argv).concat(o.paths || []) });
        }
        if (!root.hasSevenZip) {
            root.failNow("extract", title, "7-Zip is not installed — install the 7zip package (or p7zip).");
            return -1;
        }
        const ao = { overwrite: "-aoa", skip: "-aos", rename: "-aou", renameExisting: "-aot" }[o.overwrite] || "-aou";
        const argv = [root.sevenZip, o.pathMode === "none" ? "e" : "x", "-o" + o.dest, ao,
                      "-bsp1", "-bso0", "-bse2", "-y"];
        if (o.pathMode === "absolute") argv.push("-spf");
        for (const x of (o.exclude || [])) argv.push("-x!" + x);
        argv.push("--", o.archive);
        return root.start({ kind: "extract", phase: "Extracting", title: title, archive: o.archive, dir: "/",
                            argv: argv.concat(o.paths || []), input: o.password ? o.password + "\n" : "",
                            output: o.dest, total: o.total || 0, retry: { op: "extract", opts: o },
                            background: o.background, then: o.then });
    }

    // Which of the archive's files are already at the destination — for
    // "Ask before overwrite", which asks before starting.
    property Component checkComponent: Component { Proc {} }
    // then([{ path, size, mtime }]) — what is there now.
    function clashes(dest, relPaths, then) {
        const p = root.checkComponent.createObject(root);
        p.finished.connect((code, out) => {
            p.destroy();
            const found = [];
            for (const l of out.split("\n")) {
                const t = l.split("\t");
                if (t.length >= 3) found.push({ size: parseInt(t[0]) || 0, mtime: parseInt(t[1]) || 0, path: t.slice(2).join("\t") });
            }
            then(found);
        });
        p.command = ["sh", "-c", 'cd -- "$1" 2>/dev/null || exit 0; while IFS= read -r f; do [ -f "$f" ] && stat -c "%s\t%Y\t%n" -- "$f"; done', "sh", dest];
        p.writeStdin(relPaths.join("\n") + "\n");
        p.running = true;
    }

    function test(archive, password, total) {
        const name = String(archive).split("/").pop();
        if (root.isTar(archive))
            return root.start({ kind: "test", phase: "Testing", title: "Testing " + name, archive: archive, dir: "/",
                                indeterminate: true, argv: ["sh", "-c", 'tar -tf "$1" >/dev/null', "sh", archive] });
        return root.start({ kind: "test", phase: "Testing", title: "Testing " + name, archive: archive, dir: "/",
                            argv: [root.sevenZip || "7z", "t", "-bsp1", "-bso0", "-bse2", "-y", "--", archive],
                            input: password ? password + "\n" : "", total: total || 0,
                            retry: { op: "test", archive: archive, total: total || 0 } });
    }

    // 7-Zip's Delete, inside an archive: rewrites it without these.
    function remove(archive, paths, password, then) {
        const name = String(archive).split("/").pop();
        return root.start({ kind: "delete", phase: "Deleting", title: "Deleting from " + name, archive: archive,
                            dir: "/", indeterminate: false, output: archive, then: then,
                            argv: [root.sevenZip || "7z", "d", "-bsp1", "-bso0", "-bse2", "-y", "--", archive].concat(paths),
                            input: password ? password + "\n" : "" });
    }

    function retryWith(id, password) {
        const j = root.job(id);
        if (!j || !j.retry) return;
        root.dismiss(id);
        if (j.retry.op === "extract") root.extract(Object.assign({}, j.retry.opts, { password: password, background: j.background }));
        else if (j.retry.op === "test") root.test(j.retry.archive, password, j.retry.total);
    }

    // ── CRC SHA ───────────────────────────────────────────────────────────
    // then({ method, files: [{ name, size, hashes: [{ label, value }] }],
    //        summary: [{ label, value }], error })
    readonly property var hashMethods: ["CRC-32", "CRC-64", "SHA-1", "SHA-256", "BLAKE2sp", "*"]
    property Component hashComponent: Component { Proc {} }
    function checksum(dir, names, method, then) {
        const p = root.hashComponent.createObject(root);
        p.finished.connect((code, out, err) => {
            p.destroy();
            if (code !== 0) { then({ method: method, files: [], summary: [], error: root.explain(err || out, code).text }); return; }
            then(Object.assign({ method: method, error: "" }, root.parseHashes(out)));
        });
        p.command = ["sh", "-c", 'cd -- "$1" && shift && exec "$@"', "sh", dir,
                     root.sevenZip || "7z", "h", "-scrc" + method.replace("-", ""), "-bsp0", "--"].concat(names);
        p.running = true;
    }
    // The table between the two rules: the dashes say where each column
    // is, the line above them what it is.
    function parseHashes(out) {
        const lines = out.split("\n");
        const files = [], summary = [];
        let cols = null, header = "", inTable = false;
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (/^-{4,}(\s+-+)*\s*$/.test(line)) {
                if (!cols) {
                    cols = [];
                    const re = /-+/g;
                    let m;
                    while ((m = re.exec(line))) cols.push([m.index, m.index + m[0].length]);
                    header = lines[i - 1] || "";
                    inTable = true;
                } else inTable = false;
                continue;
            }
            if (inTable && cols) {
                const cell = (k) => k === cols.length - 1 ? line.slice(cols[k][0]).trim() : line.slice(cols[k][0], cols[k][1]).trim();
                const name = cell(cols.length - 1);
                const sizeAt = cols.length - 2;
                const hashes = [];
                for (let k = 0; k < sizeAt; k++) {
                    const v = cell(k);
                    if (v) hashes.push({ label: header.slice(cols[k][0], cols[k][1]).trim(), value: v });
                }
                if (hashes.length) files.push({ name: name, size: parseInt(cell(sizeAt)) || 0, hashes: hashes });
                continue;
            }
            const s = /^(\S+)\s+(for data(?: and names)?):\s+(\S+)/.exec(line);
            if (s) { summary.push({ label: s[1] + " " + s[2], value: s[3] }); continue; }
            const c = /^(Folders|Files|Size):\s+(\d+)/.exec(line);
            if (c) summary.push({ label: c[1], value: c[2], count: true });
        }
        return { files: files, summary: summary };
    }

    // ── opening one file from inside ──────────────────────────────────────
    // As 7-Zip's file manager does: out to a temporary folder, then opened.
    property int tempSerial: 0
    function openInside(archive, path, password) {
        const dir = FilesService.home + "/.cache/hyprshell-files/7z-open-" + Date.now() + "-" + (root.tempSerial++);
        const then = j => {
            if (j.state !== "done") return;
            FilesService.open(dir + "/" + path.split("/").pop());
            root.dismiss(j.id);
        };
        root.extract({ archive: archive, dest: dir, paths: [path], password: password, pathMode: "none",
                       overwrite: "overwrite", background: true, then: then });
    }

    function shortPath(p) {
        const home = FilesService.home || "";
        return home && String(p).indexOf(home) === 0 ? "~" + String(p).slice(home.length) : String(p);
    }
}
