pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Colour temperature via hyprsunset, with wlsunset as a fallback. Backs the
// control center's "Night light" tile and Settings → Display → Night shift.
//
// Both tools are daemons rather than one-shot commands, so "on" means the
// daemon is running at the configured temperature and "off" means it isn't.
// State is read back from the process table so an externally started daemon
// shows up as on, instead of the tile lying about it.
Singleton {
    id: root

    property bool active: false
    property int temperature: 3400     // Kelvin; 2500 (warm) – 6000 (neutral)
    property bool available: true
    property string backend: "hyprsunset"

    readonly property string label: active ? temperature + " K" : "off"

    Process {
        id: probe
        command: ["sh", "-c",
            "if pgrep -x hyprsunset >/dev/null 2>&1; then echo 'on hyprsunset'; "
            + "elif pgrep -x wlsunset >/dev/null 2>&1; then echo 'on wlsunset'; "
            + "elif command -v hyprsunset >/dev/null 2>&1; then echo 'off hyprsunset'; "
            + "elif command -v wlsunset >/dev/null 2>&1; then echo 'off wlsunset'; "
            + "else echo 'none'; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(" ");
                if (parts[0] === "none") { root.available = false; root.active = false; return; }
                root.available = true;
                root.active = parts[0] === "on";
                if (parts[1]) root.backend = parts[1];
            }
        }
    }

    Timer {
        interval: 6000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: probe.running = true
    }

    Process { id: action; onExited: probe.running = true }

    function setActive(on) {
        if (!available) return;
        active = on;   // optimistic; the probe corrects it
        if (!on) {
            action.command = ["sh", "-c", "pkill -x hyprsunset; pkill -x wlsunset; true"];
        } else if (backend === "hyprsunset") {
            // Replace any existing daemon so the temperature actually changes.
            action.command = ["sh", "-c",
                "pkill -x hyprsunset; hyprsunset -t " + temperature + " >/dev/null 2>&1 &"];
        } else {
            // wlsunset has no "always this temperature" mode, so day and
            // night temperatures are set to the same value.
            action.command = ["sh", "-c",
                "pkill -x wlsunset; wlsunset -T " + (temperature + 100) + " -t " + temperature + " >/dev/null 2>&1 &"];
        }
        action.running = true;
    }

    function toggle() { setActive(!active); }

    function setTemperature(k) {
        temperature = Math.round(Math.max(2500, Math.min(6000, k)));
        if (active) setActive(true);
    }
}
