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
    // Where the dock's pill is, published by the focused screen's dock so
    // the launcher can grow out of it. Width and height only: the launcher
    // covers the whole screen and works the position out itself, which
    // keeps the two windows from having to agree about coordinates.
    property real dockPillWidth: 0
    property real dockPillHeight: 0
    // The dock's Start tile, and its inset in the pill, so the launcher's
    // own Start button lands exactly on it.
    property real dockTileSize: 0
    property real dockIconSize: 0
    property real dockPadH: 0
    property bool overviewOpen: false
    property bool controlCenterOpen: false
    property bool notificationsOpen: false
    property bool calendarOpen: false
    property bool mediaOpen: false
    property bool powerOpen: false
    property bool clipboardOpen: false
    // A tray icon's menu, drawn by the shell (modules/panels/TrayMenu.qml):
    // which item, and the x of the icon it hangs from.
    property bool trayMenuOpen: false
    property bool drivesOpen: false
    property bool timersOpen: false
    property bool privacyOpen: false
    property bool updatesOpen: false
    property bool captureOpen: false
    // The screenshot open in the editor (modules/capture), "" for none.
    property string shotEditorPath: ""
    property var trayMenuItem: null
    property real trayMenuX: 0
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
    // Opened from the dock rather than the launcher: only there does
    // moving the tile left or right mean anything you can see.
    property bool appMenuFromDock: false

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

    // Until when a trackpad scroll is under way (ms since the epoch), set
    // by KineticScroll: a control that takes the wheel lets the scroll go
    // past it meanwhile, rather than catching the page mid-swipe.
    property real scrollLatch: 0

    // The bar control last clicked: where its centre is across the screen,
    // and when. A panel it opens grows out of it (modules/common/Entrance).
    property real panelOriginX: -1
    property real panelOriginAt: 0
    function scrollLatched() { return Date.now() < scrollLatch; }

    // Control center drill-down: "", "Wi-Fi", "Bluetooth" or "Mixer".
    property string ccExpanded: ""

    // The on-screen keyboard. Not part of the exclusive group: it is
    // there to type *into* something, so opening a panel must not take
    // it away and it must not take a panel away either.
    property bool oskOpen: false

    function toggleOsk() { oskOpen = !oskOpen; }

    // The icon maker. A window of its own rather than a panel, like
    // Settings — it is a thing you sit in front of for a while.
    property bool iconMakerOpen: false

    // Which pinned tile is having its icon changed, "" for none.
    property string iconPickerFor: ""
    readonly property bool iconPickerOpen: iconPickerFor !== ""

    readonly property bool anyPanelOpen: controlCenterOpen || notificationsOpen
                                         || calendarOpen || mediaOpen || powerOpen || clipboardOpen || trayMenuOpen || drivesOpen || timersOpen || privacyOpen || updatesOpen || captureOpen || desktopMenuOpen
                                         || windowMenuOpen || appMenuOpen || iconPickerOpen

    function closeAll() {
        // Anything that closes everything is not a collapse back into the
        // dock: only Escape is, and it sets this again on its way out.
        holdDockAfterLauncher = false;
        launcherOpen = false;
        overviewOpen = false;
        controlCenterOpen = false;
        notificationsOpen = false;
        calendarOpen = false;
        mediaOpen = false;
        powerOpen = false;
        clipboardOpen = false;
        trayMenuOpen = false;
        drivesOpen = false;
        timersOpen = false;
        privacyOpen = false;
        updatesOpen = false;
        captureOpen = false;
        desktopMenuOpen = false;
        windowMenuOpen = false;
        appMenuOpen = false;
        appPickerFor = "";
        iconPickerFor = "";
        ccExpanded = "";
    }

    // Generic toggle so IPC, keybinds and click handlers all go through one
    // path and can't leave two panels open at once.
    // Whether the dock should stay out after the launcher closes, to be
    // collapsed back into. Escape and the Start tile mean "put this
    // back"; Super means "I am done", and goes through toggle() below,
    // which clears it.
    property bool holdDockAfterLauncher: false

    function toggle(name) {
        const was = root[name + "Open"];
        closeAll();
        if (!was) root[name + "Open"] = true;
    }

    function toggleLauncher() { toggle("launcher"); }

    // The Start tile on the dock, which is a plain toggle and puts the
    // dock back when it closes.
    //
    // It used to go through toggle(), and toggle() calls closeAll(),
    // which clears the hold — so with auto-hide on, pressing Start to
    // dismiss the launcher took the dock away with it. The pointer was
    // on the dock at the time, having just pressed a button there, and
    // the button vanished from under it. Super and Escape are the two
    // ways to say "I am done" and "put this back"; a button you clicked
    // is neither, and should simply undo itself.
    //
    // Closing sets the hold *before* clearing launcherOpen, and not
    // through closeAll(), which would clear it again. The exit animation
    // and the dock's own "stay out for a moment" both read the flag as
    // the launcher closes, so setting it afterwards is setting it too
    // late — this is the same order Escape uses, in Launcher.close().
    function toggleLauncherFromDock() {
        if (!launcherOpen) { toggle("launcher"); return; }
        holdDockAfterLauncher = true;
        launcherOpen = false;
    }

    function toggleOverview() { toggle("overview"); }
    function toggleControlCenter() { toggle("controlCenter"); }
    function toggleNotifications() { toggle("notifications"); }
    function toggleCalendar() { toggle("calendar"); }
    function toggleMedia() { toggle("media"); }
    function togglePower() { toggle("power"); }
    function toggleClipboard() { toggle("clipboard"); }
    function toggleDrives() { toggle("drives"); }
    function toggleTimers() { toggle("timers"); }
    function togglePrivacy() { toggle("privacy"); }
    function toggleUpdates() { toggle("updates"); }
    function toggleCapture() { toggle("capture"); }
    // The same icon again closes it; another icon moves it there.
    function openTrayMenu(item, x) {
        const same = trayMenuOpen && trayMenuItem === item;
        closeAll();
        if (same) return;
        trayMenuItem = item;
        trayMenuX = x;
        trayMenuOpen = true;
    }

    function toggleWindowMenu(x) {
        const was = windowMenuOpen;
        closeAll();
        if (!was) {
            windowMenuX = x;
            windowMenuOpen = true;
        }
    }

    function openAppMenu(x, y, key, cls, label, icon, fromDock) {
        closeAll();
        appMenuFromDock = fromDock === true;
        appMenuX = x;
        appMenuY = y;
        appMenuKey = key || "";
        appMenuClass = cls || "";
        appMenuLabel = label || "";
        appMenuIcon = icon || "";
        appMenuOpen = true;
    }

    // Opens the grid of every glyph, to put one on a pinned tile.
    // Not through closeAll(): the maker is a window, and closing every
    // panel because one opened would take the icon picker away — which
    // is where "make a new one" is offered from in the first place.
    function openIconMaker() { iconMakerOpen = true; }

    function openIconPicker(key) {
        closeAll();
        if (key) iconPickerFor = key;
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

    // Settings itself (modules/settings/Settings.qml), for the launcher's
    // search; and the row to scroll to and flash once a pane opens.
    property var settingsApp: null
    property string settingsFocus: ""
    property int settingsFocusSeq: 0
    function openSettingsAt(pane, row) {
        openSettings(pane);
        settingsFocus = row || "";
        settingsFocusSeq++;
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
