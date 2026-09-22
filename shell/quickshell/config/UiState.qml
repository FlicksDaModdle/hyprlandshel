pragma Singleton
import QtQuick
import Quickshell

// Ephemeral cross-module UI state: which panel is open, transient hover and
// OSD state. Deliberately not persisted — it resets on shell reload.
//
// The shell's panels are mutually exclusive (opening one closes the rest),
// which is what the mockup does too: `toggle(p)` there sets `panel` to a
// single value. Keeping that rule here means each module can just bind
// `visible` to its own flag without coordinating with the others.
Singleton {
    id: root

    // ── panels ────────────────────────────────────────────────────────────
    property bool launcherOpen: false
    property bool overviewOpen: false
    property bool controlCenterOpen: false
    property bool notificationsOpen: false
    property bool calendarOpen: false
    property bool powerOpen: false
    property bool desktopMenuOpen: false
    property bool windowMenuOpen: false

    // Settings is a real toplevel window, not a shell panel, so it isn't
    // part of the exclusive group — it can stay open behind a dropdown.
    property bool settingsOpen: false
    property string settingsPane: "Appearance"

    // Where the desktop context menu was summoned, in screen coordinates.
    property real desktopMenuX: 0
    property real desktopMenuY: 0

    // Left edge of the bar's Window button, so its menu can hang under it.
    property real windowMenuX: 0

    // Control center drill-down: "", "Wi-Fi" or "Bluetooth".
    property string ccExpanded: ""

    readonly property bool anyPanelOpen: controlCenterOpen || notificationsOpen
                                         || calendarOpen || powerOpen || desktopMenuOpen
                                         || windowMenuOpen

    function closeAll() {
        launcherOpen = false;
        overviewOpen = false;
        controlCenterOpen = false;
        notificationsOpen = false;
        calendarOpen = false;
        powerOpen = false;
        desktopMenuOpen = false;
        windowMenuOpen = false;
        ccExpanded = "";
    }

    // Generic toggle so IPC, keybinds and click handlers all go through one
    // path and can't leave two panels open at once.
    function toggle(name) {
        const was = root[name + "Open"];
        closeAll();
        if (!was) root[name + "Open"] = true;
    }

    function toggleLauncher() { toggle("launcher"); }
    function toggleOverview() { toggle("overview"); }
    function toggleControlCenter() { toggle("controlCenter"); }
    function toggleNotifications() { toggle("notifications"); }
    function toggleCalendar() { toggle("calendar"); }
    function togglePower() { toggle("power"); }

    function toggleWindowMenu(x) {
        const was = windowMenuOpen;
        closeAll();
        if (!was) {
            windowMenuX = x;
            windowMenuOpen = true;
        }
    }

    function openDesktopMenu(x, y) {
        closeAll();
        desktopMenuX = x;
        desktopMenuY = y;
        desktopMenuOpen = true;
    }

    function openSettings(pane) {
        closeAll();
        if (pane) settingsPane = pane;
        settingsOpen = true;
    }

    // ── session lock ──────────────────────────────────────────────────────
    // The shell draws its own lock screen (modules/lock), so locking is a
    // state flip rather than launching hyprlock. Nothing may dismiss this
    // except a successful PAM authentication.
    property bool locked: false

    function lock() {
        closeAll();
        settingsOpen = false;
        locked = true;
    }

    // ── on-screen display ─────────────────────────────────────────────────
    // kind: "volume" | "mic" | "brightness"; value is 0..1.
    property string osdKind: ""
    property real osdValue: 0
    property bool osdMuted: false
    readonly property bool osdVisible: osdKind !== ""

    function showOsd(kind, value, muted) {
        osdKind = kind;
        osdValue = value;
        osdMuted = muted === true;
        osdTimer.restart();
    }

    Timer {
        id: osdTimer
        interval: 1600
        onTriggered: root.osdKind = ""
    }
}
