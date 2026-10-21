pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// The Limine boot menu in the desktop's wallpaper and colours
// (Settings → Wallpaper → Boot menu).
//
// A still of whatever the desktop shows — the picture itself, a frame from
// the live video, or the shell's own gradient, map or animation captured
// from the wallpaper surface — at the main display's size, and colours
// taken from that picture (see palette()). Both go to
// shell/limine/hyprshell-limine-theme, a small root helper installed by
// shell/limine/install.sh, through pkexec:
// it writes to the boot partition, so it asks for the password, and only
// when Update is pressed, never behind your back.
Singleton {
    id: root

    readonly property string helper: "/usr/local/libexec/hyprshell-limine-theme"
    property bool installed: false
    property bool busy: false
    property string status: ""
    property bool failed: false

    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME")
                                   || (Quickshell.env("HOME") + "/.cache")) + "/hyprshell/boot"
    readonly property string still: dir + "/wallpaper.png"

    // A drawn wallpaper is captured by the surface that draws it
    // (modules/background/Wallpaper.qml), which answers with grabbed().
    signal grabRequest(string screenName, string path)

    function probe() { probeProc.running = true; }
    Process {
        id: probeProc
        command: ["test", "-x", root.helper]
        onExited: code => root.installed = code === 0
    }
    Component.onCompleted: probe()
    // Noticed within a minute of shell/limine/install.sh, without a restart.
    Timer { running: !root.installed; interval: 60000; repeat: true; onTriggered: root.probe() }

    // The main display, or failing that the first.
    readonly property var monitor: {
        const all = Services.Compositor.monitors || [];
        return all.find(m => m && m.name === Services.Devices.mainDisplay) || all[0] || null;
    }
    // Its size in pixels, at most 2560 wide: the boot menu is drawn at the
    // firmware's resolution, and the picture lives on a small partition.
    readonly property var size: {
        const o = root.monitor ? (root.monitor.lastIpcObject || ({})) : ({});
        const q = Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        let w = Number(o.width) || (q ? Math.round(q.width * q.devicePixelRatio) : 1920);
        let h = Number(o.height) || (q ? Math.round(q.height * q.devicePixelRatio) : 1080);
        if (o.transform % 2 === 1) [w, h] = [h, w];
        const k = Math.min(1, 2560 / w);
        return { w: Math.round(w * k / 2) * 2, h: Math.round(h * k / 2) * 2 };
    }

    function hex(c) {
        const two = v => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");
        return two(c.r) + two(c.g) + two(c.b);
    }

    function fail(message) {
        root.busy = false;
        root.failed = true;
        root.status = message;
    }

    // Make the still, then hand it over.
    function update() {
        if (root.busy || !root.installed) return;
        root.busy = true;
        root.failed = false;
        root.status = "Making a still of the wallpaper…";
        const A = Config.Appearance, L = Services.LiveWallpaper;
        const name = root.monitor ? String(root.monitor.name)
                   : (Quickshell.screens.length > 0 ? String(Quickshell.screens[0].name) : "");
        if (L.enabled) root.convert(L.wallpaperFor(name) || L.chosen, "2");
        else if (A.wallpaper !== "") root.convert(A.wallpaper, "");
        else {
            // Its folder first: the capture is saved straight into it.
            mkdirProc.screenName = name;
            mkdirProc.running = true;
        }
    }
    Process {
        id: mkdirProc
        property string screenName: ""
        command: ["mkdir", "-p", root.dir]
        onExited: {
            grabTimeout.restart();
            root.grabRequest(screenName, root.dir + "/drawn.png");
        }
    }
    function grabbed(path) {
        if (!grabTimeout.running) return;
        grabTimeout.stop();
        if (path === "") root.fail("Couldn't capture the wallpaper");
        else root.convert(path, "");
    }
    Timer { id: grabTimeout; interval: 5000; onTriggered: root.fail("Couldn't capture the wallpaper") }

    function convert(source, seek) {
        convertProc.command = ["sh", "-c", convertProc.script, "boot-still", source, root.still,
                               String(root.size.w), String(root.size.h), seek];
        convertProc.running = true;
    }
    Process {
        id: convertProc
        // Filled and cropped to the screen, the way the desktop shows it;
        // a frame a couple of seconds in for a video, past any fade-in.
        readonly property string script: `
            src=$1 out=$2 w=$3 h=$4 seek=$5
            mkdir -p "\${out%/*}"
            ffmpeg -nostdin -loglevel error -y \${seek:+-ss "$seek"} -i "$src" -frames:v 1 \\
                -vf "scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h" \\
                -pix_fmt rgb24 "$out.tmp.png" && mv -f "$out.tmp.png" "$out"`
        stderr: StdioCollector { id: convertErr }
        onExited: code => {
            if (code !== 0) {
                console.warn("BootTheme: ffmpeg:", convertErr.text.trim());
                root.fail(code === 127 ? "ffmpeg is needed: sudo pacman -S ffmpeg"
                                       : "Couldn't make a still of the wallpaper");
                return;
            }
            sampleProc.running = true;
        }
    }

    // ── the colours, from the picture ────────────────────────────────────
    // The still shrunk to 16 × 10 and read back as numbers, 160 pixels.
    Process {
        id: sampleProc
        command: ["sh", "-c", 'ffmpeg -nostdin -loglevel error -i "$1" -vf scale=16:10 -f rawvideo -pix_fmt rgb24 - | od -An -v -tu1',
                  "boot-sample", root.still]
        stdout: StdioCollector { id: sampleOut }
        onExited: code => {
            const n = sampleOut.text.trim().split(/\s+/).map(Number).filter(v => isFinite(v));
            const px = [];
            for (let i = 0; i + 2 < n.length; i += 3) px.push([n[i] / 255, n[i + 1] / 255, n[i + 2] / 255]);
            root.apply(root.palette(px));
        }
    }

    // HSL, 0..1 throughout.
    function hsl(c) {
        const [r, g, b] = c, mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2;
        if (mx === mn) return [0, 0, l];
        const d = mx - mn, s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        const h = mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
        return [h / 6, s, l];
    }
    function fromHsl(h, s, l) {
        const f = n => {
            const k = (n + h * 12) % 12, a = s * Math.min(l, 1 - l);
            return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
        };
        return Qt.rgba(f(0), f(8), f(4), 1);
    }

    // Background: the picture's own average, its hue kept and darkened to
    // something text reads over. Accent: its most vivid colour, lifted to
    // a strength that reads as a highlight — or the shell's accent, for a
    // picture with no colour to speak of. Text: near white, warmed or
    // cooled towards the background's hue.
    function palette(px) {
        const A = Config.Appearance;
        if (px.length === 0) return { accent: A.accent, background: "#1f1d1c", foreground: "#f8f4f4" };
        const avg = [0, 1, 2].map(i => px.reduce((t, p) => t + p[i], 0) / px.length);
        const [bh, bs] = root.hsl(avg);
        const background = root.fromHsl(bh, Math.min(0.35, bs), 0.09);
        const foreground = root.fromHsl(bh, Math.min(0.2, bs), 0.94);
        let best = null, bestScore = 0;
        for (const p of px) {
            const [h, s, l] = root.hsl(p);
            // Vivid and neither near black nor near white.
            const score = s * (1 - Math.abs(l - 0.55) * 1.6);
            if (score > bestScore) { bestScore = score; best = [h, s, l]; }
        }
        const accent = best && bestScore > 0.18
            ? root.fromHsl(best[0], Math.max(0.6, best[1]), Math.max(0.55, Math.min(0.65, best[2])))
            : A.accent;
        return { accent: accent, background: background, foreground: foreground };
    }

    function apply(c) {
        root.status = "Writing to the boot menu…";
        console.log("BootTheme: colours", root.hex(c.accent), root.hex(c.background), root.hex(c.foreground));
        // Dark ground and light text whatever the desktop's mode: the menu
        // is read over a picture, at boot, often in the dark.
        runProc.command = ["sh", "-c", 'exec pkexec "$1" --accent "$2" --background "$3" --foreground "$4" < "$5"',
                           "boot-theme", root.helper, root.hex(c.accent), root.hex(Qt.color(c.background)),
                           root.hex(Qt.color(c.foreground)), root.still];
        runProc.running = true;
    }
    function remove() {
        if (root.busy || !root.installed) return;
        root.busy = true;
        root.failed = false;
        root.status = "Taking it out of the boot menu…";
        runProc.command = ["pkexec", root.helper, "--remove"];
        runProc.running = true;
    }
    Process {
        id: runProc
        stdout: StdioCollector { id: runOut }
        stderr: StdioCollector { id: runErr }
        onExited: code => {
            root.busy = false;
            if (code === 0) {
                root.failed = false;
                root.status = runOut.text.indexOf("remove") >= 0
                    ? "Taken out; the boot menu is Limine's own again"
                    : "Updated " + Qt.formatDateTime(new Date(), "d MMM, hh:mm");
                return;
            }
            // pkexec: 126 is a refused or dismissed password, 127 not allowed.
            const why = runErr.text.trim().split("\n").pop().replace(/^hyprshell-limine-theme: /, "");
            root.fail(code === 126 || code === 127 ? "Not changed: the password wasn't given"
                                                   : (why || "Couldn't write to the boot menu"));
        }
    }
}
