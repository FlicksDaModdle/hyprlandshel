import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services

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
Scope {
    id: root

    readonly property bool tiled: Config.Appearance.filesTiled
    readonly property var svc: Services.Files

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
    readonly property string view: Config.Appearance.filesView          // grid | list
    readonly property string sortBy: Config.Appearance.filesSortBy      // name | size | modified
    readonly property bool sortReverse: Config.Appearance.filesSortReverse
    readonly property bool showHidden: Config.Appearance.filesShowHidden

    // ── what is picked ────────────────────────────────────────────────────
    // Names, not indices: the listing is rebuilt on every change, and an
    // index would follow whatever happened to land in that slot.
    property var selection: []
    // The name being renamed in place, and the name of a new folder waiting
    // to be typed. Empty means neither is happening.
    property string renaming: ""
    property bool creatingFolder: false
    property bool confirmingEmpty: false

    readonly property var visibleEntries: {
        const all = root.showHidden ? root.entries : root.entries.filter(e => !e.hidden);
        return root.svc.sortEntries(all, root.sortBy, root.sortReverse);
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
        root.renaming = "";
        root.creatingFolder = false;
        root.confirmingEmpty = false;
        root.reload();
        root.svc.checkFree(path);
        Config.UiState.filesPath = path;
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

    function activate(entry) {
        if (!entry) return;
        if (entry.dir) root.go(root.svc.join(root.cwd, entry.name));
        else root.svc.open(root.svc.join(root.cwd, entry.name));
    }

    // ── selection ─────────────────────────────────────────────────────────
    function isSelected(name) { return root.selection.indexOf(name) >= 0; }

    function select(name, add) {
        if (!add) { root.selection = [name]; return; }
        const out = root.selection.slice();
        const at = out.indexOf(name);
        if (at >= 0) out.splice(at, 1); else out.push(name);
        root.selection = out;
    }

    function selectAll() { root.selection = root.visibleEntries.map(e => e.name); }
    function clearSelection() { root.selection = []; }

    function selectedPaths() {
        return root.selection.map(n => root.svc.join(root.cwd, n));
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

    function createFolder(name) {
        root.creatingFolder = false;
        if (!name) return;
        root.svc.makeDirectory(root.svc.join(root.cwd, name));
    }

    function pasteHere() { root.svc.paste(root.cwd); }

    function restoreSelected() {
        for (const name of root.selection) root.svc.restoreFromTrash(name);
        root.selection = [];
    }

    // ── reading the directory ─────────────────────────────────────────────
    Process {
        id: lister
        stdout: StdioCollector {
            onStreamFinished: {
                root.entries = root.svc.parseListing(text);
                root.loading = false;
                if (root.inTrash) root.svc.readTrashInfo();
            }
        }
        onExited: code => {
            root.loading = false;
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
    Connections {
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
    Process {
        id: watch
        stdout: SplitParser { onRead: settle.restart() }
    }

    function rewatch() {
        watch.running = false;
        if (root.cwd === "" || !Config.UiState.filesOpen) return;
        watch.command = ["gio", "monitor", "-d", root.cwd];
        watch.running = true;
    }

    onCwdChanged: root.rewatch()

    // A copy lands as a burst of events; reloading on each one would rebuild
    // the view dozens of times for one paste.
    Timer {
        id: settle
        interval: 250
        onTriggered: root.reload()
    }

    // ── opening ───────────────────────────────────────────────────────────
    Connections {
        target: Config.UiState
        function onFilesOpenChanged() {
            root.rewatch();
            if (!Config.UiState.filesOpen) return;
            const want = Config.UiState.filesPath || root.svc.home;
            if (want !== root.cwd || !root.entries.length) root.go(want);
            else root.reload();
        }
    }

    // ── the two windows ───────────────────────────────────────────────────
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData ?? null

            // "" means follow the focused monitor, which is what a freshly
            // opened window should do; once dragged across, it stays put.
            readonly property bool isMine: Config.UiState.filesScreen === ""
                ? Services.Compositor.isFocusedScreen(modelData)
                : (modelData && modelData.name === Config.UiState.filesScreen)

            visible: Config.UiState.filesOpen && isMine && !root.tiled
                     && !Config.UiState.locked
            color: "transparent"
            exclusiveZone: 0

            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true

            WlrLayershell.namespace: "quickshell:panel"
            WlrLayershell.layer: WlrLayer.Top
            // Real keyboard focus: renaming and the new-folder field are
            // typed into, and so is type-ahead.
            WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand
                                                 : WlrKeyboardFocus.None

            // Only the window itself takes clicks; the rest of the screen is
            // left alone so the desktop underneath still works.
            mask: Region { item: frame }

            // The host contract FilesFrame reads.
            readonly property bool tiled: false
            readonly property bool maximised: Config.UiState.filesMaximized
            readonly property real normalWidth: Math.min(width - 80, 1040)
            readonly property real normalHeight: Math.min(height - 120, 660)
            readonly property real workTop: Config.Appearance.barHeight + 8
            readonly property real workBottom: height - 8
            function moveTo(x, y) {
                Config.UiState.filesX = x;
                Config.UiState.filesY = y;
            }

            FilesFrame {
                id: frame
                host: win
                app: root
            }
        }
    }

    FloatingWindow {
        id: toplevel

        visible: Config.UiState.filesOpen && !Config.UiState.locked && root.tiled
        title: "Files"
        color: Config.Appearance.sheet

        implicitWidth: 1040
        implicitHeight: 660

        readonly property bool tiled: true
        readonly property bool maximised: false
        readonly property real normalWidth: width
        readonly property real normalHeight: height
        readonly property real workTop: 0
        readonly property real workBottom: height
        function moveTo(x, y) {}

        FilesFrame {
            host: toplevel
            app: root
        }
    }
}
