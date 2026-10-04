import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services

// Settings → Wallpaper → Topographic: contour lines over a made-up terrain,
// drawn by a fragment shader (shaders/topo.frag).
//
// Still, it is drawn once and then costs nothing — Qt only draws the
// wallpaper again when something about it changes. With Drift on, the
// terrain moves slowly at a low frame rate, and holds still while windows
// cover the screen or the machine is on battery, when nobody would see it
// or it would cost battery for nothing.
//
// shaders/topo.frag.qsb is compiled from topo.frag with Qt's qsb:
//   qsb --glsl "100 es,120,150,300 es" --hlsl 50 --msl 12 \
//       -o shaders/topo.frag.qsb shaders/topo.frag
ShaderEffect {
    id: topo

    // The screen this is on, for its place in the layout and its pixels.
    property var screen: null
    readonly property string screenName: screen ? screen.name : ""

    readonly property var prefs: Config.Appearance

    // ── the terrain ───────────────────────────────────────────────────────
    readonly property vector2d origin: Qt.vector2d(screen ? screen.x : 0, screen ? screen.y : 0)
    readonly property vector2d size: Qt.vector2d(width, height)
    // A seed is a place on the endless terrain.
    readonly property vector2d seedOffset: {
        const r = n => { const x = Math.sin(n) * 43758.5453; return x - Math.floor(x); };
        return Qt.vector2d(r(prefs.topoSeed * 12.9898) * 240 - 120, r(prefs.topoSeed * 78.233) * 240 - 120);
    }
    readonly property real unit: 650 * Math.max(25, prefs.topoScale) / 100
    readonly property real detail: Math.max(1, Math.min(6, prefs.topoDetail))
    readonly property real warp: prefs.topoFlow / 100
    readonly property real levels: Math.max(2, prefs.topoLevels)
    readonly property real lineWidth: prefs.topoWidth * ((screen && screen.devicePixelRatio) || 1)
    readonly property real majorEvery: prefs.topoMajor
    readonly property real lineAlpha: prefs.topoStrength / 100
    readonly property real shade: prefs.topoShade === "bands" ? 2 : prefs.topoShade === "smooth" ? 1 : 0
    property real time: 0

    // ── colours ───────────────────────────────────────────────────────────
    function opaque(c) { return Qt.rgba(c.r, c.g, c.b, 1); }
    readonly property color lineColor: opaque(prefs.topoLine === "accent" ? prefs.accent
                                            : prefs.topoLine === "custom" ? Qt.color(prefs.topoLineCustom)
                                            : prefs.ink)
    // The theme's ground is the gradient's own two colours, so a topo map
    // sits in the theme the way the plain gradient does — the low one taken
    // a little further, or bands between them would be too close to see.
    // Bands and shading run from low ground to high; flat runs top to bottom.
    readonly property color bgLow: opaque(prefs.topoGround === "custom" ? Qt.color(prefs.topoLow)
                                        : Qt.darker(prefs.tintSpec.b, prefs.dark ? 1.35 : 1.05))
    readonly property color bgHigh: opaque(prefs.topoGround === "custom" ? Qt.color(prefs.topoHigh)
                                         : Qt.color(prefs.tintSpec.a))

    fragmentShader: Qt.resolvedUrl("shaders/topo.frag.qsb")

    // ── drifting ──────────────────────────────────────────────────────────
    // Covered: a tiled, maximised or fullscreen window on this screen.
    readonly property bool covered: {
        if (topo.screenName === "") return false;
        return Services.Compositor.clientsShownOn(topo.screenName)
            .some(c => !c.floating || c.fullscreenMode > 0);
    }
    readonly property bool drifting: prefs.topoDrift && topo.visible && !topo.covered && !UPower.onBattery && !Services.PowerSaver.active

    // Fifteen frames a second: the terrain moves slowly enough that more
    // would only cost more.
    Timer {
        interval: 66
        repeat: true
        running: topo.drifting
        onTriggered: topo.time += 0.066 * topo.prefs.topoSpeed / 30
    }
}
