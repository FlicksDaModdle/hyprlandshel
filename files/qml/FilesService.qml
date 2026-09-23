pragma Singleton
import QtQuick
import Hyprshell.Backend

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
//   Acting wants GIO where GIO is actually better. `gio trash` is the real
//   freedesktop trash, restorable from any file manager, where `rm` is gone
//   forever, and `gio monitor` is the change feed. Copy and move are cp and
//   mv instead — see the note above them for why. Either way paths go as
//   their own argv entries, so nothing is parsed and nothing can be mangled.
//
// Nothing here holds the current directory: a window does, because there can
// be more than one. This is stateless apart from the clipboard.
QtObject {
    id: root

    // What a cut or copy left for the next paste.
    // { paths: [...], cut: bool }
    property var clipboard: ({ paths: [], cut: false })
    readonly property bool hasClipboard: (clipboard.paths || []).length > 0

    // The last thing that went wrong, for the window's status line. gio is
    // specific — "Permission denied", "No space left on device" — and a file
    // manager that silently fails to copy is worse than no file manager.
    property string lastError: ""

    readonly property string home: Sys.home()

    // ── settings ──────────────────────────────────────────────────────────
    // The file manager's own, kept beside the application rather than in
    // the shell's theme.json, which this only ever reads.
    readonly property string settingsPath:
        Sys.configDir() + "/hyprshell-files/settings.json"

    property var prefs: ({})
    property bool loadingPrefs: false

    function pref(key, fallback) {
        const v = root.prefs[key];
        return v === undefined ? fallback : v;
    }

    function setPref(key, value) {
        if (root.loadingPrefs) return;
        const next = {};
        for (const k in root.prefs) next[k] = root.prefs[k];
        next[key] = value;
        root.prefs = next;
        Sys.writeFile(root.settingsPath, JSON.stringify(next, null, 2) + "\n");
    }

    // Plain properties filled from the file once, not bindings on it: a
    // binding to pref() would depend on `prefs`, and saving replaces
    // `prefs`, so each change would feed itself.
    property string view: "grid"
    property string sortBy: "name"
    property bool sortReverse: false
    property bool showHidden: false
    property int iconSize: 100
    property string bookmarksRaw: ""
    property string terminal: "kitty"

    onViewChanged:         setPref("view", view)
    onSortByChanged:       setPref("sortBy", sortBy)
    onSortReverseChanged:  setPref("sortReverse", sortReverse)
    onShowHiddenChanged:   setPref("showHidden", showHidden)
    onIconSizeChanged:     setPref("iconSize", iconSize)
    onBookmarksRawChanged: setPref("bookmarks", bookmarksRaw)

    function loadPrefs() {
        const text = Sys.readFile(root.settingsPath);
        let p = {};
        if (text) { try { p = JSON.parse(text) || {}; } catch (e) { p = {}; } }
        root.prefs = p;
        root.loadingPrefs = true;
        root.view = pref("view", "grid");
        root.sortBy = pref("sortBy", "name");
        root.sortReverse = pref("sortReverse", false);
        root.showHidden = pref("showHidden", false);
        root.iconSize = pref("iconSize", 100);
        root.bookmarksRaw = pref("bookmarks", "");
        root.terminal = pref("terminal", "kitty");
        root.loadingPrefs = false;
    }

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

    // Comparing two names the way a person reads them, so "file2" comes
    // before "file10".
    //
    // Not localeCompare(a, b, {numeric: true}): Qt's JS engine accepts that
    // third argument and ignores it, falling back to a plain string
    // compare — which is why a folder of hyprshell(1)…(20).bundle sorted
    // (1), (10), (11), … (2), (20). It fails silently, so nothing said so.
    //
    // Each name is walked in runs of digits and non-digits: two digit runs
    // compare as numbers, anything else compares as text, case-insensitively
    // first so "Apple" and "apple" land together rather than all capitals
    // sorting ahead of all lower case.
    function compareNames(a, b) {
        const re = /(\d+|\D+)/g;
        const A = String(a).match(re) || [];
        const B = String(b).match(re) || [];
        const n = Math.min(A.length, B.length);
        for (let i = 0; i < n; i++) {
            const x = A[i], y = B[i];
            const xd = x.charCodeAt(0) >= 48 && x.charCodeAt(0) <= 57;
            const yd = y.charCodeAt(0) >= 48 && y.charCodeAt(0) <= 57;
            if (xd && yd) {
                // Compare as numbers, and when they are equal let the
                // shorter run win so "01" sorts before "1".
                const nx = parseInt(x, 10), ny = parseInt(y, 10);
                if (nx !== ny) return nx < ny ? -1 : 1;
                // Equal numbers, different spellings: the padded one first,
                // which is what `ls -v` and `sort -V` both do — 01 before 1,
                // 010 before 10.
                if (x.length !== y.length) return x.length > y.length ? -1 : 1;
            } else {
                const lx = x.toLowerCase(), ly = y.toLowerCase();
                if (lx !== ly) return lx < ly ? -1 : 1;
                if (x !== y) return x < y ? -1 : 1;
            }
        }
        if (A.length !== B.length) return A.length < B.length ? -1 : 1;
        return 0;
    }

    // Directories first, then by name, the way every file manager does it.

    function sortEntries(list, by, reverse) {
        const dir = reverse ? -1 : 1;
        const sorted = (list || []).slice();
        sorted.sort((a, b) => {
            if (a.dir !== b.dir) return a.dir ? -1 : 1;
            let r = 0;
            if (by === "size") r = a.size - b.size;
            else if (by === "modified") r = a.mtime - b.mtime;
            else if (by === "type") r = root.compareNames(root.typeLabel(a), root.typeLabel(b));
            if (r === 0) r = root.compareNames(a.name, b.name);
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

    // The paths inside a drop. Qt hands back `urls` when the source set
    // them, and otherwise the raw text/uri-list, which also carries comment
    // lines beginning with '#' per the spec.
    function pathsFromDrop(drop) {
        const out = [];
        const add = u => {
            const s = String(u || "").trim();
            if (!s || s.charAt(0) === "#") return;
            if (s.indexOf("file://") !== 0) return;
            let p = s.slice("file://".length);
            try { p = decodeURIComponent(p); } catch (e) {}
            if (p && out.indexOf(p) < 0) out.push(p);
        };
        if (drop.urls && drop.urls.length) for (const u of drop.urls) add(u);
        else if (drop.text) for (const line of String(drop.text).split(/\r?\n/)) add(line);
        return out;
    }

    // A path as a URL Qt will open. Each segment is encoded separately so
    // the separators survive: a name containing '#' would otherwise be read
    // as a fragment and everything after it dropped, and one containing '%'
    // would be read as an escape.
    function fileUrl(path) {
        const parts = String(path).split("/").map(encodeURIComponent);
        return "file://" + parts.join("/");
    }

    // What a file is, in words, for the list view's Type column and the
    // properties panel. From the extension, like the glyph: asking the
    // system for a MIME type per file is a process per file.
    readonly property var extNames: ({
        txt: "Text", md: "Markdown", rst: "Text", log: "Log",
        qml: "QML", js: "JavaScript", ts: "TypeScript", py: "Python",
        sh: "Shell script", bash: "Shell script", zsh: "Shell script",
        fish: "Shell script", lua: "Lua", c: "C source", h: "C header",
        cpp: "C++ source", rs: "Rust", go: "Go", java: "Java", rb: "Ruby",
        php: "PHP", json: "JSON", yaml: "YAML", yml: "YAML", toml: "TOML",
        xml: "XML", ini: "Configuration", conf: "Configuration",
        css: "Stylesheet", html: "HTML", nix: "Nix",
        png: "PNG image", jpg: "JPEG image", jpeg: "JPEG image",
        gif: "GIF image", webp: "WebP image", svg: "SVG image",
        bmp: "Bitmap image", ico: "Icon", avif: "AVIF image", tiff: "TIFF image",
        mp3: "MP3 audio", flac: "FLAC audio", ogg: "Ogg audio", wav: "WAV audio",
        m4a: "AAC audio", opus: "Opus audio", aac: "AAC audio",
        mp4: "MP4 video", mkv: "Matroska video", webm: "WebM video",
        mov: "QuickTime video", avi: "AVI video",
        zip: "ZIP archive", tar: "Tar archive", gz: "Gzip archive",
        xz: "XZ archive", zst: "Zstandard archive", bz2: "Bzip2 archive",
        "7z": "7-Zip archive", rar: "RAR archive",
        pkg: "Package", deb: "Debian package", rpm: "RPM package",
        appimage: "AppImage", pdf: "PDF document", desktop: "Shortcut",
        ttf: "Font", otf: "Font"
    })

    function typeLabel(entry) {
        if (!entry) return "";
        if (entry.dir) return "Folder";
        if (entry.broken) return "Broken link";
        const dot = entry.name.lastIndexOf(".");
        if (dot > 0) {
            const ext = entry.name.slice(dot + 1).toLowerCase();
            if (root.extNames[ext]) return root.extNames[ext]
                                          + (entry.link ? " (link)" : "");
            return ext.toUpperCase() + " file";
        }
        return entry.link ? "Link" : "File";
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


    function buildPlaces() {
        const text = Sys.readFile(root.home + "/.config/user-dirs.dirs") || "";
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

    Component.onCompleted: { loadPrefs(); buildPlaces(); }

    // The item counts beside each place. One process for all of them, and
    // only counted once per open — a count that updates per keystroke would
    // mean walking every one of those directories on every change.
    property var placeCounts: ({})

    property Proc countProc: Proc {
        onFinished: (code, out, err) => {
            const counts = {};
            const lines = out.trim().split("\n");
            const paths = countProc.forPaths || [];
            for (let i = 0; i < paths.length && i < lines.length; i++)
                counts[paths[i]] = parseInt(lines[i], 10) || 0;
            root.placeCounts = counts;
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
    // The sidebar's PINNED section: folders you put there yourself. Kept as a newline-separated list in theme.json, because a
    // path can contain anything except a newline and a NUL, so there is no
    // separator to escape.
    readonly property var bookmarks: {
        const raw = root.bookmarksRaw || "";
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
        root.bookmarksRaw = out.join("\n");
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
        Sys.env("XDG_DATA_HOME") !== "" ? Sys.env("XDG_DATA_HOME") + "/Trash"
                                        : root.home + "/.local/share/Trash"
    readonly property string trashFiles: trashDir + "/files"
    readonly property string trashInfo: trashDir + "/info"

    function isTrash(path) { return path === root.trashFiles; }

    // Where a trashed file came from, so it can go back. The .trashinfo is
    // a small ini beside it; Path is URL-encoded per the spec.
    property var trashOrigins: ({})

    property Proc trashInfoProc: Proc {
        onFinished: (code, out, err) => {
            {
                const map = {};
                // One record per file: name, then its original path.
                for (const rec of out.split("\0")) {
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

    // ── what a thing is ───────────────────────────────────────────────────
    // Everything the properties panel shows that the listing does not
    // already know: permissions, owner, link target, and for a folder the
    // size of what is inside it.
    //
    // A folder's size is `du`, which is a walk of the whole tree, so it is
    // only ever done for the one thing you asked about.
    property var details: ({})
    property bool inspecting: false

    property Proc inspectProc: Proc {
        onFinished: (code, out, err) => {
            root.inspecting = false;
            const f = out.split("\u0000");
            if (f.length < 6) return;
            root.details = {
                path: f[0],
                perms: f[1],
                owner: f[2] + ":" + f[3],
                bytes: parseInt(f[4], 10) || 0,
                target: f[5].trim(),
                items: parseInt(f[6], 10) || 0
            };
        }
    }

    function inspect(path, isDir) {
        root.details = ({});
        root.inspecting = true;
        // NUL between the fields, because every one of them can contain
        // whitespace and the last is a path.
        inspectProc.command = ["sh", "-c",
            'p="$1"; '
            + 'printf "%s\\0" "$p" '
            + '"$(stat -c %A -- "$p" 2>/dev/null)" '
            + '"$(stat -c %U -- "$p" 2>/dev/null)" '
            + '"$(stat -c %G -- "$p" 2>/dev/null)" '
            + '"$(if [ -d "$p" ]; then du -sb -- "$p" 2>/dev/null | cut -f1; '
            + '   else stat -c %s -- "$p" 2>/dev/null; fi)" '
            + '"$(readlink -- "$p" 2>/dev/null)" '
            + '"$(if [ -d "$p" ]; then find "$p" -mindepth 1 -printf . 2>/dev/null | wc -c; '
            + '   else echo 0; fi)"',
            "inspect", path];
        inspectProc.running = true;
    }

    // ── free space ────────────────────────────────────────────────────────
    property string freeSpace: ""

    property Proc dfProc: Proc {
        onFinished: (code, out, err) => {
            // `df -B1 --output=avail` is one number and a header.
            const lines = out.trim().split("\n");
            const n = parseInt(lines[lines.length - 1], 10);
            root.freeSpace = isNaN(n) ? "" : root.humanSize(n) + " free";
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

    property Proc action: Proc {
        onFinished: (code, out, err) => {
            const t = String(err || "").trim();
            if (code === 0) {
                root.lastError = "";
            } else {
                // Whatever the tool said, minus its own name at the front.
                root.lastError = t ? t.split("\n")[0].replace(/^(gio|cp|mv|rm):\s*/, "")
                                   : "That didn't work";
                root.failed(root.lastError);
            }
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

    // Copy and move are cp and mv, not `gio copy` and `gio move`, for two
    // measured reasons:
    //
    //   `gio copy` refuses a directory outright — "Can't recursively copy
    //   directory", exit 1 — so pasting a folder simply did not work. There
    //   is no recursive flag; the option that looks like one, -p, is
    //   --progress. (--preserve is the attribute one, and has no short form,
    //   which is how -p came to be in here claiming to preserve anything.)
    //
    //   Neither gio verb has a conflict policy that suits a shell: the
    //   default overwrites silently, and -i prompts on a terminal that does
    //   not exist, so it would hang. --backup=numbered keeps whatever was
    //   there as name.~1~ and needs nobody to answer a question.
    //
    // cp -a is recursive and does preserve mode, ownership and timestamps;
    // mv handles a cross-device move by copying, the same as gio move. The
    // listing is local-only anyway, since it is `find`.
    function copy(paths, dir) {
        if (!paths || !paths.length) return;
        run(["cp", "-a", "--backup=numbered", "--"].concat(paths).concat([dir]), dir);
    }

    function move(paths, dir) {
        if (!paths || !paths.length) return;
        run(["mv", "--backup=numbered", "--"].concat(paths).concat([dir]), dir);
    }

    // The system clipboard, for "copy path". wl-copy reads the text from
    // stdin rather than argv, so a path containing anything at all — a
    // newline included — survives the trip.
    property Proc clipProc: Proc {}

    function copyPathToClipboard(paths) {
        if (!paths || !paths.length) return;
        clipProc.command = ["sh", "-c",
            'printf %s "$1" | wl-copy 2>/dev/null || printf %s "$1" | xclip -selection clipboard 2>/dev/null',
            "copy-path", paths.join("\n")];
        clipProc.running = true;
    }

    // Deleting outright. The one irreversible thing in here besides
    // emptying the trash, and the window asks before calling it.
    function deletePermanently(paths, dir) {
        if (!paths || !paths.length) return;
        run(["rm", "-rf", "--"].concat(paths), dir);
    }

    // A copy beside the original. cp's own --backup names the *existing*
    // file, which is the wrong way round here, so the name is worked out
    // first: "a report.pdf" becomes "a report (copy).pdf", then
    // "a report (copy 2).pdf". The loop stops at 99 rather than spinning.
    function duplicate(paths, dir) {
        if (!paths || !paths.length) return;
        run(["sh", "-c",
            'for p in "$@"; do '
            + '  b=${p##*/}; d=${p%/*}; '
            + '  case "$b" in *.*) stem=${b%.*}; ext=.${b##*.};; *) stem=$b; ext=;; esac; '
            + '  n=1; '
            + '  while [ -e "$d/$stem (copy$( [ $n -gt 1 ] && echo " $n" ))$ext" ]; do '
            + '    n=$((n+1)); [ $n -gt 99 ] && exit 1; done; '
            + '  cp -a -- "$p" "$d/$stem (copy$( [ $n -gt 1 ] && echo " $n" ))$ext" || exit 1; '
            + 'done',
            "duplicate"].concat(paths), dir);
    }

    // An empty file, the way Explorer's New > Text Document works.
    function newFile(path) {
        run(["sh", "-c", '[ -e "$1" ] && exit 1; : > "$1"', "new-file", path],
            root.parent(path));
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
    // `gio open` consults the same default-application table every GTK app
    // uses, but it is the glib one: on a session with no portal running, or
    // with a mimeapps.list that only xdg-utils understands, it can come back
    // having done nothing at all. xdg-open is the wider net — it falls
    // through desktop-specific openers to its own generic handling — so try
    // gio first and hand off to xdg-open when it fails.
    //
    // This is one `sh -c` rather than two spawns because the fallback has to
    // depend on the first one's exit status. The path is still $1, not
    // interpolated, so a filename remains only a filename.
    function open(path) {
        Sys.execDetached(["sh", "-c",
            'gio open -- "$1" 2>/dev/null || xdg-open "$1" 2>/dev/null || '
            + 'handlr open "$1" 2>/dev/null || mimeopen -n "$1" 2>/dev/null',
            "open-file", path]);
    }

    // Open with a chooser, for when the default is not what you want.
    // Nothing here ships a picker of its own; these are the ones desktops
    // actually provide, tried in turn.
    function openWith(path) {
        Sys.execDetached(["sh", "-c",
            'mimeopen -a "$1" 2>/dev/null || handlr launch "$1" 2>/dev/null || '
            + 'exo-open "$1" 2>/dev/null || gio open -- "$1"',
            "open-with", path]);
    }

    function openTerminal(dir) {
        // No dock table to ask in a standalone app, so the terminal is a
        // setting of its own, defaulting to what the shell ships with.
        const term = root.terminal;
        Sys.execDetached(["sh", "-c",
            'cd "$1" && exec ' + term, "open-term", dir]);
    }
}
