pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Backlight via brightnessctl. Machines without a backlight (desktops) just
// report unavailable, and every consumer — the control center's brightness
// slider, the OSD, Settings → Display — hides itself rather than showing a
// dead control.
//
// brightnessctl's machine-readable format is:
//     <device>,<class>,<current>,<percent>%,<max>
Singleton {
    id: root

    property int current: 0
    property int maximum: 0
    property string device: ""
    readonly property bool available: maximum > 0
    readonly property real value: available ? current / maximum : 0
    readonly property int percent: Math.round(value * 100)

    // Writes are debounced: dragging the slider would otherwise spawn a
    // brightnessctl process per pixel of travel.
    property real pendingValue: -1

    Process {
        id: query
        // Runs immediately so `available` is known before anything reads it;
        // Component.onCompleted does not attach to a Singleton.
        running: true
        command: ["brightnessctl", "-m"]
        stdout: StdioCollector {
            onStreamFinished: {
                const line = text.trim().split("\n")[0] || "";
                const parts = line.split(",");
                if (parts.length < 5) return;
                root.device = parts[0];
                root.current = parseInt(parts[2]) || 0;
                root.maximum = parseInt(parts[4]) || 0;
            }
        }
    }

    Process { id: setter }

    Timer {
        id: flush
        interval: 40
        onTriggered: {
            if (root.pendingValue < 0) return;
            const pct = Math.round(root.pendingValue * 100);
            root.pendingValue = -1;
            // -n1 keeps a minimum of 1% so the screen never goes fully black.
            setter.command = ["brightnessctl", "-m", "-n1", "set", pct + "%"];
            setter.running = true;
            refresh.restart();
        }
    }

    // Re-read after any change so external tools (hotkeys bound straight to
    // brightnessctl, power management) stay reflected in the UI.
    Timer {
        id: refresh
        interval: 120
        onTriggered: query.running = true
    }

    Timer {
        interval: 10000
        running: root.available
        repeat: true
        onTriggered: query.running = true
    }

    function set(v) {
        if (!available) return;
        const clamped = Math.max(0.01, Math.min(1, v));
        // Update optimistically so the slider tracks the pointer.
        current = Math.round(clamped * maximum);
        pendingValue = clamped;
        flush.restart();
    }

    function step(delta) {
        if (!available) return;
        // Resolve the target before set(), which moves `value` underneath us.
        const target = Math.max(0.01, Math.min(1, value + delta));
        set(target);
        Config.UiState.showOsd("brightness", target, false);
    }
}
