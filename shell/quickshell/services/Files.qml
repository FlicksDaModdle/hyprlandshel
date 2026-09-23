pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// The file manager's engine.
//
// Listing is `find`, and everything that *changes* the disk is `gio` — the
// same GIO/GVfs that Nautilus is built on. That split is deliberate:
//
//   Listing wants a format that cannot be misread. `find -printf ... \0`
//   gives NUL-terminated records with the name last, so a file called
//   "we\nird.txt" survives. `gio list` cannot express that name at all —
//   it prints it across two lines, and a line-based reader silently invents
//   two files that do not exist.
//
//   Acting wants GIO's semantics. `gio trash` is the real freedesktop trash,
//   restorable from any file manager, where `rm` is gone forever; `gio move`
//   knows about cross-device copies; `gio mount` reaches removable and
//   network locations. Paths go to it as their own argv entries, so nothing
//   is parsed and nothing can be mangled.
//
// Nothing here holds the current directory: a window does, because there can
// be more than one. This is stateless apart from the clipboard.
Singleton {
    id: root

    // What a cut or copy left for the next paste.
    // { paths: [...], cut: bool }
    property var clipboard: ({ paths: [], cut: false })
    readonly property bool hasClipboard: (clipboard.paths || []).length > 0

    // The last thing that went wrong, for the window's status line. gio is
    // specific — "Permission denied", "No space left on device" — and a file
    // manager that silently fails to copy is worse than no file manager.
    property string lastError: ""

    readonly property string home: Quickshell.env("HOME") || "/home"

    // ── listing ───────────────────────────────────────────────────────────
    // One record per entry: type, dereferenced type, size, mtime, name.
    // The name is last because it is the only field that can contain a tab,
    // and records are NUL-separated because it can contain a newline too.
    // `--` and a leading ./ are not optional: a directory named "-delete"
    // would otherwise be read by find as an option.
    function listCommand(path) {
        return ["find", path, "-mindepth", "1", "-maxdepth", "1",
                // Backslash-t and backslash-zero as literal two-character
                // escapes, which `find` expands itself. They cannot be real
                // control characters here: argv strings are NUL-terminated,
                // so a real NUL cannot be passed to a process at all, and
                // execve would reject the call.
                "-printf", "%y\\t%Y\\t%s\\t%T@\\t%f\\0"];
    }

    function parseListing(text) {
        const out = [];
        for (const rec of String(text || "").split("\0")) {
            if (!rec) continue;
            const f = rec.split("\t");
            if (f.length < 5) continue;
            // Everything after the fourth tab is the name, tabs and all.
            const name = f.slice(4).join("\t");
            if (!name || name === "." || name === "..") continue;
            const kind = f[0] === "l" ? f[1] : f[0];
            out.push({
                name: name,
                hidden: name.charAt(0) === ".",
                dir: kind === "d",
                link: f[0] === "l",
                // A symlink whose target is gone: `find` reports its type as
                // the letter it could not resolve rather than d or f.
                broken: f[0] === "l" && f[1] !== "d" && f[1] !== "f",
                size: parseInt(f[2], 10) || 0,
                mtime: parseFloat(f[3]) || 0
            });
        }
        return out;
    }

    // Directories first, then by name, the way every file manager does it.
    // localeCompare so "Ärger" lands next to "Arger" rather than after "Z".
    function sortEntries(list, by, reverse) {
        const dir = reverse ? -1 : 1;
        const sorted = (list || []).slice();
        sorted.sort((a, b) => {
            if (a.dir !== b.dir) return a.dir ? -1 : 1;
            let r = 0;
            if (by === "size") r = a.size - b.size;
            else if (by === "modified") r = a.mtime - b.mtime;
            if (r === 0) r = a.name.localeCompare(b.name, undefined, { numeric: true });
            return r * dir;
        });
        return sorted;
    }

    // ── names and paths ───────────────────────────────────────────────────
    function join(dir, name) {
        if (dir === "/") return "/" + name;
        return dir.replace(/\/+$/, "") + "/" + name;
    }

    function parent(path) {
        if (!path || path === "/") return "/";
        const cut = path.replace(/\/+$/, "").lastIndexOf("/");
        return cut <= 0 ? "/" : path.slice(0, cut);
    }

    function basename(path) {
        if (!path || path === "/") return "/";
        const parts = path.replace(/\/+$/, "").split("/");
        return parts[parts.length - 1] || "/";
    }

    // "~/.config/quickshell" rather than the full path, for the breadcrumb.
    function pretty(path) {
        if (path === root.home) return "~";
        if (path.indexOf(root.home + "/") === 0) return "~" + path.slice(root.home.length);
        return path;
    }

    // The breadcrumb's segments: [{ label, path }], root first.
    function crumbs(path) {
        const out = [];
        if (path.indexOf(root.home) === 0) {
            out.push({ label: "~", path: root.home });
            const rest = path.slice(root.home.length).replace(/^\/+/, "");
            let at = root.home;
            if (rest) for (const part of rest.split("/")) {
                at = root.join(at, part);
                out.push({ label: part, path: at });
            }
        } else {
            out.push({ label: "/", path: "/" });
            let at = "";
            for (const part of path.split("/")) {
                if (!part) continue;
                at = at + "/" + part;
                out.push({ label: part, path: at });
            }
        }
        return out;
    }

    // ── sizes and times ───────────────────────────────────────────────────
    function humanSize(bytes) {
        if (bytes < 1000) return bytes + " B";
        const units = ["KB", "MB", "GB", "TB"];
        let v = bytes / 1000, i = 0;
        while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
        return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + units[i];
    }

    function humanTime(epoch) {
        if (!epoch) return "";
        const d = new Date(epoch * 1000);
        const now = new Date();
        const sameDay = d.toDateString() === now.toDateString();
        if (sameDay) return Qt.formatTime(d, "HH:mm");
        if (d.getFullYear() === now.getFullYear()) return Qt.formatDate(d, "d MMM");
        return Qt.formatDate(d, "d MMM yyyy");
    }

    // ── the icon for an entry ─────────────────────────────────────────────
    // From the extension, not from a MIME lookup. Asking gio for the content
    // type of every file would be a second process over the whole directory
    // for something only the glyph depends on, and the design's icons are a
    // handful of shapes rather than a full MIME set.
    readonly property var extIcons: ({
        // text and code
        txt: "stickyNote", md: "stickyNote", rst: "stickyNote", log: "stickyNote",
        qml: "code", js: "code", ts: "code", py: "code", sh: "code", bash: "code",
        zsh: "code", fish: "code", lua: "code", c: "code", h: "code", cpp: "code",
        rs: "code", go: "code", java: "code", rb: "code", php: "code",
        json: "code", yaml: "code", yml: "code", toml: "code", xml: "code",
        ini: "code", conf: "code", css: "code", html: "code", nix: "code",
        // pictures
        png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image",
        svg: "image", bmp: "image", ico: "image", avif: "image", tiff: "image",
        // sound and moving pictures
        mp3: "music", flac: "music", ogg: "music", wav: "music", m4a: "music",
        opus: "music", aac: "music",
        mp4: "film", mkv: "film", webm: "film", mov: "film", avi: "film",
        // bundles
        zip: "package", tar: "package", gz: "package", xz: "package",
        zst: "package", bz2: "package", "7z": "package", rar: "package",
        pkg: "package", deb: "package", rpm: "package", appimage: "package",
        // the rest
        pdf: "file", desktop: "panelsTopLeft", ttf: "palette", otf: "palette"
    })

    function iconFor(entry) {
        if (!entry) return "file";
        if (entry.dir) return "folder";
        if (entry.broken) return "x";
        const dot = entry.name.lastIndexOf(".");
        if (dot > 0) {
            const ext = entry.name.slice(dot + 1).toLowerCase();
            if (root.extIcons[ext]) return root.extIcons[ext];
        }
        return "file";
    }

    // Images are shown as themselves. Anything else would need the
    // freedesktop thumbnailers, which is a separate piece of work.
    readonly property var previewExts: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"]

    function canPreview(entry) {
        if (!entry || entry.dir) return false;
        const dot = entry.name.lastIndexOf(".");
        if (dot <= 0) return false;
        return root.previewExts.indexOf(entry.name.slice(dot + 1).toLowerCase()) >= 0;
    }

    // ── places ────────────────────────────────────────────────────────────
    // The XDG user directories, as the sidebar shows them. Read from
    // user-dirs.dirs rather than assumed, because they are translated and
    // relocatable — a German session has ~/Bilder, not ~/Pictures.
    property var places: []

    FileView {
        id: userDirs
        path: (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")) + "/user-dirs.dirs"
        preload: true
        printErrors: false
        onLoaded: root.buildPlaces()
        onLoadFailed: root.buildPlaces()
    }

    function buildPlaces() {
        const text = userDirs.text() || "";
        const dirs = {};
        for (const line of text.split("\n")) {
            const m = /^\s*XDG_([A-Z_]+)_DIR\s*=\s*"(.*)"\s*$/.exec(line);
            if (!m) continue;
            dirs[m[1]] = m[2].replace(/^\$HOME/, root.home);
        }
        const want = [
            { key: "DESKTOP", label: "Desktop", icon: "monitor" },
            { key: "DOCUMENTS", label: "Documents", icon: "stickyNote" },
            { key: "DOWNLOAD", label: "Downloads", icon: "download" },
            { key: "PICTURES", label: "Pictures", icon: "image" },
            { key: "MUSIC", label: "Music", icon: "music" },
            { key: "VIDEOS", label: "Videos", icon: "film" }
        ];
        const out = [{ label: "Home", path: root.home, icon: "home" }];
        for (const w of want) {
            const p = dirs[w.key];
            // A directory that is just $HOME means "not configured", and one
            // that does not exist should not be offered.
            if (!p || p === root.home) continue;
            out.push({ label: w.label, path: p, icon: w.icon });
        }
        out.push({ label: "Trash", path: root.trashFiles, icon: "trash", trash: true });
        root.places = out;
        root.refreshCounts();
    }

    Component.onCompleted: buildPlaces()

    // The item counts beside each place. One process for all of them, and
    // only counted once per open — a count that updates per keystroke would
    // mean walking every one of those directories on every change.
    property var placeCounts: ({})

    Process {
        id: countProc
        stdout: StdioCollector {
            onStreamFinished: {
                const counts = {};
                const lines = text.trim().split("\n");
                const paths = countProc.forPaths || [];
                for (let i = 0; i < paths.length && i < lines.length; i++)
                    counts[paths[i]] = parseInt(lines[i], 10) || 0;
                root.placeCounts = counts;
            }
        }
        // Which paths this run asked about, so the numbers can be matched
        // back to them by position rather than re-derived from `places`,
        // which may have changed by the time the answer arrives.
        property var forPaths: []
    }

    function refreshCounts() {
        const paths = (places || []).map(p => p.path).concat(root.bookmarks);
        if (!paths.length) return;
        countProc.forPaths = paths;
        countProc.command = ["sh", "-c",
            // One dot per entry, counted as characters. `wc -l` would
            // count a newline *inside* a filename as another file — a
            // directory holding "we\\nird.txt" reported one item too many.
            'for d in "$@"; do '
            + 'n=$(find "$d" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null | wc -c); '
            + 'printf "%s\\n" "$n"; done',
            "count"].concat(paths);
        countProc.running = true;
    }

    // ── bookmarks ─────────────────────────────────────────────────────────
    // The design's DOTFILES section: folders you put in the sidebar
    // yourself. Kept as a newline-separated list in theme.json, because a
    // path can contain anything except a newline and a NUL, so there is no
    // separator to escape.
    readonly property var bookmarks: {
        const raw = Config.Appearance.filesBookmarks || "";
        const out = [];
        for (const line of raw.split("\n")) {
            const p = line.trim();
            if (p && out.indexOf(p) < 0) out.push(p);
        }
        return out;
    }

    function isBookmarked(path) { return root.bookmarks.indexOf(path) >= 0; }

    function toggleBookmark(path) {
        if (!path) return;
        const out = root.bookmarks.slice();
        const at = out.indexOf(path);
        if (at >= 0) out.splice(at, 1); else out.push(path);
        Config.Appearance.filesBookmarks = out.join("\n");
        root.refreshCounts();
    }

    // ── the trash ─────────────────────────────────────────────────────────
    // Read straight from the freedesktop layout rather than through
    // `trash://`. `gio trash <file>` writes that layout with no help, but
    // `gio trash --list` and `--empty` go through the gvfs daemon and fail
    // with "Operation not supported" when it is not running — which on a
    // Hyprland session it often is not. The spec is two directories, so
    // this reads them.
    readonly property string trashDir:
        (Quickshell.env("XDG_DATA_HOME") || (root.home + "/.local/share")) + "/Trash"
    readonly property string trashFiles: trashDir + "/files"
    readonly property string trashInfo: trashDir + "/info"

    function isTrash(path) { return path === root.trashFiles; }

    // Where a trashed file came from, so it can go back. The .trashinfo is
    // a small ini beside it; Path is URL-encoded per the spec.
    property var trashOrigins: ({})

    Process {
        id: trashInfoProc
        stdout: StdioCollector {
            onStreamFinished: {
                const map = {};
                // One record per file: name, then its original path.
                for (const rec of text.split("\0")) {
                    if (!rec) continue;
                    const cut = rec.indexOf("\n");
                    if (cut < 0) continue;
                    const name = rec.slice(0, cut);
                    const orig = rec.slice(cut + 1).trim();
                    if (!name || !orig) continue;
                    try { map[name] = decodeURIComponent(orig); }
                    catch (e) { map[name] = orig; }
                }
                root.trashOrigins = map;
            }
        }
    }

    function readTrashInfo() {
        trashInfoProc.command = ["sh", "-c",
            'cd "$1" 2>/dev/null || exit 0; '
            + 'for f in *.trashinfo; do '
            + '  [ -e "$f" ] || continue; '
            + '  n=${f%.trashinfo}; '
            + '  p=$(sed -n "s/^Path=//p" "$f" | head -n1); '
            + '  printf "%s\\n%s\\0" "$n" "$p"; done',
            "trashinfo", root.trashInfo];
        trashInfoProc.running = true;
    }

    // Put one back where it came from. gio move rather than mv, so a file
    // that was trashed from another filesystem still lands correctly.
    function restoreFromTrash(name) {
        const from = root.join(root.trashFiles, name);
        const to = root.trashOrigins[name];
        if (!to) {
            root.lastError = "No record of where that came from";
            root.failed(root.lastError);
            return;
        }
        // The .trashinfo has to go with it, or the trash keeps a record of a
        // file that is no longer there.
        root.lastError = "";
        root.pendingDir = root.trashFiles;
        action.command = ["sh", "-c",
            'gio move -- "$1" "$2" && rm -f -- "$3"',
            "restore", from, to, root.join(root.trashInfo, name + ".trashinfo")];
        action.running = true;
    }

    // Emptying is the one irreversible thing in here, so nothing calls it
    // without asking first — see the window's confirmation bar.
    function emptyTrash() {
        root.lastError = "";
        root.pendingDir = root.trashFiles;
        action.command = ["sh", "-c",
            'rm -rf -- "$1"/* "$1"/.[!.]* "$2"/* "$2"/.[!.]* 2>/dev/null; exit 0',
            "empty", root.trashFiles, root.trashInfo];
        action.running = true;
    }

    // ── free space ────────────────────────────────────────────────────────
    property string freeSpace: ""

    Process {
        id: dfProc
        stdout: StdioCollector {
            onStreamFinished: {
                // `df -B1 --output=avail` is one number and a header.
                const lines = text.trim().split("\n");
                const n = parseInt(lines[lines.length - 1], 10);
                root.freeSpace = isNaN(n) ? "" : root.humanSize(n) + " free";
            }
        }
    }

    function checkFree(path) {
        dfProc.command = ["df", "-B1", "--output=avail", path];
        dfProc.running = true;
    }

    // ── acting on files ───────────────────────────────────────────────────
    // Everything below goes through gio, and every path is its own argv
    // entry. Nothing is interpolated into a shell string, so a file named
    // `; rm -rf ~` is only ever a name.
    signal changed(string path)
    signal failed(string message)

    property string pendingDir: ""

    Process {
        id: action
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t) root.lastError = t.replace(/^gio:\s*/, "");
            }
        }
        onExited: code => {
            if (code === 0) root.lastError = "";
            else if (!root.lastError) root.lastError = "That didn't work";
            if (root.lastError) root.failed(root.lastError);
            root.changed(root.pendingDir);
            root.refreshCounts();
        }
    }

    function run(argv, dir) {
        root.lastError = "";
        root.pendingDir = dir || "";
        action.command = argv;
        action.running = true;
    }

    // Deleting means the trash, always. There is no confirmation because
    // there is nothing to confirm: it is reversible, from here or from any
    // other file manager.
    function trash(paths, dir) {
        if (!paths || !paths.length) return;
        run(["gio", "trash"].concat(paths), dir);
    }

    function makeDirectory(path) {
        run(["gio", "mkdir", path], root.parent(path));
    }

    function rename(path, name) {
        if (!name || name.indexOf("/") >= 0) {
            root.lastError = "A name cannot contain '/'";
            root.failed(root.lastError);
            return;
        }
        run(["gio", "rename", path, name], root.parent(path));
    }

    function copy(paths, dir) {
        if (!paths || !paths.length) return;
        // -p keeps permissions and timestamps; a copy that silently drops
        // the executable bit is a copy that does not work.
        run(["gio", "copy", "-p"].concat(paths).concat([dir]), dir);
    }

    function move(paths, dir) {
        if (!paths || !paths.length) return;
        run(["gio", "move"].concat(paths).concat([dir]), dir);
    }

    function cut(paths) { root.clipboard = { paths: (paths || []).slice(), cut: true }; }
    function copyToClipboard(paths) { root.clipboard = { paths: (paths || []).slice(), cut: false }; }

    function paste(dir) {
        const c = root.clipboard;
        if (!c || !(c.paths || []).length) return;
        if (c.cut) { move(c.paths, dir); root.clipboard = { paths: [], cut: false }; }
        else copy(c.paths, dir);
    }

    // Opening is the desktop's decision, not ours: `gio open` follows the
    // same default-application table every other application uses.
    function open(path) {
        Quickshell.execDetached(["gio", "open", path]);
    }

    function openTerminal(dir) {
        const term = Config.Apps.execFor("appTerm") || "kitty";
        Quickshell.execDetached(["sh", "-c",
            'cd "$1" && exec ' + term, "open-term", dir]);
    }
}
