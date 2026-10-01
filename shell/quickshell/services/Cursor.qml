pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services
import "CursorShapes.js" as Shapes

// The pointer, in the shell's accent colour.
//
// CursorShapes.js draws the set as SVG; hyprshell-cursors (shell/agent,
// built by install.sh) turns it into a theme in ~/.local/share/icons/
// Hyprshell — hyprcursor for Hyprland and the apps that ask it for a cursor
// by name, XCursor for those that load one themselves (XWayland, GTK 3) —
// and then it is put in use:
//
//   hyprctl setcursor     Hyprland's own pointer, and every app that asks
//                         Hyprland for one (cursor-shape-v1), at once
//   gsettings             GTK's idea of the theme, for GTK apps started
//                         from here on
//   ~/.icons/default      what an app with no theme named falls back to —
//                         XWayland apps among them. Only written when it
//                         is not there or is this shell's own.
//
// Rebuilt when the accent, the light/dark theme or the colours change,
// after a moment's pause so dragging through accents builds it once.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    readonly property bool enabled: prefs.cursorTheme === "accent"
    readonly property string themeName: "Hyprshell"
    readonly property string home: Quickshell.env("HOME")
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (root.home + "/.local/share")
    readonly property string themeDir: root.dataHome + "/icons/" + root.themeName
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (root.home + "/.cache")) + "/hyprshell"
    readonly property string tool: Services.Agent.shellDir + "/bin/hyprshell-cursors"

    property bool toolMissing: false
    property bool built: false
    property bool building: false
    property string error: ""

    function hex(c) {
        const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2);
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    // What it is filled with, and the outline that keeps it visible on
    // anything: light on dark fills, dark on light ones, unless chosen.
    readonly property string fill: prefs.cursorFill === "white" ? "#ffffff"
                                 : prefs.cursorFill === "black" ? "#1b1a19"
                                 : root.hex(prefs.accent)
    readonly property string line: {
        if (prefs.cursorOutline === "light") return "#ffffff";
        if (prefs.cursorOutline === "dark") return "#1b1a19";
        const c = Qt.color(root.fill);
        const lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        return lum > 0.6 ? "#1b1a19" : "#ffffff";
    }
    readonly property int size: Math.max(16, Math.min(96, prefs.cursorSize))

    // What a rebuild depends on; a change in it, settled, rebuilds.
    readonly property string key: root.enabled ? root.fill + root.line : ""
    onKeyChanged: if (root.enabled) settle.restart()
    onEnabledChanged: root.enabled ? settle.restart() : root.restoreSystem()
    onSizeChanged: if (root.enabled && root.built) root.apply()
    Timer { id: settle; interval: 900; onTriggered: root.build() }
    Component.onCompleted: if (root.enabled) settle.restart()

    function build() {
        if (writer.running || builder.running) { settle.restart(); return; }
        root.error = "";
        root.building = true;
        writer.payload = JSON.stringify({
            name: root.themeName,
            sizes: [24, 32, 48, 64, 96],
            shapes: Shapes.shapes(root.fill, root.line)
        });
        writer.running = true;
    }

    // The spec goes to a file through stdin: it is a few hundred
    // kilobytes, far past what belongs in an argument list.
    Process {
        id: writer
        property string payload: ""
        stdinEnabled: true
        command: ["sh", "-c", 'mkdir -p "$1" && cat > "$1/cursor-spec.json"', "sh", root.cacheDir]
        onStarted: { writer.write(writer.payload); writer.stdinEnabled = false; }
        onExited: code => {
            writer.stdinEnabled = true;
            if (code !== 0) { root.building = false; root.error = "couldn't write the cursor spec"; return; }
            builder.running = true;
        }
    }

    Process {
        id: builder
        command: ["sh", "-c", '[ -x "$1" ] || exit 127; exec "$1" "$2" "$3"', "sh",
                  root.tool, root.cacheDir + "/cursor-spec.json", root.themeDir]
        stderr: StdioCollector { id: buildErr }
        onExited: code => {
            root.building = false;
            root.toolMissing = code === 127;
            if (code === 0) { root.built = true; root.apply(); }
            else if (code !== 127) root.error = buildErr.text.split("\n").filter(l => l && !/locale|UTF-8|for more information/.test(l)).pop() || ("exited " + code);
        }
    }

    // Puts a theme in use, by name.
    Process { id: applier }
    function use(name, size) {
        applier.command = ["sh", "-c",
            'name=$1 size=$2 ours=$3\n'
          + 'command -v hyprctl >/dev/null 2>&1 && hyprctl setcursor "$name" "$size" >/dev/null\n'
          + 'if command -v gsettings >/dev/null 2>&1; then\n'
          + '  gsettings set org.gnome.desktop.interface cursor-theme "$name" 2>/dev/null\n'
          + '  gsettings set org.gnome.desktop.interface cursor-size "$size" 2>/dev/null\n'
          + 'fi\n'
          // The fallback theme, for apps that name none. Left alone when it
          // is someone else's.
          + 'd="$HOME/.icons/default"; f="$d/index.theme"\n'
          + 'if [ ! -e "$f" ] || grep -q "^# hyprshell" "$f"; then\n'
          + '  if [ "$ours" = 1 ]; then\n'
          + '    mkdir -p "$d" && printf "# hyprshell: the accent cursor (Settings → Appearance)\\n[Icon Theme]\\nName=Default\\nInherits=%s\\n" "$name" > "$f"\n'
          + '  else rm -f "$f"; fi\n'
          + 'fi',
            "sh", name, String(size), name === root.themeName ? "1" : "0"];
        applier.running = true;
    }
    function apply() { root.use(root.themeName, root.size); }
    function restoreSystem() { root.use(prefs.cursorSystemTheme || "Adwaita", root.size); }
}
