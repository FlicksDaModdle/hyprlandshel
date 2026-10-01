pragma Singleton
import QtQuick
import Hyprshell.Backend

// Archives: making them, opening them, getting things out of them.
//
// 7-Zip does the work — `7zz` (the official 7-Zip, Arch's `7zip`) or `7z`
// (p7zip) — for ZIP, 7z and everything it reads: RAR, ISO, CAB, WIM, DEB,
// JAR, CPIO and the rest. tar.gz / tar.xz / tar.zst / tar.bz2 go through
// GNU tar instead, which handles a compressed tar in one pass where 7-Zip
// needs two. Without 7-Zip, tar formats still work, and ZIP and 7z are
// offered with a note saying what to install.
//
// Passwords are written to the tool's stdin, never put in its arguments:
// /proc/PID/cmdline is readable by everyone on the machine. 7-Zip asks for
// the password itself when it needs one, and reads the answer from there.
//
// Every operation is a job — [{ id, kind, title, percent, state, … }] —
// shown as a card in the window while it runs, with Cancel, and kept there
// when it fails so the reason can be read.
QtObject {
    id: root

    // ── tools ─────────────────────────────────────────────────────────────
    property string sevenZip: ""          // the binary, or "" when there is none
    property bool probed: false
    readonly property bool hasSevenZip: sevenZip !== ""

    property Proc probe: Proc {
        command: ["sh", "-c", "for b in 7zz 7z 7za; do command -v \"$b\" >/dev/null 2>&1 && { echo \"$b\"; exit 0; }; done; exit 0"]
        onFinished: (code, out) => { root.sevenZip = out.trim(); root.probed = true; }
    }
    Component.onCompleted: probe.running = true

    // ── what is an archive ────────────────────────────────────────────────
    readonly property var tarSuffixes: [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".tzst",
                                        ".tar.bz2", ".tbz", ".tbz2", ".tar.lz", ".tar.lzma", ".tar"]
    readonly property var sevenSuffixes: [".zip", ".7z", ".rar", ".iso", ".cab", ".wim", ".jar", ".apk",
                                          ".deb", ".rpm", ".cpio", ".lzh", ".lha", ".arj", ".xpi",
                                          ".epub", ".gz", ".bz2", ".xz", ".lzma", ".z", ".001"]

    function lower(n) { return String(n || "").toLowerCase(); }
    function isTar(name) { const n = lower(name); return tarSuffixes.some(s => n.endsWith(s)); }
    function isArchive(name) {
        const n = lower(name);
        return isTar(name) || sevenSuffixes.some(s => n.endsWith(s));
    }
    // The name without what makes it an archive: "photos.tar.gz" → "photos".
    function stem(name) {
        const n = String(name);
        const l = lower(n);
        for (const s of tarSuffixes.concat(sevenSuffixes))
            if (l.endsWith(s)) return n.slice(0, n.length - s.length) || n;
        return n;
    }
    function canRead(name) { return isTar(name) || hasSevenZip; }

    // ── jobs ──────────────────────────────────────────────────────────────
    property var jobs: []
    property int nextId: 1
    signal finished(var job)

    function update(id, changes) {
        root.jobs = root.jobs.map(j => j.id === id ? Object.assign({}, j, changes) : j);
    }
    function job(id) { return root.jobs.find(j => j.id === id) || null; }
    function dismiss(id) { root.jobs = root.jobs.filter(j => j.id !== id); }

    property Component procComponent: Component { Proc { streaming: true } }
    property var procs: ({})

    // Runs argv in `dir`, writing `input` to its stdin. `parse` reads a
    // line of output for progress.
    function start(spec) {
        const id = root.nextId++;
        const j = { id: id, kind: spec.kind, title: spec.title, detail: spec.detail || "",
                    percent: spec.indeterminate ? -1 : 0, state: "running", error: "",
                    output: spec.output || "", retry: spec.retry || null, cleanup: spec.cleanup || "" };
        root.jobs = root.jobs.concat([j]);
        const p = root.procComponent.createObject(root);
        root.procs[id] = p;
        p.line.connect(text => {
            const m = /(\d{1,3})%/.exec(text);
            if (m && root.job(id) && root.job(id).percent >= 0) root.update(id, { percent: parseInt(m[1]) });
        });
        p.finished.connect((code, out, err) => {
            delete root.procs[id];
            p.destroy();
            const cur = root.job(id);
            if (!cur || cur.state === "cancelled") return;
            if (code === 0) {
                root.update(id, { state: "done", percent: 100 });
            } else {
                const e = root.explain(err || out, code);
                root.update(id, { state: e.password ? "password" : "failed", error: e.text });
                if (cur.cleanup) root.removePartial(cur.cleanup);
            }
            root.finished(root.job(id));
        });
        p.command = ["sh", "-c", 'cd -- "$1" || exit 1; shift; exec "$@"', "sh", spec.dir].concat(spec.argv);
        p.writeStdin(spec.input || "");
        p.running = true;
        return id;
    }

    function cancel(id) {
        const p = root.procs[id];
        const cur = root.job(id);
        root.update(id, { state: "cancelled" });
        if (p) { p.running = false; delete root.procs[id]; p.destroy(); }
        if (cur && cur.cleanup) root.removePartial(cur.cleanup);
        root.dismiss(id);
    }

    // A half-written archive left behind by a cancel or a failure.
    property Proc remover: Proc {}
    function removePartial(path) {
        remover.command = ["sh", "-c", 'rm -f -- "$1" "$1".[0-9][0-9][0-9]', "sh", path];
        remover.running = true;
    }

    // What went wrong, in words, and whether a password would fix it.
    function explain(text, code) {
        const t = String(text || "");
        // "Break signaled": 7-Zip asked for a password and found nothing
        // on stdin to read. (A cancel never gets this far.)
        if (/Wrong password|Cannot open encrypted archive|encrypted|password|Break signaled/i.test(t))
            return { password: true, text: "This archive needs a password" + (/Wrong/i.test(t) ? " — the one given was wrong." : ".") };
        if (/not found/i.test(t) && code === 127)
            return { password: false, text: "The tool for this isn't installed: " + t.trim() };
        if (/No space left/i.test(t)) return { password: false, text: "The disk is full." };
        if (/Permission denied/i.test(t)) return { password: false, text: "Permission denied — you can't write there." };
        if (/Can not open the file as archive|Cannot open the file as archive|not in gzip format|Unexpected end/i.test(t))
            return { password: false, text: "This file isn't an archive 7-Zip can read, or it is damaged or incomplete." };
        if (/CRC Failed|Data Error|Headers Error/i.test(t))
            return { password: false, text: "The archive is damaged: some data failed its check." };
        const lines = t.split("\n").map(l => l.trim()).filter(l => l && !/^7-Zip|^p7zip|^Copyright|^\d+-bit|^Scanning|^$/.test(l));
        return { password: false, text: lines.slice(-2).join(" ") || ("Exited with code " + code) };
    }

    // ── making one ────────────────────────────────────────────────────────
    // opts: { dir, names, out (file name), format: zip|7z|tar.gz|tar.xz|
    //         tar.zst|tar.bz2, level: 0-9, password, encryptNames,
    //         volume: "" | "100m" | … }
    readonly property var formats: [
        { value: "zip", label: "ZIP", note: "Opens anywhere — Windows, macOS, phones" },
        { value: "7z", label: "7z", note: "Smallest; needs 7-Zip or similar to open" },
        { value: "tar.zst", label: "tar.zst", note: "Fast and small; keeps Linux permissions" },
        { value: "tar.xz", label: "tar.xz", note: "Small; keeps Linux permissions" },
        { value: "tar.gz", label: "tar.gz", note: "Readable by everything Unix" }
    ]
    function suffixFor(format) { return "." + format; }
    function supportsPassword(format) { return format === "zip" || format === "7z"; }

    function compress(o) {
        const out = o.out;
        const level = Math.max(0, Math.min(9, o.level === undefined ? 5 : o.level));
        const full = o.dir.replace(/\/+$/, "") + "/" + out;
        const title = "Compressing " + (o.names.length === 1 ? o.names[0] : o.names.length + " items");
        if (o.format === "zip" || o.format === "7z") {
            if (!root.hasSevenZip) {
                root.failNow("compress", title, "ZIP and 7z need 7-Zip — install the 7zip package (or p7zip).");
                return;
            }
            const argv = [root.sevenZip, "a", "-t" + o.format, "-mx=" + level, "-bsp1", "-bso0", "-bse2", "-y"];
            if (o.format === "7z") argv.push("-mmt=on");
            let input = "";
            if (o.password && root.supportsPassword(o.format)) {
                // -p with no value: 7-Zip asks, twice when creating.
                argv.push("-p");
                if (o.format === "zip") argv.push("-mem=AES256");
                if (o.format === "7z" && o.encryptNames) argv.push("-mhe=on");
                input = o.password + "\n" + o.password + "\n";
            }
            if (o.volume) argv.push("-v" + o.volume);
            argv.push("--", out);
            return root.start({ kind: "compress", title: title, detail: out, dir: o.dir,
                                argv: argv.concat(o.names), input: input, output: full, cleanup: full });
        }
        // tar, through the compressor the format names, at the level asked.
        const prog = o.format === "tar.zst" ? "zstd -T0 -" + Math.max(1, Math.round(1 + level * 2.1))
                   : o.format === "tar.xz" ? "xz -T0 -" + level
                   : o.format === "tar.bz2" ? "bzip2 -" + Math.max(1, level)
                   : "gzip -" + Math.max(1, level);
        return root.start({ kind: "compress", title: title, detail: out, dir: o.dir, indeterminate: true,
                            argv: ["tar", "-I", prog, "-cf", out, "--"].concat(o.names),
                            output: full, cleanup: full });
    }

    function failNow(kind, title, text) {
        const id = root.nextId++;
        root.jobs = root.jobs.concat([{ id: id, kind: kind, title: title, detail: "", percent: 0,
                                        state: "failed", error: text, output: "" }]);
    }

    // ── what is inside ────────────────────────────────────────────────────
    // `then` gets { entries: [{ path, size, packed, mtime, dir, encrypted }],
    //               needsPassword, error }.
    property Component listComponent: Component { Proc {} }
    function list(path, password, then) {
        const p = root.listComponent.createObject(root);
        const tar = root.isTar(path);
        p.finished.connect((code, out, err) => {
            p.destroy();
            if (code !== 0) {
                const e = root.explain(err || out, code);
                then({ entries: [], needsPassword: e.password, error: e.text });
                return;
            }
            then({ entries: tar ? root.parseTar(out) : root.parseSeven(out), needsPassword: false, error: "" });
        });
        p.command = tar ? ["tar", "-tvf", path, "--full-time"]
                        : [root.sevenZip || "7z", "l", "-slt", "-ba", "--", path];
        p.writeStdin(password ? password + "\n" : "");
        p.running = true;
    }

    function parseSeven(out) {
        const entries = [];
        for (const block of out.split(/\n\s*\n/)) {
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
                mtime: f["Modified"] ? Date.parse(f["Modified"].replace(" ", "T").slice(0, 19)) / 1000 : 0,
                dir: f["Folder"] === "+" || /^D/.test(attr) || /\bD\b/.test(attr.split(" ")[0] || ""),
                encrypted: f["Encrypted"] === "+"
            });
        }
        return root.withParents(entries);
    }
    // "-rw-r--r-- user/group 1234 2026-10-01 03:32:01 path"
    function parseTar(out) {
        const entries = [];
        for (const line of out.split("\n")) {
            const m = /^(\S)\S*\s+\S+\s+(\d+)\s+(\d{4}-\d\d-\d\d \d\d:\d\d(?::\d\d)?)\s+(.+)$/.exec(line);
            if (!m) continue;
            const path = m[4].replace(/ -> .*$/, "").replace(/\/+$/, "");
            entries.push({ path: path, size: parseInt(m[2]) || 0, packed: 0,
                           mtime: Date.parse(m[3].replace(" ", "T")) / 1000 || 0,
                           dir: m[1] === "d", encrypted: false });
        }
        return root.withParents(entries);
    }
    // Archives need not list a folder before what is in it.
    function withParents(entries) {
        const have = {};
        for (const e of entries) have[e.path] = true;
        const out = entries.slice();
        for (const e of entries) {
            const parts = e.path.split("/");
            for (let i = 1; i < parts.length; i++) {
                const p = parts.slice(0, i).join("/");
                if (!have[p]) { have[p] = true; out.push({ path: p, size: 0, packed: 0, mtime: 0, dir: true, encrypted: false }); }
            }
        }
        return out;
    }

    // ── getting things out ────────────────────────────────────────────────
    // opts: { archive (full path), dest (full path), paths: [] (all when
    //         empty), password, overwrite: "rename" | "skip" | "overwrite" }
    function extract(o) {
        const name = String(o.archive).split("/").pop();
        const title = "Extracting " + name;
        const parent = o.dest;
        if (root.isTar(o.archive)) {
            // tar cannot give a clashing file a new name, so "keep both"
            // keeps the one already there.
            const argv = ["tar", "-xf", o.archive];
            argv.push(o.overwrite === "overwrite" ? "--overwrite" : "--skip-old-files");
            argv.push("-C", o.dest, "--");
            return root.start({ kind: "extract", title: title, detail: root.shortPath(o.dest), dir: "/",
                                indeterminate: true, output: o.dest,
                                argv: ["sh", "-c", 'mkdir -p -- "$1" && shift && exec "$@"', "sh", o.dest]
                                      .concat(argv).concat(o.paths || []) });
        }
        if (!root.hasSevenZip) {
            root.failNow("extract", title, "Opening this needs 7-Zip — install the 7zip package (or p7zip).");
            return;
        }
        const ao = o.overwrite === "skip" ? "-aos" : o.overwrite === "overwrite" ? "-aoa" : "-aou";
        const argv = [root.sevenZip, "x", "-o" + o.dest, ao, "-bsp1", "-bso0", "-bse2", "-y", "--", o.archive];
        // A folder named on its own brings everything under it.
        const picks = [];
        for (const p of (o.paths || [])) { picks.push(p); }
        return root.start({ kind: "extract", title: title, detail: root.shortPath(o.dest), dir: "/",
                            argv: argv.concat(picks), input: o.password ? o.password + "\n" : "",
                            output: o.dest,
                            retry: { op: "extract", opts: o } });
    }

    // Checks every file in it against its checksum.
    function test(archive, password) {
        const name = String(archive).split("/").pop();
        if (root.isTar(archive))
            return root.start({ kind: "test", title: "Testing " + name, dir: "/", indeterminate: true,
                                argv: ["sh", "-c", 'tar -tf "$1" >/dev/null', "sh", archive] });
        return root.start({ kind: "test", title: "Testing " + name, dir: "/",
                            argv: [root.sevenZip || "7z", "t", "-bsp1", "-bso0", "-bse2", "--", archive],
                            input: password ? password + "\n" : "",
                            retry: { op: "test", archive: archive } });
    }

    // A job that failed for want of a password, run again with one.
    function retryWith(id, password) {
        const j = root.job(id);
        if (!j || !j.retry) return;
        root.dismiss(id);
        if (j.retry.op === "extract") root.extract(Object.assign({}, j.retry.opts, { password: password }));
        else if (j.retry.op === "test") root.test(j.retry.archive, password);
    }

    function shortPath(p) {
        const home = FilesService.home || "";
        return home && String(p).indexOf(home) === 0 ? "~" + String(p).slice(home.length) : String(p);
    }
}
