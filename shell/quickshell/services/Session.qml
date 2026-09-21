pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Session actions for the power menu and the launcher's commands.
//
// systemd's loginctl is preferred where it exists — it goes through the
// session manager, so inhibitors and other sessions are respected — with
// systemctl as the fallback.
Singleton {
    id: root

    // Suspending or powering off with a screen left unlocked is the one
    // thing here that's hard to take back, so the screen locks first.
    property bool lockBeforeSleep: true

    function run(args) {
        Quickshell.execDetached(["sh", "-c", args]);
    }

    function suspend() {
        if (lockBeforeSleep) Quickshell.execDetached(["sh", "-c",
            "loginctl lock-session 2>/dev/null || true"]);
        run("loginctl suspend 2>/dev/null || systemctl suspend");
    }

    function hibernate() {
        run("loginctl hibernate 2>/dev/null || systemctl hibernate");
    }

    function reboot() {
        run("loginctl reboot 2>/dev/null || systemctl reboot");
    }

    function powerOff() {
        run("loginctl poweroff 2>/dev/null || systemctl poweroff");
    }

    // Ends the Wayland session cleanly: Hyprland tears down its clients
    // rather than being killed out from under them.
    function logout() {
        Quickshell.execDetached(["hyprctl", "dispatch", "exit"]);
    }

    // Re-execs the shell in place. `qs` picks the same config back up, so
    // this is the mockup's "Reload shell — re-read the QML tree without
    // logging out".
    function reloadShell() {
        Quickshell.reload(true);
    }
}
