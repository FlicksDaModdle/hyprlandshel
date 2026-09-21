pragma Singleton
import QtQuick
import Quickshell

// Ephemeral cross-module UI state (which panel is open, hover state, …).
// Not persisted — that's the point, it resets on shell reload. Modules
// that don't exist yet (Launcher, Overview, Settings, Control Center) will
// bind to these as they're built; for now Dock just flips them.
Singleton {
    id: root

    property bool launcherOpen: false
    property bool overviewOpen: false
    property bool settingsOpen: false
    property bool controlCenterOpen: false

    function closeAll() {
        launcherOpen = false;
        overviewOpen = false;
        settingsOpen = false;
        controlCenterOpen = false;
    }

    function toggleLauncher() {
        var next = !launcherOpen;
        closeAll();
        launcherOpen = next;
    }

    function toggleOverview() {
        var next = !overviewOpen;
        closeAll();
        overviewOpen = next;
    }
}
