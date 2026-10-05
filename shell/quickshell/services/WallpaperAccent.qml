pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// Settings → Appearance → "Accent from wallpaper": the accent colour taken
// from the picture on the desktop, worked out by hyprshell-daemon
// (rust/daemon/src/accent.rs) each time the wallpaper changes. Off unless
// chosen.
//
// The colours found are kept apart from your own accent (wallAccentLight /
// wallAccentDark), and Appearance.accent uses them only while this is on —
// so switching it off, or picking a swatch, puts back what you had. A live
// wallpaper is read from its gallery thumbnail; the gradient and the
// contour map have no picture, so your own accent stays.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    readonly property bool enabled: prefs.accentFromWallpaper
    readonly property bool available: Services.Daemon.running && Services.Daemon.modules.accent === true

    // The picture the colour comes from, "" when there is none.
    readonly property string source: {
        const live = Services.LiveWallpaper;
        if (live.enabled) return live.current && live.current.preview ? live.current.preview : "";
        return prefs.wallpaper || "";
    }

    property string status: ""      // what Settings says under the switch
    property bool working: false
    property string asked: ""

    function update() {
        // Not before theme.json is read: until then these are defaults,
        // and the picture and its stored colours arrive one at a time.
        if (!prefs.settingsReady) return;
        if (!root.enabled) { root.status = ""; return; }
        if (root.source === "") {
            // The gallery's list (and its thumbnails) is only read when
            // something asks.
            if (Services.LiveWallpaper.enabled && !Services.LiveWallpaper.scanned)
                Services.LiveWallpaper.scan();
            prefs.wallAccentLight = "";
            prefs.wallAccentDark = "";
            prefs.wallAccentFor = "";
            root.status = Services.LiveWallpaper.enabled
                ? "Waiting for the live wallpaper's thumbnail"
                : "No picture on the desktop to take a colour from — your own accent is used";
            return;
        }
        // Already worked out for this picture (a restart, say).
        if (prefs.wallAccentFor === root.source && prefs.wallAccentLight !== "") {
            root.status = "";
            return;
        }
        if (!root.available) {
            root.status = Services.Daemon.missing
                ? "Needs hyprshell-daemon — install.sh builds it when cargo is installed" : "";
            return;
        }
        // Already asked about this picture; the answer is on its way.
        if (root.working && root.asked === root.source) return;
        // Colours from another picture are not this one's: your own
        // accent until the new ones arrive (a few milliseconds).
        prefs.wallAccentLight = "";
        prefs.wallAccentDark = "";
        prefs.wallAccentFor = "";
        root.working = true;
        root.asked = root.source;
        root.status = "Reading the wallpaper…";
        Services.Daemon.send({ cmd: "wp-accent", path: root.source });
    }
    onEnabledChanged: update()
    onSourceChanged: update()
    onAvailableChanged: update()
    readonly property bool ready: prefs.settingsReady
    onReadyChanged: update()

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev !== "wp-accent" || ev.path !== root.source) return;
            root.working = false;
            if (ev.error) {
                // The colours from the last picture belong to that picture.
                root.prefs.wallAccentLight = "";
                root.prefs.wallAccentDark = "";
                root.prefs.wallAccentFor = "";
                root.status = ev.error.charAt(0).toUpperCase() + ev.error.slice(1) + " — your own accent is used";
                return;
            }
            root.prefs.wallAccentLight = ev.light;
            root.prefs.wallAccentDark = ev.dark;
            root.prefs.wallAccentFor = ev.path;
            root.status = "";
        }
    }
}
