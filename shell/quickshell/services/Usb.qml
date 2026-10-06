pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// USB sticks and SD cards, through UDisks2 by way of hyprshell-daemon
// (rust/daemon/src/usb.rs): what is plugged in, mounted on arrival if
// chosen, a notification with Open and Eject, and ejecting safely. The
// bar shows a drive button while one is connected (modules/panels/
// DrivesPanel.qml).
Singleton {
    id: root

    readonly property bool daemonHas: Services.Daemon.running && Services.Daemon.modules.usb === true
    property bool available: false
    // [{ path, name, size, parts: [{ path, label, fs, size, mount, device, locked }] }]
    property var drives: []
    property string error: ""
    // Drives being ejected, by path, for the panel's "Ejecting…".
    property var ejecting: ({})

    function configure() {
        if (root.daemonHas)
            Services.Daemon.send({ cmd: "usb-config", automount: Config.Appearance.usbAutomount,
                                   notify: Config.Appearance.usbNotify });
    }
    readonly property string config: [daemonHas, Config.Appearance.settingsReady,
                                      Config.Appearance.usbAutomount, Config.Appearance.usbNotify].join("|")
    onConfigChanged: if (Config.Appearance.settingsReady) configure()

    function label(d, p) {
        return (p && p.label) ? p.label : d.name;
    }
    function mount(p) { Services.Daemon.send({ cmd: "usb-mount", path: p.path }); }
    function unmount(p) { Services.Daemon.send({ cmd: "usb-unmount", path: p.path }); }
    function eject(d) {
        const e = Object.assign({}, root.ejecting);
        e[d.path] = true;
        root.ejecting = e;
        Services.Daemon.send({ cmd: "usb-eject", drive: d.path });
    }
    // Opened in Files, mounted first if it is not yet.
    property string pendingOpen: ""
    function open(p) {
        if (p.mount) { Config.Apps.launchFiles(p.mount); return; }
        root.pendingOpen = p.path;
        mount(p);
    }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "usb") {
                root.available = ev.available === true;
                root.drives = ev.drives || [];
                // A drive that went, or whose filesystems are all unmounted
                // after an eject, is done ejecting.
                const e = {};
                for (const k in root.ejecting)
                    if (root.drives.some(d => d.path === k && d.parts.some(p => p.mount !== ""))) e[k] = true;
                root.ejecting = e;
                if (root.pendingOpen !== "") {
                    for (const d of root.drives) for (const p of d.parts)
                        if (p.path === root.pendingOpen && p.mount !== "") {
                            root.pendingOpen = "";
                            Config.Apps.launchFiles(p.mount);
                        }
                }
            } else if (ev.ev === "usb-open") {
                Config.Apps.launchFiles(ev.mount);
            } else if (ev.ev === "usb-error") {
                root.error = ev.message || "";
                root.ejecting = ({});
                clearError.restart();
            }
        }
    }
    Timer { id: clearError; interval: 9000; onTriggered: root.error = "" }
}
