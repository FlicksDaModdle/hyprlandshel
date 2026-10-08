pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "." as Services

// Compositor state: workspaces, windows and their geometry.
//
// Quickshell's Hyprland singleton already gives live workspaces and monitors,
// so those are used directly. Window *geometry* — which the overview needs to
// draw real thumbnails rather than the mockup's fixed rectangles — is only
// available from `hyprctl clients`, so that's polled on the compositor's own
// event stream rather than on a timer: it refreshes exactly when something
// moved, and costs nothing while the desktop is idle.
Singleton {
    id: root

    // Workspaces, from Quickshell's Hyprland connection when it is
    // delivering and from hyprctl when it is not.
    //
    // The fallback is not paranoia. When that connection is not up there are
    // no events either, so nothing ever tells the bar that the workspace
    // changed: the pills sit on whatever was true when the shell started and
    // clicking one appears to do nothing, because the dispatch works and the
    // display never moves. A shell that quietly stops reflecting the
    // compositor is worse than one that polls.
    readonly property var workspaces: {
        const live = Hyprland.workspaces.values.filter(w => w && w.id > 0);
        if (live.length === 0) return polledWorkspaces;

        // Quickshell builds its list from the event stream and keeps an
        // object for every workspace it has heard of, which is not quite
        // the same thing as the workspaces that exist: an object can
        // outlive the workspace it stood for, and at startup it can be
        // built from an event that arrives before the first full read.
        // `hyprctl workspaces` is the compositor answering the question
        // directly, with no object lifetime in between, so where the two
        // disagree that one settles it.
        //
        // The focused workspace is never dropped. It can be one created
        // half a millisecond ago, and a poll that has not come back yet
        // is not evidence against it.
        const live2 = root.polled
            ? live.filter(w => root.polledIds[w.id] || w.id === root.focusedId)
            : live;
        const out = live2.slice();
        out.sort((a, b) => a.id - b.id);
        return out;
    }

    property var polledWorkspaces: []

    // Whether `hyprctl workspaces` has ever answered. Until it has there
    // is nothing to check the live list against, so it is taken as given.
    property bool polled: false

    readonly property var polledIds: {
        const known = ({});
        for (const w of polledWorkspaces) known[w.id] = true;
        return known;
    }

    // Workspaces Quickshell is holding that hyprctl does not report.
    //
    // Joined into a string rather than kept as a list so that the change
    // signal fires when the set changes and not every time the binding
    // re-runs — a binding that returns a fresh array notifies on every
    // evaluation, which for a warning means the log fills up.
    readonly property string ghostWorkspaces: {
        if (!root.polled) return "";
        return Hyprland.workspaces.values
            .filter(w => w && w.id > 0 && !root.polledIds[w.id]
                         && w.id !== root.focusedId)
            .map(w => w.id).sort((a, b) => a - b).join(", ");
    }
    onGhostWorkspacesChanged: {
        if (root.ghostWorkspaces !== "")
            console.warn("Compositor: ignoring workspace(s) that hyprctl "
                         + "does not report: " + root.ghostWorkspaces);
    }

    function fetchWorkspaces() {
        Services.HyprIpc.request("j/workspaces", r => {
            if (r === null) wsProc.running = true;
            else root.parseWorkspaces(r);
        });
    }
    function fetchActiveWs() {
        Services.HyprIpc.request("j/activeworkspace", r => {
            if (r === null) activeWsProc.running = true;
            else root.parseActiveWs(r);
        });
    }
    Process {
        id: wsProc
        command: ["hyprctl", "-j", "workspaces"]
        stdout: StdioCollector {
            onStreamFinished: root.parseWorkspaces(text)
        }
    }
    function parseWorkspaces(text) {
                let parsed;
                try { parsed = JSON.parse(text); } catch (e) { return; }
                if (!Array.isArray(parsed)) return;
                const out = parsed.filter(w => w && w.id > 0).map(w => ({
                    id: w.id,
                    name: w.name || String(w.id),
                    urgent: false,
                    windows: w.windows || 0
                }));
                out.sort((a, b) => a.id - b.id);
                root.polledWorkspaces = out;
                root.polled = true;
    }

    readonly property var monitors: Hyprland.monitors.values

    // The monitor Hyprland says is focused. Quickshell tracks this itself,
    // which is more reliable than scanning `monitors` for a focused flag —
    // and when that scan found nothing it returned undefined, which the
    // panel layer read as "this screen is the right one" on *every* screen,
    // so a bar dropdown opened on all of them at once.
    readonly property var focusedMonitor: Hyprland.focusedMonitor
    readonly property string focusedMonitorName:
        focusedMonitor ? focusedMonitor.name : ""

    // True for exactly one screen: the focused one, or the first as a
    // fallback so a panel is never invisible everywhere.
    function isFocusedScreen(screenInfo) {
        if (!screenInfo) return false;
        if (focusedMonitorName !== "") return screenInfo.name === focusedMonitorName;
        const all = monitors || [];
        return all.length === 0 || !all[0] || all[0].name === screenInfo.name;
    }
    readonly property int monitorCount: monitors.length
    readonly property var focusedWorkspace: Hyprland.focusedWorkspace

    // Whether Quickshell's own Hyprland IPC connection came up. When it
    // didn't, workspaces and dispatches fall back to hyprctl, which this
    // service already shells out to for window geometry — so the bar keeps
    // working either way instead of going inert.
    readonly property bool ipcReady: Hyprland.focusedWorkspace !== null
    property int activeWorkspaceId: 1
    readonly property int focusedId: focusedWorkspace ? focusedWorkspace.id : activeWorkspaceId

    Process {
        id: activeWsProc
        command: ["hyprctl", "-j", "activeworkspace"]
        stdout: StdioCollector {
            onStreamFinished: root.parseActiveWs(text)
        }
    }
    function parseActiveWs(text) {
        try {
            const o = JSON.parse(text);
            if (o && o.id > 0) root.activeWorkspaceId = o.id;
        } catch (e) { /* leave the last known value */ }
    }

    // Queued, and the reply is read. A Process is one slot: assigning
    // `running = true` while it is already running is a no-op, so a second
    // dispatch arriving before the first exits used to be dropped on the
    // floor — which is exactly what a run of quick clicks on the workspace
    // pills is. hyprctl also answers "ok" or an error string, and that reply
    // was being discarded, so a rejected dispatch looked identical to one
    // that worked.
    property var dispatchQueue: []
    property bool dispatchBusy: false
    property string dispatchLast: ""

    signal dispatchFailed(string request, string reply)

    Process {
        id: dispatchProc
        stdout: StdioCollector {
            onStreamFinished: {
                const reply = text.trim();
                if (reply && reply.toLowerCase() !== "ok") {
                    console.warn("Compositor: hyprctl dispatch", root.dispatchLast, "->", reply);
                    root.dispatchFailed(root.dispatchLast, reply);
                }
            }
        }
        onExited: { root.dispatchBusy = false; root.pumpDispatch(); }
    }

    function pumpDispatch() {
        if (dispatchBusy || dispatchQueue.length === 0) return;
        const cmd = dispatchQueue.shift();
        dispatchLast = cmd;
        dispatchBusy = true;
        // One argv entry, not split on spaces: hyprctl joins its arguments
        // back together with single spaces anyway, and what goes in here is
        // a Lua call with spaces inside its braces.
        dispatchProc.command = ["hyprctl", "dispatch", cmd];
        dispatchProc.running = true;
    }

    // The mockup's bar always shows at least five workspace pills, filling in
    // empty ones — otherwise the pill group jitters in width as you open and
    // close the last window on a workspace.
    readonly property int minWorkspaces: 5

    // What the switcher draws: the workspaces that exist, the focused one,
    // and enough low unused numbers to reach the minimum.
    //
    // This used to be every number from 1 to the highest id — a range, not
    // a list. That is indistinguishable from the right answer while the ids
    // are 1 to 5, and catastrophic the moment one of them is not: a single
    // workspace numbered 99 drew ninety-nine beads, ninety-six of which
    // stood for nothing, and the group swallowed the whole bar.
    //
    // The fill is still here, because it is what keeps the group from
    // changing width as the last window on a workspace closes. What has
    // gone is the idea that the gap between two workspaces needs filling:
    // 1, 2, 3 and 99 is four workspaces and is drawn as four, which is odd
    // to look at exactly once and true every time.
    readonly property var workspaceSlots: {
        const byId = ({});
        const ids = [];
        function add(id, w) {
            if (!(id > 0) || byId[id] !== undefined) return;
            byId[id] = w || null;
            ids.push(id);
        }

        // Show desktop's stash (see toggleShowDesktop) is not a workspace
        // anyone made, and it is the one that put ninety-nine beads on the
        // bar: it is numbered 99, and while it existed the old range drew
        // everything below it. It is left out unless a window has actually
        // landed there — something launched while the desktop was showing
        // opens on it, and hiding that would hide the window.
        const stash = root.stashWorkspace;
        const stashHolds = root.clientsOn(stash).length > 0;
        for (const w of workspaces)
            if (w.id !== stash || stashHolds) add(w.id, w);

        // Drawn even in the moment before the compositor has confirmed it
        // exists, so clicking a pill never makes that pill vanish. With the
        // desktop showing nothing is highlighted, which is what it is.
        if (root.focusedId !== stash || stashHolds) add(root.focusedId, null);

        // Padded with the lowest numbers not already in use. Searching only
        // 1..minWorkspaces is always enough: every id in that span that is
        // taken is one fewer the padding has to supply.
        for (let i = 1; ids.length < root.minWorkspaces
                        && i <= root.minWorkspaces; i++)
            add(i, null);

        ids.sort((a, b) => a - b);

        return ids.map(id => {
            const w = byId[id];
            return {
                id: id,
                workspace: w,
                exists: !!w,
                focused: id === root.focusedId,
                urgent: !!(w && w.urgent),
                windows: w ? root.clientsOn(id).length : 0
            };
        });
    }

    // ── windows ───────────────────────────────────────────────────────────
    // [{ address, class, title, workspace, x, y, w, h, floating, fullscreen,
    //    monitor, focused }]
    property var clients: []
    property string activeAddress: ""

    readonly property var activeClient: clients.find(c => c.address === activeAddress) || null
    readonly property string activeClass: activeClient ? activeClient.cls : ""
    readonly property string activeTitle: activeClient ? activeClient.title : ""

    function clientsOn(workspaceId) {
        return clients.filter(c => c.workspace === workspaceId);
    }

    // ── what each output is showing ───────────────────────────────────────
    function monitorNamed(name) {
        return (root.monitors || []).find(m => m && m.name === name) || null;
    }

    // The workspaces whose windows are on screen on one output: the one it
    // is showing, and a special workspace (a scratchpad) open over it.
    //
    // While Show desktop has it parked on the stash it answers with the
    // workspace it came from. The desktop being uncovered for a moment is
    // not a change of workspace, and anything scoped to "this workspace" —
    // the dock, Alt+Tab — should not go blank because of it.
    function shownWorkspacesOn(name) {
        const m = root.monitorNamed(name);
        if (!m) return root.focusedId > 0 ? [root.focusedId] : [];
        const ipc = m.lastIpcObject || ({});
        let active = m.activeWorkspace ? m.activeWorkspace.id
                   : ((ipc.activeWorkspace || {}).id || 0);
        if (active === root.stashWorkspace && root.stashReturn > 0)
            active = root.stashReturn;
        const out = [];
        if (active) out.push(active);
        const special = ipc.specialWorkspace || ({});
        if (special.id && special.name) out.push(special.id);
        return out;
    }

    // Windows on screen on one output, including windows pinned there,
    // which Hyprland shows on every workspace.
    function clientsShownOn(name) {
        const ws = root.shownWorkspacesOn(name);
        const m = root.monitorNamed(name);
        const id = m ? m.id : -1;
        return root.clients.filter(c => ws.indexOf(c.workspace) >= 0
                                        || (c.pinned && c.monitor === id));
    }

    // Every window on one output, whatever workspace it is on.
    function clientsOnMonitor(name) {
        const m = root.monitorNamed(name);
        if (!m) return root.clients;
        return root.clients.filter(c => c.monitor === m.id);
    }

    // Asked over Hyprland's socket (HyprIpc), and through hyprctl only when
    // that isn't there: this runs after every window event.
    function fetchClients() {
        Services.HyprIpc.request("j/clients", r => {
            if (r === null) clientsProc.running = true;
            else root.parseClients(r);
        });
    }
    function fetchActive() {
        Services.HyprIpc.request("j/activewindow", r => {
            if (r === null) activeProc.running = true;
            else root.parseActive(r);
        });
    }
    function parseActive(text) {
        try {
            const o = JSON.parse(text);
            root.activeAddress = (o && o.address) || "";
        } catch (e) { root.activeAddress = ""; }
    }
    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: root.parseClients(text)
        }
    }
    function parseClients(text) {
                let parsed;
                try { parsed = JSON.parse(text); } catch (e) { return; }
                if (!Array.isArray(parsed)) return;
                root.clients = parsed.filter(c => c && c.mapped !== false).map(c => ({
                    address: c.address || "",
                    cls: c.class || "",
                    initialClass: c.initialClass || c.class || "",
                    title: c.title || "",
                    workspace: c.workspace ? c.workspace.id : 0,
                    workspaceName: c.workspace ? c.workspace.name : "",
                    monitor: c.monitor,
                    x: (c.at && c.at.length === 2) ? c.at[0] : 0,
                    y: (c.at && c.at.length === 2) ? c.at[1] : 0,
                    w: (c.size && c.size.length === 2) ? c.size[0] : 0,
                    h: (c.size && c.size.length === 2) ? c.size[1] : 0,
                    floating: !!c.floating,
                    fullscreen: !!c.fullscreen,
                    // Hyprland's own number: 0 not, 1 maximised, 2 fullscreen.
                    fullscreenMode: typeof c.fullscreen === "number" ? c.fullscreen
                                  : (c.fullscreen ? 2 : 0),
                    // Shown on every workspace of its monitor.
                    pinned: !!c.pinned,
                    // 0 is the window with focus, 1 the one before it, and
                    // so on: the order Alt+Tab walks.
                    focusHistory: typeof c.focusHistoryID === "number"
                                  ? c.focusHistoryID : 1e6,
                    pid: c.pid || 0
                }));
    }

    Process {
        id: activeProc
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector {
            onStreamFinished: root.parseActive(text)
        }
    }

    // Coalesce bursts: moving a window emits several events in a row, and
    // re-running hyprctl for each of them is wasteful.
    Timer {
        id: debounce
        interval: 60
        onTriggered: {
            root.fetchClients();
            root.fetchActive();
            root.fetchActiveWs();
            if (!root.ipcReady) root.fetchWorkspaces();
        }
    }

    function refresh() { debounce.restart(); }

    // Without Quickshell's Hyprland connection there is no event stream, so
    // the only way to notice that something changed is to look. This runs
    // only in that case, and stops the moment the connection comes up.
    Timer {
        id: poll
        interval: 700
        repeat: true
        running: !root.ipcReady
        onTriggered: {
            root.fetchActiveWs();
            root.fetchWorkspaces();
            root.fetchClients();
        }
    }

    // A dispatch of our own is the one moment we know something is about to
    // change, whether or not an event will arrive to say so. Long enough for
    // the compositor to have acted, short enough not to be seen.
    Timer {
        id: actionSettle
        interval: 120
        onTriggered: {
            root.fetchActiveWs();
            root.fetchWorkspaces();
            root.fetchClients();
            root.fetchActive();
        }
    }

    // Monitor state is Quickshell's, not ours, and it only re-reads it on a
    // compositor event. Changing a mode or scale through hl.monitor doesn't
    // raise one, so the Settings window has to ask — otherwise its dropdowns
    // keep reporting the mode you just changed away from.
    //
    // Twice: once now, and once after the mode change has actually landed,
    // because a modeset takes a moment and the first read can beat it.
    function refreshMonitors() {
        Hyprland.refreshMonitors();
        monitorSettle.restart();
    }

    Timer {
        id: monitorSettle
        interval: 900
        onTriggered: Hyprland.refreshMonitors()
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "openwindow") root.windowOpened(event.data);
            else if (event.name === "closewindow") root.windowClosed(event.data);
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
            case "activewindow":
            case "activewindowv2":
            case "fullscreen":
            case "changefloatingmode":
            case "workspace":
            case "workspacev2":
            // A workspace appearing or going away used to raise nothing
            // here, so `hyprctl workspaces` was only re-read when the
            // focus happened to move as well. That is most of the time
            // and not all of it — a window moved to a new workspace
            // silently creates one — and the poll is now what decides
            // whether a workspace Quickshell is holding is really there.
            case "createworkspace":
            case "createworkspacev2":
            case "destroyworkspace":
            case "destroyworkspacev2":
            case "renameworkspace":
            case "moveworkspace":
            case "moveworkspacev2":
            case "focusedmon":
                root.refresh();
                break;
            // A scratchpad opening or closing changes what an output is
            // showing, and that is read from the monitor record — which
            // Quickshell otherwise re-reads only on a monitor event.
            case "activespecial":
            case "activespecialv2":
                Hyprland.refreshMonitors();
                root.refresh();
                break;
            // An output (re)appearing is set up from hyprland.lua's rule,
            // which undoes a mode set from Settings; Devices puts it back.
            case "monitoradded":
            case "monitoraddedv2":
            case "monitorremoved":
            case "monitorremovedv2":
                Hyprland.refreshMonitors();
                root.refresh();
                root.outputsChanged();
                break;
            case "windowtitle":
            case "windowtitlev2":
            case "pin":
                root.refresh();
                break;

            // Hyprland re-read its config — from `hyprctl reload`, from the
            // Keybinds pane, or from someone typing it in a terminal. Every
            // runtime override the shell had applied is gone with it, so
            // this is what tells Devices to put them back.
            //
            // Previously only the shell's own reloadConfig() raised that,
            // which meant a reload from anywhere else silently reverted the
            // display mode, the pointer settings and the window frame.
            case "configreloaded":
                Hyprland.refreshMonitors();
                root.refresh();
                root.configReloaded();
                break;
            }
        }
    }

    // Primes the window list once the singleton is built; from then on
    // refreshes ride Hyprland's event stream. A zero-interval Timer rather
    // than Component.onCompleted, which QML will not attach to a Singleton.
    Timer {
        interval: 0
        running: true
        onTriggered: root.refresh()
    }

    // ── actions ───────────────────────────────────────────────────────────

    function focusWorkspace(id) {
        dispatch("hl.dsp.focus({ workspace = " + parseInt(id, 10) + " })");
        refresh();
        actionSettle.restart();
    }

    // The Quickshell toplevel for a window, which is what a ScreencopyView
    // takes to show a live picture of it — or null.
    //
    // The two lists spell the same address differently. `hyprctl clients`
    // writes "0x55d3e1a2b3c0"; Quickshell's HyprlandToplevel.address is
    // QString::number(address, 16), which is "55d3e1a2b3c0" with no prefix.
    // Compared as they come, no window would ever match and every preview
    // would be the fallback icon.
    function normAddress(a) {
        return String(a || "").trim().toLowerCase()
            .replace(/^0x/, "").replace(/^0+(?=.)/, "");
    }

    function toplevelFor(address) {
        const want = root.normAddress(address);
        if (want === "") return null;
        const list = Hyprland.toplevels.values;
        for (let i = 0; i < list.length; i++) {
            const t = list[i];
            if (t && root.normAddress(t.address) === want) return t;
        }
        return null;
    }

    function focusClient(address) {
        if (!address) return;
        dispatch("hl.dsp.focus({ window = " + luaSel("address:" + address) + " })");
        actionSettle.restart();
    }

    function closeClient(address) {
        if (!address) return;
        dispatch("hl.dsp.window.close({ window = "
                 + luaSel("address:" + address) + " })");
        actionSettle.restart();
    }

    // follow = false is what the old `movetoworkspacesilent` meant: move the
    // window, stay where you are.
    function moveClientToWorkspace(address, workspaceId) {
        if (!address) return;
        dispatch("hl.dsp.window.move({ workspace = " + parseInt(workspaceId, 10)
                 + ", follow = false, window = "
                 + luaSel("address:" + address) + " })");
        actionSettle.restart();
    }

    // Hyprland has no "minimise everything" dispatcher; the equivalent is a
    // scratch workspace nothing else uses, toggled in and out of.
    property int stashWorkspace: 99
    // The workspace Show desktop left, while it is on the stash.
    property int stashReturn: 0
    function toggleShowDesktop() {
        if (focusedId === stashWorkspace) {
            dispatch('hl.dsp.focus({ workspace = "previous" })');
            stashReturn = 0;
        } else {
            stashReturn = focusedId;
            dispatch("hl.dsp.focus({ workspace = " + stashWorkspace + " })");
        }
        refresh();
        actionSettle.restart();
    }

    // `cmd` is a Lua call, not a hyprlang dispatcher line.
    //
    // Under a Lua config Hyprland's IPC evaluates a dispatch request as
    // `return hl.dispatch(<request>)` (dispatchRequest in src/ipc/s1/
    // Commands.cpp), so "workspace 1" is not a dispatcher name — it is a Lua
    // syntax error, and the only sign of it is a line in the shell's log:
    //
    //     Dispatch request "workspace 1" failed with error
    //     "...')' expected near '1'"
    //
    // Which is why clicking a workspace pill did nothing: the click worked,
    // the request went out, and the compositor rejected it.
    //
    // Both routes end at the same socket and the same evaluation, so both
    // take the same Lua.
    function dispatch(cmd) {
        if (ipcReady) {
            Hyprland.dispatch(cmd);
        } else {
            dispatchQueue.push(cmd);
            pumpDispatch();
        }
    }

    // Lua literals for the dispatcher arguments. A window address is a
    // string selector ("address:0x…"), a workspace is a number or one of
    // Hyprland's selector words.
    function luaSel(s) {
        return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    // ── runtime configuration ─────────────────────────────────────────────
    // Everything below used to go through `hyprctl keyword`. On a Lua-config
    // Hyprland — which is 0.55+, i.e. every version this shell supports —
    // that is rejected outright:
    //
    //     keyword can't work with non-legacy parsers. Use eval.
    //
    // and it still exits 0. So a settings window built on `keyword` changes
    // nothing, reports success, and leaves the control sitting at the value
    // you picked. The replacement is `hyprctl eval`, which runs Lua against
    // the live config, exactly as hyprland.lua does at startup.
    //
    // Changes last until the next `hyprctl reload`, which is the same
    // lifetime `keyword` had. Anything meant to survive a reload belongs in
    // hyprland.lua.

    // Lua has no JSON, so values are serialised by hand. Only the shapes the
    // hl.* API actually takes are handled: booleans, numbers, strings,
    // arrays and nested tables.
    function luaValue(v) {
        if (v === true) return "true";
        if (v === false) return "false";
        if (v === null || v === undefined) return "nil";
        if (typeof v === "number") {
            if (!isFinite(v)) return "nil";
            // Integers must not pick up a decimal point (a mode of
            // 1920.000000 is not a mode), and fractions must not be printed
            // in exponent form.
            return Number.isInteger(v) ? String(v) : v.toFixed(6);
        }
        if (Array.isArray(v)) return "{" + v.map(x => luaValue(x)).join(",") + "}";
        if (typeof v === "object") return luaTable(v);
        return luaString(String(v));
    }

    function luaString(str) {
        return '"' + str.replace(/\\/g, "\\\\")
                       .replace(/"/g, '\\"')
                       .replace(/\n/g, "\\n") + '"';
    }

    function luaTable(obj) {
        const parts = [];
        for (const k in obj) {
            if (obj[k] === undefined) continue;
            // Bare keys only where Lua allows them; the rest are bracketed,
            // which is what any option still spelled with a hyphen needs.
            const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + luaString(k) + "]";
            parts.push(key + "=" + luaValue(obj[k]));
        }
        return "{" + parts.join(",") + "}";
    }

    // hyprctl exits 0 whether the Lua ran or not, so success is judged by
    // what it printed. This is the only way a bad option surfaces at all.
    signal configFailed(string code, string reply)

    property var evalQueue: []
    property bool evalBusy: false

    Process {
        id: evalProc
        stdout: StdioCollector {
            onStreamFinished: root.checkEval(text.trim())
        }
        onExited: {
            root.evalBusy = false;
            root.pumpEval();
        }
    }

    property string evalLast: ""

    // One hyprctl at a time: a Process is a single slot, and overwriting
    // `command` mid-run would drop whichever call got there first. Settings
    // rows fire in bursts (a slider release, a pane switch), so they queue.
    function pumpEval() {
        if (evalBusy || evalQueue.length === 0) return;
        const code = evalQueue.shift();
        evalLast = code;
        evalBusy = true;
        // Over the socket when it is there; hyprctl sends exactly this.
        Services.HyprIpc.request("/eval " + code, r => {
            if (r === null) {
                evalProc.command = ["hyprctl", "eval", code];
                evalProc.running = true;
                return;
            }
            root.checkEval(r.trim());
            root.evalBusy = false;
            root.pumpEval();
        });
    }
    function checkEval(reply) {
        // "ok" is success. Anything else is Lua or Hyprland complaining,
        // and is worth seeing.
        if (reply && reply.toLowerCase() !== "ok") {
            console.warn("Compositor: hyprctl eval rejected", JSON.stringify(root.evalLast), "->", reply);
            root.configFailed(root.evalLast, reply);
        }
    }

    function evalLua(code) {
        evalQueue.push(code);
        pumpEval();
    }

    // hl.config takes a partial tree and merges it, so a single option can be
    // set without restating the rest of the category.
    function setConfig(tree) { evalLua("hl.config(" + luaTable(tree) + ")"); }

    // Re-reads hyprland.lua, which throws away every runtime override. The
    // shell puts its own back afterwards, or the Settings window would show
    // values the compositor no longer has.
    Process { id: reloadProc }
    function reloadConfig() {
        reloadProc.running = false;
        reloadProc.command = ["hyprctl", "reload"];
        reloadProc.running = true;
        // Belt and braces: the configreloaded event above is the normal
        // path, but it only arrives when the IPC connection is live. On the
        // hyprctl fallback there is no event stream, so this fires anyway.
        reapply.restart();
    }
    Timer {
        id: reapply
        interval: 1200
        onTriggered: if (!root.ipcReady) root.configReloaded();
    }
    signal configReloaded()
    // An output was added or removed.
    signal outputsChanged()
    // A window has just been mapped (Hyprland's openwindow; the data is
    // "address,workspace,class,title").
    signal windowOpened(string data)
    // ...and one has gone (closewindow; the data is its address, no 0x).
    signal windowClosed(string data)

    // hl.device({ name=, ... }): settings for one input device, over the
    // input ones. Hyprland keeps them by name, so they hold for a device
    // that is unplugged and comes back.
    function setDevice(spec) { evalLua("hl.device(" + luaTable(spec) + ")"); }

    // hl.monitor({ output=, mode=, position=, scale= }). Fields left out keep
    // whatever the monitor already has.
    function setMonitor(spec) { evalLua("hl.monitor(" + luaTable(spec) + ")"); }

    // Where an output sits on the desktop plane, in logical pixels. The
    // mode and scale go with it because Hyprland's monitor keyword takes
    // the whole line — sending only a position resets the rest to auto.
    function setMonitorPosition(name, x, y) {
        const m = monitors.find(o => o.name === name);
        if (!m) return;
        const ipc = m.lastIpcObject || ({});
        const pxW = ipc.width || m.width, pxH = ipc.height || m.height;
        const hz = ipc.refreshRate || 60;
        setMonitor({ output: name,
                     mode: pxW + "x" + pxH + "@" + (Math.round(hz * 1000) / 1000),
                     position: Math.round(x) + "x" + Math.round(y),
                     scale: m.scale || ipc.scale || 1 });
        refreshMonitors();
    }

    // ── monitor modes ─────────────────────────────────────────────────────
    // Hyprland refuses a scale that doesn't divide the mode into a whole
    // number of logical pixels ("failed to find a clean divisor"), and since
    // the rejection is just a log line, a slider offering every value in a
    // range mostly produces settings that silently don't apply. So only the
    // scales that actually work for this monitor's current mode are offered.
    function scaleIsClean(pxW, pxH, scale) {
        if (!(pxW > 0) || !(pxH > 0) || !(scale > 0)) return false;
        const w = pxW / scale, h = pxH / scale;
        return Math.abs(w - Math.round(w)) < 0.001
            && Math.abs(h - Math.round(h)) < 0.001;
    }

    // The steps a person actually reaches for, filtered to the ones this
    // panel can take. 100% is always valid, so the list is never empty.
    readonly property var scaleSteps: [1, 1.25, 1.333333, 1.5, 1.666667,
                                       1.75, 2, 2.25, 2.5, 3]

    function validScales(pxW, pxH) {
        return scaleSteps.filter(s => scaleIsClean(pxW, pxH, s));
    }
}
