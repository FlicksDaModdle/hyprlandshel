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
// and, so the pointer is the same size everywhere, the theme and size go
// to every other place an app reads them from (see use()). An app that
// draws its own pointer — every XWayland app, MuseScore among them, and Qt
// for any shape it doesn't hand to Hyprland — reads XCURSOR_SIZE, and it
// used to be fixed at 24 whatever was set here: the pointer changed size
// each time it crossed from a part of the window Hyprland drew it over to
// one the app did.
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
    // What the last step did, for Settings to show: so "the cursor did
    // not change" can be told apart as not built, built but refused by
    // Hyprland, or in use.
    property string status: ""

    function hex(c) {
        const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2);
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    // Drawn as the app icons are (CursorShapes.js): ink lines on a body
    // in the surface colour, one element in the accent. Dark is a dark body
    // with light lines, light the reverse; auto follows the theme. Either
    // shows on anything — the body frames the lines.
    readonly property bool darkBody: prefs.cursorFill === "dark" ? true
                                   : prefs.cursorFill === "light" ? false
                                   : prefs.dark
    readonly property string base: root.darkBody ? "#1f1d1c" : "#fbfafa"
    readonly property string ink: root.darkBody ? "#f8f4f4" : "#201e1d"
    readonly property string acc: root.hex(prefs.accent)
    readonly property int size: Math.max(16, Math.min(96, prefs.cursorSize))

    // XCursor is bitmaps at fixed sizes, and an app asking for a size
    // that isn't there gets the nearest — 32 for a pointer set to 28, so
    // the same mismatch over again. So the set holds the size chosen, the
    // sizes a scaled display multiplies it to, and the usual ones.
    readonly property var xcursorSizes: {
        const out = [24, 32, 48, 64, 96];
        for (const f of [1, 1.25, 1.5, 1.6, 1.75, 2, 2.5, 3])
            out.push(Math.round(root.size * f));
        return out.filter((v, i) => v <= 256 && out.indexOf(v) === i).sort((a, b) => a - b);
    }

    // What a rebuild depends on; a change in it, settled, rebuilds.
    readonly property string key: root.enabled ? root.base + root.ink + root.acc + root.size : ""
    onKeyChanged: if (root.enabled) settle.restart()
    onEnabledChanged: root.enabled ? settle.restart() : root.restoreSystem()
    onSizeChanged: if (!root.enabled) root.restoreSystem()
    Timer { id: settle; interval: 900; onTriggered: root.build() }
    Component.onCompleted: if (root.enabled) settle.restart()

    function build() {
        // Settings may have loaded "system" since the rebuild was queued.
        if (!root.enabled) return;
        if (writer.running || builder.running) { settle.restart(); return; }
        root.error = "";
        root.building = true;
        writer.payload = JSON.stringify({
            name: root.themeName,
            sizes: root.xcursorSizes,
            shapes: Shapes.shapes(root.base, root.ink, root.acc)
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
            console.log("Cursor: hyprshell-cursors exited", code, "→", root.themeDir);
            if (code === 0) { root.built = true; root.status = "built"; if (root.enabled) root.apply(); }
            else if (code === 127) root.status = "not built";
            else if (code !== 127) root.error = buildErr.text.split("\n").filter(l => l && !/locale|UTF-8|for more information/.test(l)).pop() || ("exited " + code);
        }
    }

    // Puts a theme in use, by name.
    Process {
        id: applier
        stdout: StdioCollector {
            onStreamFinished: {
                const reply = (/hyprctl:(.*)/.exec(text) || [, ""])[1].trim();
                root.status = reply === "ok" || reply === "" ? "in use"
                            : reply === "-" ? "built (hyprctl not found — log out and in to see it)"
                            : "Hyprland refused it: " + reply;
                console.log("Cursor: setcursor said", JSON.stringify(reply));
            }
        }
    }
    // Where the theme and size are kept for everything started after
    // this: hyprland.lua reads it at login (so even the first pointer is
    // the right size), and apps started from the shell read it on the way
    // out (Config.Apps.launch), since the shell's own environment was fixed
    // when Hyprland started it.
    readonly property string envFile: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state"))
                                      + "/hyprshell/session.env"

    function use(name, size) {
        applier.command = ["sh", "-c",
            'name=$1 size=$2 ours=$3 envf=$4\n'
          + 'if command -v hyprctl >/dev/null 2>&1; then echo "hyprctl:$(hyprctl setcursor "$name" "$size" 2>&1 | head -n1)"\n'
          // Hyprland's environment, for what it starts from here on —
          // keybinds, autostart. Lua config, so hl.env through eval.
          + '  hyprctl eval "hl.env(\\"XCURSOR_THEME\\", \\"$name\\") hl.env(\\"XCURSOR_SIZE\\", \\"$size\\") '
          + 'hl.env(\\"HYPRCURSOR_THEME\\", \\"$name\\") hl.env(\\"HYPRCURSOR_SIZE\\", \\"$size\\")" >/dev/null 2>&1\n'
          + 'else echo "hyprctl:-"; fi\n'
          + 'mkdir -p "$(dirname "$envf")" && printf "export XCURSOR_THEME=\\"%s\\" XCURSOR_SIZE=%s HYPRCURSOR_THEME=\\"%s\\" HYPRCURSOR_SIZE=%s\\n" '
          + '"$name" "$size" "$name" "$size" > "$envf"\n'
          + 'export XCURSOR_THEME="$name" XCURSOR_SIZE="$size" HYPRCURSOR_THEME="$name" HYPRCURSOR_SIZE="$size"\n'
          // What systemd and the session bus start: autostart entries,
          // portals, anything D-Bus activates.
          + 'if command -v dbus-update-activation-environment >/dev/null 2>&1; then\n'
          + '  dbus-update-activation-environment --systemd XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE >/dev/null 2>&1\n'
          + 'elif command -v systemctl >/dev/null 2>&1; then\n'
          + '  systemctl --user import-environment XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE >/dev/null 2>&1\n'
          + 'fi\n'
          // XWayland apps started without the variables fall back to these.
          + 'if command -v xrdb >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then\n'
          + '  printf "Xcursor.theme: %s\\nXcursor.size: %s\\n" "$name" "$size" | xrdb -merge 2>/dev/null\n'
          + 'fi\n'
          + 'if command -v gsettings >/dev/null 2>&1; then\n'
          + '  gsettings set org.gnome.desktop.interface cursor-theme "$name" 2>/dev/null\n'
          + '  gsettings set org.gnome.desktop.interface cursor-size "$size" 2>/dev/null\n'
          + 'fi\n'
          // Qt apps using KDE's platform theme take the pointer from here,
          // ahead of the environment. Two keys; the rest of the file is KDE's.
          + 'for k in kwriteconfig6 kwriteconfig5; do\n'
          + '  if command -v $k >/dev/null 2>&1; then\n'
          + '    $k --file kcminputrc --group Mouse --key cursorTheme "$name"\n'
          + '    $k --file kcminputrc --group Mouse --key cursorSize "$size"; break\n'
          + '  fi\n'
          + 'done\n'
          // The fallback theme, for apps that name none. Left alone when it
          // is someone else's.
          + 'd="$HOME/.icons/default"; f="$d/index.theme"\n'
          + 'if [ ! -e "$f" ] || grep -q "^# hyprshell" "$f"; then\n'
          + '  if [ "$ours" = 1 ]; then\n'
          + '    mkdir -p "$d" && printf "# hyprshell: the accent cursor (Settings → Appearance)\\n[Icon Theme]\\nName=Default\\nInherits=%s\\n" "$name" > "$f"\n'
          + '  else rm -f "$f"; fi\n'
          + 'fi',
            "sh", name, String(size), name === root.themeName ? "1" : "0", root.envFile];
        applier.running = true;
    }
    function apply() { root.use(root.themeName, root.size); }
    function restoreSystem() { root.use(prefs.cursorSystemTheme || "Adwaita", root.size); }
}
