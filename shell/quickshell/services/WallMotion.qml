pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "../config" as Config
import "." as Services

// Whether the animated wallpapers (Topography.qml, AnimatedWallpaper.qml)
// move on the desktop, and if not, why — so Settings can say so rather
// than leave a still desktop looking broken next to previews that move.
//
// They hold still, by choice in Settings → Wallpaper:
//   battery   on battery, unless "Keep moving on battery" is on
//   saver     under Battery saver
//   covered   while a tiled, maximised or fullscreen window fills the
//             screen, unless "Hold still behind windows" is off. The
//             shell's own windows (Settings, tiled) never count: you are
//             looking at the wallpaper through them while choosing it.
//
// It also looks for another wallpaper program drawing over the shell's
// ground — hyprpaper, swww, swaybg, wpaperd, linux-wallpaperengine, or an
// mpvpaper the shell did not start — which hides any wallpaper the shell
// draws, animated or not.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance

    readonly property bool onBattery: UPower.onBattery
    readonly property bool saver: Services.PowerSaver.active

    function coveredOn(screenName) {
        if (!screenName || !prefs.animPauseCovered) return false;
        return Services.Compositor.clientsShownOn(screenName)
            .some(c => !/quickshell/i.test(c.cls) && (!c.floating || c.fullscreenMode > 0));
    }

    // "" when it moves; otherwise battery | saver | covered.
    function reason(screenName) {
        if (root.onBattery && !prefs.animOnBattery) return "battery";
        if (root.saver) return "saver";
        if (root.coveredOn(screenName)) return "covered";
        return "";
    }
    function moving(screenName) { return root.reason(screenName) === ""; }

    // For Settings: why the desktop is still, on any screen.
    readonly property string anyReason: {
        const names = Quickshell.screens.map(s => s.name);
        if (names.length === 0) return root.reason("");
        let r = "";
        for (const n of names) {
            const why = root.reason(n);
            if (why === "") return "";
            if (r === "") r = why;
        }
        return r;
    }

    // ── what each screen is doing, for `qs -c hyprshell ipc call shell wallpaperStatus` ────
    // The desktop's wallpapers add themselves while they are up.
    property var shown: []
    function add(w) { root.shown = root.shown.concat([w]); }
    function remove(w) { root.shown = root.shown.filter(x => x !== w); }
    // Where a screen's animation has got to, so the lock screen can carry on
    // from the same frame rather than jump back to the start.
    function phaseFor(screenName) {
        const w = root.shown.find(x => x && x.screenName === screenName) || root.shown[0];
        return w ? { time: w.time || 0, rise: w.rise || 0 } : null;
    }
    function status() {
        const api = ["unknown", "software", "openvg", "opengl", "direct3d11", "vulkan", "metal", "null", "direct3d12"];
        return JSON.stringify({
            style: prefs.wallpaperStyle, image: prefs.wallpaper !== "", live: Services.LiveWallpaper.enabled,
            onBattery: root.onBattery, saver: root.saver, keepOnBattery: prefs.animOnBattery,
            holdBehindWindows: prefs.animPauseCovered, fps: prefs.animFps, otherPrograms: root.foreignNames,
            topo: { animate: prefs.topoDrift, motion: prefs.topoMotion, speed: prefs.topoSpeed },
            screens: root.shown.map(w => ({
                screen: w.screenName, style: w.styleName, moving: w.moving, why: root.reason(w.screenName),
                time: Math.round(w.time * 100) / 100, rise: w.rise !== undefined ? Math.round(w.rise * 100) / 100 : null,
                size: Math.round(w.width) + "x" + Math.round(w.height), status: w.status,
                graphics: api[w.gfxApi] || String(w.gfxApi)
            }))
        });
    }

    // ── another program drawing a wallpaper ──────────────────────────────
    // Process names as the kernel keeps them: 15 characters at most.
    readonly property var others: [
        { comm: "hyprpaper", name: "hyprpaper" },
        { comm: "swww-daemon", name: "swww" },
        { comm: "awww-daemon", name: "awww" },
        { comm: "swaybg", name: "swaybg" },
        { comm: "wpaperd", name: "wpaperd" },
        { comm: "linux-wallpaper", name: "linux-wallpaperengine" },
        { comm: "mpvpaper", name: "mpvpaper" }
    ]
    // [{ comm, name }] running now. An mpvpaper is the shell's own while a
    // Live wallpaper is on.
    property var foreign: []
    readonly property string foreignNames: root.foreign.map(o => o.name).join(", ")

    function check() { if (!scan.running) scan.running = true; }
    Process {
        id: scan
        command: ["ps", "-eo", "stat=,comm="]
        stdout: StdioCollector {
            onStreamFinished: {
                // Not the ones already gone, waiting to be reaped.
                const running = text.split("\n").map(s => s.trim().split(/\s+/))
                    .filter(f => f.length >= 2 && f[0][0] !== "Z").map(f => f[1]);
                root.foreign = root.others.filter(o => running.indexOf(o.comm) >= 0
                    && !(o.comm === "mpvpaper" && Services.LiveWallpaper.enabled));
            }
        }
    }
    function stopForeign() {
        for (const o of root.foreign) Quickshell.execDetached(["pkill", "-x", o.comm]);
        recheck.restart();
    }
    Timer { id: recheck; interval: 800; onTriggered: root.check() }

    // Once: the map's "Animate" switched on, as it now is from the start.
    readonly property bool migrate: prefs.settingsReady && !prefs.animMigrated
    onMigrateChanged: root.migrateOnce()
    function migrateOnce() {
        if (!root.migrate) return;
        prefs.topoDrift = true;
        prefs.animMigrated = true;
    }

    Component.onCompleted: { root.check(); root.migrateOnce(); }
}
