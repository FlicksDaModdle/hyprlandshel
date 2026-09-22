pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

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

    readonly property var workspaces: {
        const list = Hyprland.workspaces.values.filter(w => w && w.id > 0);
        list.sort((a, b) => a.id - b.id);
        return list;
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
            onStreamFinished: {
                try {
                    const o = JSON.parse(text);
                    if (o && o.id > 0) root.activeWorkspaceId = o.id;
                } catch (e) { /* leave the last known value */ }
            }
        }
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
        // hyprctl takes the dispatcher and its arguments as separate argv
        // entries, so the request is split rather than passed as one blob.
        dispatchProc.command = ["hyprctl", "dispatch"].concat(cmd.split(" "));
        dispatchProc.running = true;
    }

    // The mockup's bar always shows at least five workspace pills, filling in
    // empty ones — otherwise the pill group jitters in width as you open and
    // close the last window on a workspace.
    readonly property int minWorkspaces: 5
    readonly property var workspaceSlots: {
        const byId = {};
        for (const w of workspaces) byId[w.id] = w;
        const highest = workspaces.length > 0 ? workspaces[workspaces.length - 1].id : 1;
        const upTo = Math.max(minWorkspaces, highest, focusedId);
        const out = [];
        for (let i = 1; i <= upTo; i++) {
            const w = byId[i];
            out.push({
                id: i,
                workspace: w || null,
                exists: !!w,
                focused: i === focusedId,
                urgent: !!(w && w.urgent),
                windows: w ? clientsOn(i).length : 0
            });
        }
        return out;
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

    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
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
                    pid: c.pid || 0
                }));
            }
        }
    }

    Process {
        id: activeProc
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(text);
                    root.activeAddress = (o && o.address) || "";
                } catch (e) { root.activeAddress = ""; }
            }
        }
    }

    // Coalesce bursts: moving a window emits several events in a row, and
    // re-running hyprctl for each of them is wasteful.
    Timer {
        id: debounce
        interval: 60
        onTriggered: {
            clientsProc.running = true;
            activeProc.running = true;
            if (!root.ipcReady) activeWsProc.running = true;
        }
    }

    function refresh() { debounce.restart(); }

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
            case "focusedmon":
            case "monitoradded":
            case "monitorremoved":
            case "windowtitle":
            case "windowtitlev2":
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
        dispatch("workspace " + id);
        refresh();
    }

    function focusClient(address) {
        if (!address) return;
        dispatch("focuswindow address:" + address);
    }

    function closeClient(address) {
        if (!address) return;
        dispatch("closewindow address:" + address);
    }

    function moveClientToWorkspace(address, workspaceId) {
        if (!address) return;
        dispatch("movetoworkspacesilent " + workspaceId + ",address:" + address);
    }

    // Hyprland has no "minimise everything" dispatcher; the equivalent is a
    // scratch workspace nothing else uses, toggled in and out of.
    property int stashWorkspace: 99
    function toggleShowDesktop() {
        if (focusedId === stashWorkspace) dispatch("workspace previous");
        else dispatch("workspace " + stashWorkspace);
    }

    function dispatch(cmd) {
        if (ipcReady) {
            Hyprland.dispatch(cmd);
        } else {
            dispatchQueue.push(cmd);
            pumpDispatch();
        }
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
            onStreamFinished: {
                const reply = text.trim();
                // "ok" is success. Anything else is Lua or Hyprland
                // complaining, and is worth seeing.
                if (reply && reply.toLowerCase() !== "ok") {
                    console.warn("Compositor: hyprctl eval rejected",
                                 JSON.stringify(root.evalLast), "->", reply);
                    root.configFailed(root.evalLast, reply);
                }
            }
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
        evalProc.command = ["hyprctl", "eval", code];
        evalProc.running = true;
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

    // hl.monitor({ output=, mode=, position=, scale= }). Fields left out keep
    // whatever the monitor already has.
    function setMonitor(spec) { evalLua("hl.monitor(" + luaTable(spec) + ")"); }

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
