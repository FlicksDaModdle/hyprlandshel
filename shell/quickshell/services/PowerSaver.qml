pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "../config" as Config
import "." as Services

// Battery saver: the expensive, decorative parts of the desktop switched
// off while it is on — on battery, below a charge, always, or never, as
// Settings → Power says.
//
// What it can do, each its own setting:
//
//   blur          Hyprland's blur behind translucent windows and the
//                 shell's panels: the costliest thing the compositor
//                 draws, redone whenever anything behind it changes
//   shadows       the soft shadow under every window
//   opacity       inactive windows drawn fully opaque, rather than a
//                 touch see-through — which also gives the blur behind
//                 them nothing to do, and lets a fullscreen app be
//                 scanned straight out
//   animations    Hyprland's own window animations
//   still         the shell's transitions made instant and its
//                 decorative motion stopped (Config.Appearance.saverCalm)
//   profile       the power profile put on "Power saver", and put back
//                 afterwards
//
// The compositor's own values are read before anything is changed and are
// what it gets back, so whatever hyprland.lua (or you) set is restored —
// not this file's idea of the defaults.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    readonly property var bat: UPower.displayDevice
    readonly property bool onBattery: UPower.onBattery
    readonly property real charge: bat && bat.isLaptopBattery ? bat.percentage : 1

    readonly property bool active: {
        switch (prefs.saverMode) {
        case "always": return true;
        case "never":  return false;
        case "low":    return onBattery && charge * 100 <= prefs.saverBelow;
        default:       return onBattery;               // "battery"
        }
    }

    // What should be off right now.
    readonly property var want: ({
        blur: active && prefs.saverBlur,
        shadows: active && prefs.saverShadows,
        opacity: active && prefs.saverOpacity,
        animations: active && prefs.saverAnimations
    })
    readonly property string wantKey: JSON.stringify(want)
    onWantKeyChanged: sync()
    onActiveChanged: { syncProfile(); syncStill(); }
    Component.onCompleted: { sync(); syncStill(); }

    function syncStill() { prefs.saverCalm = active && prefs.saverStill; }
    Connections {
        target: root.prefs
        function onSaverStillChanged() { root.syncStill(); }
        function onSaverProfileChanged() { root.syncProfile(); }
    }

    // ── the compositor ───────────────────────────────────────────────────
    // `original` holds Hyprland's values from before anything here touched
    // them; null while nothing is changed.
    property var original: null
    property bool reading: false
    property var applied: ({ blur: false, shadows: false, opacity: false, animations: false })

    Process {
        id: readProc
        command: ["sh", "-c",
            'for o in decoration:blur:enabled decoration:shadow:enabled decoration:inactive_opacity animations:enabled; do '
          + '  hyprctl -j getoption "$o" 2>/dev/null || echo "{}"; echo; echo "@@"; '
          + 'done']
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.split("@@");
                const val = (i, fallback) => {
                    try {
                        const j = JSON.parse((parts[i] || "").trim() || "{}");
                        if (j.int !== undefined) return j.int;
                        if (j.float !== undefined) return j.float;
                        if (j.bool !== undefined) return j.bool ? 1 : 0;
                    } catch (e) {}
                    return fallback;
                };
                // Fallbacks are hyprland.lua's own values.
                root.original = {
                    blur: val(0, 1) !== 0,
                    shadows: val(1, 1) !== 0,
                    opacity: Number(val(2, 0.97)),
                    animations: val(3, 1) !== 0
                };
                root.reading = false;
                root.sync();
            }
        }
    }

    function sync() {
        const w = want;
        const anyWanted = w.blur || w.shadows || w.opacity || w.animations;
        if (anyWanted && original === null) {
            if (!reading) { reading = true; readProc.running = true; }
            return;
        }
        if (original === null) return;

        const o = original;
        const tree = { decoration: {} };
        let changed = false;
        if (w.blur !== applied.blur) { tree.decoration.blur = { enabled: w.blur ? false : o.blur }; changed = true; }
        if (w.shadows !== applied.shadows) { tree.decoration.shadow = { enabled: w.shadows ? false : o.shadows }; changed = true; }
        if (w.opacity !== applied.opacity) { tree.decoration.inactive_opacity = w.opacity ? 1.0 : o.opacity; changed = true; }
        if (w.animations !== applied.animations) { tree.animations = { enabled: w.animations ? false : o.animations }; changed = true; }
        if (Object.keys(tree.decoration).length === 0) delete tree.decoration;
        if (changed) Services.Compositor.setConfig(tree);
        applied = Object.assign({}, w);
        // Everything is back as it was: forget it, so the next time reads
        // the values fresh (hyprland.lua may have been edited meanwhile).
        if (!anyWanted) original = null;
    }

    // A reload puts hyprland.lua's values back underneath: start over from
    // those.
    Connections {
        target: Services.Compositor
        function onConfigReloaded() {
            root.original = null;
            root.applied = { blur: false, shadows: false, opacity: false, animations: false };
            root.sync();
        }
    }

    // ── the power profile ────────────────────────────────────────────────
    // Only put back if it is still the one set here: a profile picked by
    // hand meanwhile is a decision, and stays.
    property int profileBefore: -1
    function syncProfile() {
        if (active && prefs.saverProfile) {
            if (PowerProfiles.profile !== PowerProfile.PowerSaver) {
                profileBefore = PowerProfiles.profile;
                PowerProfiles.profile = PowerProfile.PowerSaver;
            }
        } else if (profileBefore >= 0) {
            if (PowerProfiles.profile === PowerProfile.PowerSaver) PowerProfiles.profile = profileBefore;
            profileBefore = -1;
        }
    }

    // For Settings: a line saying what it is doing.
    readonly property string summary: {
        if (!active) {
            switch (prefs.saverMode) {
            case "never": return "Off";
            case "always": return "On";
            case "low": return "Comes on below " + prefs.saverBelow + "% on battery";
            default: return "Comes on when you unplug";
            }
        }
        const what = [prefs.saverBlur ? "blur" : "", prefs.saverShadows ? "shadows" : "",
                      prefs.saverOpacity ? "see-through windows" : "", prefs.saverAnimations ? "window animations" : "",
                      prefs.saverStill ? "shell motion" : ""].filter(s => s);
        return "On" + (what.length > 0 ? " — no " + what.join(", ") : "")
             + (prefs.saverProfile ? (what.length > 0 ? "; " : " — ") + "power saver profile" : "");
    }
}
