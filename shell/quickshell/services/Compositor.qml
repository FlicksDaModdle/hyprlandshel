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
    readonly property int monitorCount: monitors.length
    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    readonly property int focusedId: focusedWorkspace ? focusedWorkspace.id : 1

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
        }
    }

    function refresh() { debounce.restart(); }

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
        Hyprland.dispatch("workspace " + id);
    }

    function focusClient(address) {
        if (!address) return;
        Hyprland.dispatch("focuswindow address:" + address);
    }

    function closeClient(address) {
        if (!address) return;
        Hyprland.dispatch("closewindow address:" + address);
    }

    function moveClientToWorkspace(address, workspaceId) {
        if (!address) return;
        Hyprland.dispatch("movetoworkspacesilent " + workspaceId + ",address:" + address);
    }

    // Hyprland has no "minimise everything" dispatcher; the equivalent is a
    // scratch workspace nothing else uses, toggled in and out of.
    property int stashWorkspace: 99
    function toggleShowDesktop() {
        if (focusedId === stashWorkspace) Hyprland.dispatch("workspace previous");
        else Hyprland.dispatch("workspace " + stashWorkspace);
    }

    function dispatch(cmd) { Hyprland.dispatch(cmd); }
}
