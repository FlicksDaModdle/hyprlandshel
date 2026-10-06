import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "Palettes.js" as Palettes

// Settings → Wallpaper → Animated: aurora, blobs, waves, starfield,
// synthwave and cells, each a fragment shader (shaders/<style>.frag).
//
// Every style takes the same settings: a palette (a preset, the theme's
// own, or five colours of your choosing), speed, size, density, glow,
// brightness and a variation. They move at the frame rate chosen, and
// hold still while a window covers the screen, on battery (unless asked
// otherwise) and under Battery saver — nobody sees them then, and it would
// cost power for nothing.
//
// The .qsb files beside each shader are what is loaded, compiled with:
//   qsb --glsl "100 es,120,150,300 es" --hlsl 50 --msl 12 \
//       -o shaders/<style>.frag.qsb shaders/<style>.frag
//
// `preview` is the small live version in Settings' gallery: it always
// moves, and its time is its own.
ShaderEffect {
    id: fx

    property var screen: null
    property string style: Config.Appearance.wallpaperStyle
    property bool preview: false
    // The palette to show, for a preview of one that is not chosen.
    property string palette: Config.Appearance.animPalette

    readonly property var prefs: Config.Appearance
    readonly property string screenName: screen ? screen.name : ""

    // ── uniforms ──────────────────────────────────────────────────────────
    readonly property vector2d origin: preview ? Qt.vector2d(0, 0)
        : Qt.vector2d(screen ? screen.x : 0, screen ? screen.y : 0)
    readonly property vector2d size: Qt.vector2d(width, height)
    readonly property vector2d seedOffset: {
        const r = n => { const x = Math.sin(n) * 43758.5453; return x - Math.floor(x); };
        return Qt.vector2d(r(prefs.animSeed * 12.9898) * 97, r(prefs.animSeed * 78.233) * 97);
    }
    // A preview is a screen in miniature, so its sizes shrink with it.
    readonly property real previewScale: preview ? width / 1280 : 1
    // Blobs are sized against the screen, so a preview is the same picture
    // smaller; everything else in logical pixels.
    readonly property real unit: 650 * Math.max(25, prefs.animScale) / 100 * (style === "blobs" ? 1 : previewScale)
    readonly property real density: prefs.animDensity / 100
    readonly property real glow: prefs.animGlow / 100
    readonly property real intensity: prefs.animIntensity / 100
    readonly property real dpr: preview ? 1 : ((screen && screen.devicePixelRatio) || 1)
    property real time: 0

    // ── colours ───────────────────────────────────────────────────────────
    function opaque(c) { return Qt.rgba(c.r, c.g, c.b, 1); }
    function hueShift(c, d) {
        return Qt.hsla(((c.hslHue < 0 ? 0 : c.hslHue) + d + 1) % 1, Math.max(0.35, c.hslSaturation), c.hslLightness, 1);
    }
    readonly property var colours: {
        const p = palette;
        if (p === "custom")
            return [prefs.animBg1, prefs.animBg2, prefs.animC1, prefs.animC2, prefs.animC3].map(c => opaque(Qt.color(c)));
        const preset = Palettes.find(p);
        if (preset)
            return [preset.bg1, preset.bg2, preset.c1, preset.c2, preset.c3].map(c => Qt.color(c));
        // The theme: its ground, and the accent with two neighbours.
        const a = opaque(prefs.accent);
        return [opaque(Qt.darker(prefs.tintSpec.b, prefs.dark ? 1.35 : 1.05)), opaque(Qt.color(prefs.tintSpec.a)),
                a, hueShift(a, 0.10), hueShift(a, -0.12)];
    }
    readonly property color bg1: colours[0]
    readonly property color bg2: colours[1]
    readonly property color c1: colours[2]
    readonly property color c2: colours[3]
    readonly property color c3: colours[4]

    fragmentShader: Qt.resolvedUrl("shaders/" + style + ".frag.qsb")

    // ── moving ────────────────────────────────────────────────────────────
    readonly property bool covered: {
        if (preview || screenName === "") return false;
        return Services.Compositor.clientsShownOn(screenName)
            .some(c => !c.floating || c.fullscreenMode > 0);
    }
    readonly property bool animating: visible && (preview || (!covered
        && (!UPower.onBattery || prefs.animOnBattery) && !Services.PowerSaver.active))

    Timer {
        readonly property int fps: fx.preview ? 24 : Math.max(10, Math.min(60, fx.prefs.animFps))
        interval: Math.round(1000 / fps)
        repeat: true
        running: fx.animating
        onTriggered: fx.time += interval / 1000 * fx.prefs.animWallSpeed / 100
    }
}
