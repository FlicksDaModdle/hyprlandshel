import QtQuick
import Hyprshell
import Hyprshell.Backend

// The file manager.
//
// Same shape as Settings: this file owns the state and the two kinds of
// window it can be mounted in, and FilesFrame.qml is the chrome. Floating is
// a layer-shell surface with our own title bar — the design's own window —
// and tiled is an ordinary toplevel that Hyprland lays out like any other
// application.
//
// Everything that touches the disk is in services/Files.qml. This holds only
// what a *window* knows: where it is, what is selected, and how you got here.
QtObject {
    id: root

    readonly property var svc: FilesService

    // ── where we are ──────────────────────────────────────────────────────
    property string cwd: ""
    property var entries: []
    property bool loading: false

    // Back and forward, as a stack with a cursor rather than two stacks:
    // going back then somewhere new should drop the forward history, which
    // is what truncating at the cursor does.
    property var history: []
    property int historyAt: -1
    readonly property bool canBack: historyAt > 0
    readonly property bool canForward: historyAt >= 0 && historyAt < history.length - 1
    readonly property bool canUp: cwd !== "/" && cwd !== ""

    // ── how it is shown ───────────────────────────────────────────────────
    readonly property string view: FilesService.view          // grid | list
    readonly property string sortBy: FilesService.sortBy      // name | size | modified
    readonly property bool sortReverse: FilesService.sortReverse
    readonly property bool showHidden: FilesService.showHidden

    // ── what is picked ────────────────────────────────────────────────────
    // Names, not indices: the listing is rebuilt on every change, and an
    // index would follow whatever happened to land in that slot.
    property var selection: []
    // The name being renamed in place, and the name of a new folder waiting
    // to be typed. Empty means neither is happening.
    property string renaming: ""
    property bool creatingFolder: false
    property bool creatingFile: false
    property bool confirmingEmpty: false

    // Filtering the folder you are in, the way both Nautilus and Explorer
    // do it: not a search of the disk, just this directory narrowed as you
    // type. Empty means everything.
    property string filter: ""
    property bool filtering: false

    // What the properties panel is showing, or null.
    property var propertiesFor: null
    // The archive sheet (ArchiveSheet.qml): { mode: compress | extract |
    // browse, … }, or null.
    property var archiveSheet: null

    // The sidebar can be put away, for a narrow window.
    property bool showSidebar: true

    // What a file dialog will accept, as a list of patterns. Empty means
    // everything, which is what an ordinary window always is.
    property var kindFilter: []

    readonly property var visibleEntries: {
        let all = root.showHidden ? root.entries : root.entries.filter(e => !e.hidden);
        // Folders are never filtered out: the file someone is after is
        // usually in one of them, and a dialog that hides the way there
        // is a dialog that cannot be used.
        const kind = root.svc.matcher(root.kindFilter);
        if (kind) all = all.filter(e => e.dir || kind(e.name));
        const q = root.filter.trim().toLowerCase();
        if (q !== "") all = all.filter(e => e.name.toLowerCase().indexOf(q) >= 0);
        return root.svc.sortEntries(all, root.sortBy, root.sortReverse);
    }

    // Whether this listing is broken into date groups. Only when the sort
    // is by date — grouping a name-sorted list would scatter the groups
    // through it — and never in the trash, where the date shown is when a
    // thing was deleted and the columns are different anyway.
    readonly property bool grouping:
        root.svc.groupByDate && root.sortBy === "modified" && !root.inTrash

    // The heading that belongs *above* entry `i`, or "" when it carries on
    // from the one before it. Deliberately a lookup beside the list rather
    // than headings spliced into it: selection, shift-ranges, type-ahead
    // and the drag all index into visibleEntries, and every one of them
    // would have to learn to skip a heading.
    function groupAt(i) {
        if (!root.grouping) return "";
        const list = root.visibleEntries;
        if (i < 0 || i >= list.length) return "";
        // Folders sort ahead of files regardless, so they are their own
        // run and get their own heading rather than being dated.
        const here = list[i].dir ? "Folders" : root.svc.dateGroup(list[i].mtime);
        if (i === 0) return here;
        const prev = list[i - 1].dir ? "Folders" : root.svc.dateGroup(list[i - 1].mtime);
        return here === prev ? "" : here;
    }

    // Go to where something lives and pick it out, which is what every
    // desktop means by "show this in a file manager". A folder is opened
    // rather than revealed — nobody asking to see a folder wants its
    // parent — unless it is what was explicitly asked for.
    function reveal(path, asFolder) {
        if (!path) return;
        if (asFolder) { root.go(path); return; }
        const dir = root.svc.parent(path);
        const name = root.svc.basename(path);
        root.go(dir);
        // The listing arrives asynchronously, so the selection waits for
        // it rather than being set against the folder we just left.
        root.pendingSelect = name;
    }

    // Set by reveal(), consumed the next time a listing lands.
    property string pendingSelect: ""
    // Likewise for ShowItemProperties, which wants the sheet open on it.
    property string pendingProperties: ""
    onEntriesChanged: {
        const wantSel = root.pendingSelect;
        const wantProps = root.pendingProperties;
        if (wantSel === "" && wantProps === "") return;
        root.pendingSelect = "";
        root.pendingProperties = "";
        const find = n => root.entries.find(e => e.name === n) || null;
        const sel = find(wantSel || wantProps);
        if (sel) {
            root.selection = [sel.name];
            root.anchor = sel.name;
            if (wantProps !== "") root.propertiesFor = sel;
        }
    }

    // Typing a letter with no field focused jumps to the next entry
    // starting with it, which is how a file list has always behaved.
    property string typeAhead: ""
    property var typeAheadClear: Timer {
        interval: 900
        onTriggered: root.typeAhead = ""
    }

    function jumpTo(letters) {
        root.typeAhead += letters.toLowerCase();
        root.typeAheadClear.restart();
        const list = root.visibleEntries;
        const hit = list.find(e => e.name.toLowerCase().indexOf(root.typeAhead) === 0);
        if (hit) { root.selection = [hit.name]; root.anchor = hit.name; }
    }

    readonly property bool inTrash: root.svc.isTrash(root.cwd)

    // ── navigation ────────────────────────────────────────────────────────
    function go(path, record) {
        if (!path) return;
        if (record !== false) {
            const trimmed = root.history.slice(0, root.historyAt + 1);
            if (trimmed[trimmed.length - 1] !== path) trimmed.push(path);
            root.history = trimmed;
            root.historyAt = trimmed.length - 1;
        }
        root.cwd = path;
        root.selection = [];
        root.anchor = "";
        root.filter = "";
        root.filtering = false;
        root.propertiesFor = null;
        root.renaming = "";
        root.creatingFolder = false;
        root.confirmingEmpty = false;
        root.reload();
        root.svc.checkFree(path);
            }

    function back() {
        if (!canBack) return;
        root.historyAt -= 1;
        root.go(root.history[root.historyAt], false);
    }

    function forward() {
        if (!canForward) return;
        root.historyAt += 1;
        root.go(root.history[root.historyAt], false);
    }

    function up() { if (canUp) root.go(root.svc.parent(root.cwd)); }

    // Opening something in a dialog means choosing it, not launching it —
    // a Save dialog that started the document you were about to overwrite
    // would be a trap. The dialog sets `dialogMode` and listens instead.
    property bool dialogMode: false
    signal activateRequested(var entry)

    function activate(entry) {
        if (!entry) return;
        if (root.dialogMode) { root.activateRequested(entry); return; }
        if (entry.dir) root.go(root.svc.join(root.cwd, entry.name));
        // An archive opens here, to look inside, as a folder would — "Open
        // with…" still hands it to anything else.
        else if (Archives.isArchive(entry.name) && Archives.canRead(entry.name)) root.browseArchive(entry);
        else root.svc.open(root.svc.join(root.cwd, entry.name));
    }

    // ── archives ──────────────────────────────────────────────────────────
    // 7-Zip's menu, its "Add to Archive" and "Extract" dialogs and its file
    // manager: ArchiveSheet.qml, from what this is set to.
    function compressSelected() {
        if (root.selection.length === 0) return;
        root.archiveSheet = { mode: "compress", names: root.selection.slice(), dir: root.cwd };
    }
    function quickAdd(name, format) {
        if (root.selection.length === 0) return;
        Archives.quickAdd(root.cwd, root.selection.slice(), root.svc.join(root.cwd, name), format);
        root.pendingSelect = name;
    }
    function checksumSelected(method) {
        if (root.selection.length === 0) return;
        root.archiveSheet = { mode: "checksum", dir: root.cwd, names: root.selection.slice(), method: method };
    }
    function browseArchive(entry) {
        root.archiveSheet = { mode: "browse", archive: root.svc.join(root.cwd, entry.name), name: entry.name };
    }
    function extractTo(entry) {
        root.archiveSheet = { mode: "extract", archive: root.svc.join(root.cwd, entry.name), name: entry.name };
    }
    // Extract Here and Extract to "name/", as 7-Zip's menu does them:
    // straight away, asking only before overwriting something.
    function extractHere(entry) {
        root.archiveSheet = { mode: "extractNow", opts: {
            archive: root.svc.join(root.cwd, entry.name), dest: root.cwd, paths: [], password: "",
            pathMode: "full", eliminateRoot: false, overwrite: "ask" } };
    }
    function extractToFolder(entry) {
        root.archiveSheet = { mode: "extractNow", opts: {
            archive: root.svc.join(root.cwd, entry.name), dest: root.svc.join(root.cwd, Archives.stem(entry.name)),
            paths: [], password: "", pathMode: "full", eliminateRoot: true, overwrite: "ask" } };
    }

    // ── selection ─────────────────────────────────────────────────────────
    // Where a shift-range starts. Set by any plain or toggling click, so
    // shift-clicking extends from the last thing you actually picked rather
    // than from wherever the selection happens to begin.
    property string anchor: ""

    function isSelected(name) { return root.selection.indexOf(name) >= 0; }

    function select(name, add) {
        root.anchor = name;
        if (!add) { root.selection = [name]; return; }
        const out = root.selection.slice();
        const at = out.indexOf(name);
        if (at >= 0) out.splice(at, 1); else out.push(name);
        root.selection = out;
    }

    // Shift-click: everything between the anchor and here, in the order the
    // view is showing them — which is why it works off visibleEntries and
    // not off the raw listing.
    function selectTo(name, add) {
        const list = root.visibleEntries;
        const to = list.findIndex(e => e.name === name);
        if (to < 0) return;
        let from = list.findIndex(e => e.name === root.anchor);
        if (from < 0) from = to;
        const lo = Math.min(from, to), hi = Math.max(from, to);
        const range = list.slice(lo, hi + 1).map(e => e.name);
        if (!add) { root.selection = range; return; }
        const out = root.selection.slice();
        for (const n of range) if (out.indexOf(n) < 0) out.push(n);
        root.selection = out;
    }

    // The click handlers all go through here, so the three modifier
    // combinations behave the same in both views.
    function clickSelect(name, mods) {
        if (mods & Qt.ShiftModifier) root.selectTo(name, (mods & Qt.ControlModifier) !== 0);
        else root.select(name, (mods & Qt.ControlModifier) !== 0);
    }

    function selectAll() { root.selection = root.visibleEntries.map(e => e.name); }

    function selectNone() { root.selection = []; root.anchor = ""; }

    function invertSelection() {
        const out = [];
        for (const e of root.visibleEntries) if (!root.isSelected(e.name)) out.push(e.name);
        root.selection = out;
    }

    // What the status bar totals. Directories are counted as items, not as
    // bytes: a recursive size is a walk of the disk, and doing one every
    // time the selection changes would make selecting things slow.
    readonly property real selectedBytes: {
        let n = 0;
        for (const e of root.visibleEntries)
            if (root.isSelected(e.name) && !e.dir) n += e.size;
        return n;
    }
    function clearSelection() { root.selection = []; }

    function selectedPaths() {
        return root.selection.map(n => root.svc.join(root.cwd, n));
    }

    // What a drag carries. text/uri-list is one URL per line, CRLF by the
    // spec, and every other application expects exactly that.
    function selectedUris() {
        return root.selectedPaths().map(p => root.svc.fileUrl(p)).join("\r\n");
    }

    // Where the menu is drawn, and how it is opened. The frame sets these
    // when it builds; the tiles call them without knowing where the menu
    // lives.
    property var menuLayer: null
    // The frame, given the keyboard — what a click on a file does, so the
    // shortcuts work after typing in a field.
    signal focusWanted()
    function takeFocus() { root.focusWanted(); }
    property var menu: null
    // The picture a drag carries, produced by DragBadge and bound by the
    // delegates. Empty until the first selection.
    property url dragImage: ""

    function openMenu(x, y, entry) {
        if (root.menu) root.menu.openAt(x, y, entry);
    }

    // A drop, from our own window or from another application. Files coming
    // from elsewhere are copied; files from this window are moved, which is
    // what dragging within one place means everywhere else.
    function dropOnto(drop, targetDir) {
        if (!drop || !targetDir) return;
        const paths = root.svc.pathsFromDrop(drop);
        if (!paths.length) return;
        // Dropping a folder into itself, or into where it already is, is a
        // no-op rather than an error.
        const useful = paths.filter(p => p !== targetDir
                                         && root.svc.parent(p) !== targetDir);
        if (!useful.length) return;
        if (drop.proposedAction === Qt.CopyAction || !root.ownsPaths(useful))
            root.svc.copy(useful, targetDir);
        else
            root.svc.move(useful, targetDir);
    }

    // Whether these came from the folder we are showing, which is what makes
    // a drag a move rather than a copy.
    function ownsPaths(paths) {
        return paths.every(p => root.svc.parent(p) === root.cwd);
    }

    // Move the cursor with the keyboard. `step` is in entries; the grid
    // passes its column count so up and down move a row.
    function moveSelection(step) {
        const list = root.visibleEntries;
        if (!list.length) return;
        let at = list.findIndex(e => e.name === root.selection[root.selection.length - 1]);
        if (at < 0) at = step > 0 ? -1 : list.length;
        const next = Math.max(0, Math.min(list.length - 1, at + step));
        root.selection = [list[next].name];
    }

    // ── acting ────────────────────────────────────────────────────────────
    function trashSelected() {
        if (!root.selection.length) return;
        root.svc.trash(root.selectedPaths(), root.cwd);
        root.selection = [];
    }

    function renameTo(name) {
        const from = root.renaming;
        root.renaming = "";
        if (!from || !name || name === from) return;
        root.svc.rename(root.svc.join(root.cwd, from), name);
    }

    // One entry point for both, because the tile that names them is one
    // tile: which of the two it makes is the only difference.
    function createNamed(name) {
        const wasFile = root.creatingFile;
        root.creatingFolder = false;
        root.creatingFile = false;
        if (!name) return;
        const path = root.svc.join(root.cwd, name);
        if (wasFile) root.svc.newFile(path);
        else root.svc.makeDirectory(path);
    }

    readonly property bool creatingSomething: creatingFolder || creatingFile

    function pasteHere() { root.svc.paste(root.cwd); }

    function zoom(by) {
        root.svc.iconSize = Math.max(60, Math.min(220, root.svc.iconSize + by));
    }

    // Deleting outright rather than to the trash. Asked for twice, because
    // unlike everything else in here it cannot be undone.
    property bool confirmingDelete: false

    function deleteSelected() {
        if (!root.selection.length) return;
        root.svc.deletePermanently(root.selectedPaths(), root.cwd);
        root.selection = [];
        root.confirmingDelete = false;
    }

    function duplicateSelected() {
        if (!root.selection.length) return;
        root.svc.duplicate(root.selectedPaths(), root.cwd);
    }

    function showProperties() {
        const names = root.selection;
        if (!names.length) { root.propertiesFor = null; return; }
        const e = root.visibleEntries.find(x => x.name === names[names.length - 1]);
        root.propertiesFor = e || null;
        if (e) root.svc.inspect(root.svc.join(root.cwd, e.name), e.dir);
    }

    function restoreSelected() {
        for (const name of root.selection) root.svc.restoreFromTrash(name);
        root.selection = [];
    }

    // ── reading the directory ─────────────────────────────────────────────
    property Proc lister: Proc {
        onFinished: (code, out, err) => {
            root.entries = root.svc.parseListing(out);
            root.loading = false;
            if (root.inTrash) root.svc.readTrashInfo();
            // A directory that cannot be read is not an error worth a dialog,
            // but it should not look like an empty one either.
            if (code !== 0 && !root.entries.length)
                root.svc.lastError = "Can't read " + root.svc.pretty(root.cwd);
        }
    }

    function reload() {
        if (!root.cwd) return;
        root.loading = true;
        lister.command = root.svc.listCommand(root.cwd);
        lister.running = true;
    }

    // A change anywhere reloads the directory it happened in, so a paste or
    // a rename shows up without asking.
    property Connections svcChanges: Connections {
        target: root.svc
        function onChanged(path) {
            if (!path || path === root.cwd) root.reload();
        }
    }

    // Watch the open directory, so files something *else* creates appear.
    // `gio monitor` is the same GFileMonitor a GTK file manager uses; its
    // output is only a trigger, never parsed for names.
    // Restarted rather than rebound: changing `command` on a process that is
    // already running does not restart it, so binding the command to cwd
    // would leave the watcher on whichever directory was open first and
    // every later one silently unwatched.
    property Proc watch: Proc {
        streaming: true
        onLine: settle.restart()
    }

    function rewatch() {
        watch.running = false;
        if (root.cwd === "") return;
        watch.command = ["gio", "monitor", "-d", root.cwd];
        watch.running = true;
    }

    onCwdChanged: root.rewatch()

    // A copy lands as a burst of events; reloading on each one would rebuild
    // the view dozens of times for one paste.
    property Timer settle: Timer {
        interval: 250
        onTriggered: root.reload()
    }

}
