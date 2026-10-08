import QtQuick
import Quickshell
import "../../config" as Config

// Settings → Wallpaper → Topographic: contour lines over a made-up terrain,
// drawn by a fragment shader (shaders/topo.frag).
//
// Still, it is drawn once and then costs nothing — Qt only draws the
// wallpaper again when something about it changes. Animated, the terrain
// drifts, the contours flow up the slopes (the Wallpaper Engine look), or
// both, at the animated wallpapers' frame rate — and hold still while
// windows cover the screen, on battery (unless asked otherwise) or under
// Battery saver, when nobody would see it or it would cost power for
// nothing.
//
// shaders/topo.frag.qsb is compiled from topo.frag with Qt's qsb:
//   qsb --glsl "100 es,120,150,300 es" --hlsl 50 --msl 12 \
//       -o shaders/topo.frag.qsb shaders/topo.frag
ShaderEffect {
    id: topo

    // The screen this is on, for its place in the layout and its pixels.
    property var screen: null
    // As AnimatedWallpaper: the desktop's Services.WallMotion when given,
    // else `running`.
    property var motion: null
    property bool running: true
    // Where to start the animation: the lock screen's, carrying on from the
    // desktop's ({ time, rise }, as Services.WallMotion.phaseFor gives).
    property var startPhase: null
    // The small live version in Settings' gallery: always moving, and its
    // sizes shrunk with it.
    property bool preview: false
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
    readonly property real unit: 650 * Math.max(25, prefs.topoScale) / 100 * (preview ? width / 1280 : 1)
    readonly property real detail: Math.max(1, Math.min(6, prefs.topoDetail))
    readonly property real warp: prefs.topoFlow / 100
    readonly property real levels: Math.max(2, prefs.topoLevels)
    readonly property real lineWidth: preview ? Math.max(0.7, prefs.topoWidth * 0.6)
                                              : prefs.topoWidth * ((screen && screen.devicePixelRatio) || 1)
    readonly property real majorEvery: prefs.topoMajor
    readonly property real lineAlpha: prefs.topoStrength / 100
    readonly property real shade: prefs.topoShade === "bands" ? 2 : prefs.topoShade === "smooth" ? 1 : 0
    property real time: 0
    // Flowing: the contours climbing, a level every few seconds.
    property real rise: 0
    readonly property real glowAmt: prefs.topoGlow / 100

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
    // Held still on battery, under Battery saver and behind windows, as
    // Settings says (Services.WallMotion, which also tells Settings why).
    readonly property bool drifting: topo.preview ? topo.visible
        : prefs.topoDrift && topo.visible && (topo.motion ? topo.motion.moving(topo.screenName) : topo.running)
    // What moves: the terrain drifting, the contours flowing, or both.
    readonly property bool moveTerrain: prefs.topoMotion !== "flow"
    readonly property bool moveLines: prefs.topoMotion !== "drift"

    // At the animated wallpapers' frame rate (Settings → Wallpaper); never
    // slower than the slider's own least, whatever a settings file says.
    Timer {
        interval: Math.round(1000 / Math.max(10, Math.min(60, topo.prefs.animFps || 30)))
        repeat: true
        running: topo.drifting
        onTriggered: {
            const dt = interval / 1000 * Math.max(5, topo.prefs.topoSpeed || 30) / 30;
            if (topo.moveTerrain) topo.time += dt;
            if (topo.moveLines) topo.rise += dt * 0.35;
        }
    }

    // For `qs -c hyprshell ipc call shell wallpaperStatus`.
    readonly property string styleName: "topo"
    readonly property int gfxApi: GraphicsInfo.api
    readonly property bool moving: drifting
    Component.onCompleted: {
        if (startPhase) { time = startPhase.time || 0; rise = startPhase.rise || 0; }
        if (motion) motion.add(topo);
    }
    Component.onDestruction: if (motion) motion.remove(topo)
    onDriftingChanged: if (motion) console.log("Topography:", drifting ? "moving" : "still", "on", screenName)
}
