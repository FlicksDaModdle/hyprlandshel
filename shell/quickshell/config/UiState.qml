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
    // A panel wants to be typed into — the control center's password field,
    // for one. The panel layer takes keyboard focus only while this is set,
    // because a layer surface that holds focus the rest of the time takes it
    // away from whatever you were working in.
    property bool panelWantsKeyboard: false

    property bool desktopMenuOpen: false
    property bool windowMenuOpen: false

    // Right-clicking a dock tile or a launcher tile. `appMenuKey` is the
    // pinned entry's key when the tile is pinned; for a running app that
    // isn't pinned, appMenuClass carries its window class so it can be.
    property bool appMenuOpen: false
    property real appMenuX: 0
    property real appMenuY: 0
    property string appMenuKey: ""
    property string appMenuClass: ""
    property string appMenuLabel: ""
    property string appMenuIcon: ""

    // Set while the launcher is being used to pick an application for a
    // pinned slot rather than to launch something. Holds that slot's key.
    property string appPickerFor: ""

    // Settings is a real toplevel window, not a shell panel, so it isn't
    // part of the exclusive group — it can stay open behind a dropdown.
    property bool settingsOpen: false
    property string settingsPane: "Appearance"

    // The Settings window draws its own chrome on a shell surface, so its
    // geometry lives here rather than with the compositor. -1 means "centre
    // me"; kept across a minimise so reopening restores it where you left it.
    // Which monitor the Settings window is on. Empty means "wherever the
    // focus is"; dragging it past a screen edge sets it explicitly.
    property string settingsScreen: ""

    property real settingsX: -1
    property real settingsY: -1
    property bool settingsMaximized: false

    // Minimise: hide, keep everything. The dock's Settings tile stays lit, and
    // reopening from there or super+, restores this exact state.
    function minimiseSettings() { settingsOpen = false; }

    // Close: hide and forget, so it comes back at its default size and pane.
    function closeSettings() {
        settingsOpen = false;
        settingsMaximized = false;
        settingsX = -1;
        settingsY = -1;
        settingsPane = "Appearance";
    }

    // Where the desktop context menu was summoned, in screen coordinates.
    property real desktopMenuX: 0
    property real desktopMenuY: 0

    // Left edge of the bar's Window button, so its menu can hang under it.
    property real windowMenuX: 0

    // Control center drill-down: "", "Wi-Fi" or "Bluetooth".
    property string ccExpanded: ""

    readonly property bool anyPanelOpen: controlCenterOpen || notificationsOpen
                                         || calendarOpen || powerOpen || desktopMenuOpen
                                         || windowMenuOpen || appMenuOpen

    function closeAll() {
        launcherOpen = false;
        overviewOpen = false;
        controlCenterOpen = false;
        notificationsOpen = false;
        calendarOpen = false;
        powerOpen = false;
        desktopMenuOpen = false;
        windowMenuOpen = false;
        appMenuOpen = false;
        appPickerFor = "";
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

    function openAppMenu(x, y, key, cls, label, icon) {
        closeAll();
        appMenuX = x;
        appMenuY = y;
        appMenuKey = key || "";
        appMenuClass = cls || "";
        appMenuLabel = label || "";
        appMenuIcon = icon || "";
        appMenuOpen = true;
    }

    // Opens the launcher as a chooser: picking an entry assigns it to `key`
    // instead of launching it.
    function pickAppFor(key) {
        closeAll();
        appPickerFor = key;
        launcherOpen = true;
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
        // Opens on whichever monitor you are on, unless it is already open
        // somewhere — then it stays put rather than jumping to you.
        if (!settingsOpen) settingsScreen = "";
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
