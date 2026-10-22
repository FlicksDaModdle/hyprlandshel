pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Spotify in the shell's colours, through Spicetify.
//
// Writes a Spicetify theme, ~/.config/spicetify/Themes/Hyprshell/, from the
// theme the shell is wearing: color.ini (Spicetify's colour scheme, "shell")
// and user.css (assets/spicetify/user.css, with the shell's radii, font and
// ink-on-accent put at its top). Whenever the theme changes it writes them
// again, and if Spotify is wearing it, has Spicetify put the new files into
// Spotify — without restarting it, so the music doesn't stop; Spotify shows
// the new colours the next time it starts.
//
// Nothing happens until Spicetify is set up (spotify/install.sh), so having
// this on by default costs nothing on a computer without Spotify.
Singleton {
    id: root

    readonly property string dir: (Quickshell.env("XDG_CONFIG_HOME")
                                   || (Quickshell.env("HOME") + "/.config"))
                                  + "/spicetify"
    readonly property string themeName: "Hyprshell"
    readonly property string themeDir: dir + "/Themes/" + themeName
    readonly property bool enabled: Config.Appearance.spotifyTheme

    // Spicetify's own config: there once it is set up, and it says which
    // theme Spotify is wearing.
    property bool installed: false
    property bool wearing: false
    FileView {
        id: spiceConfig
        path: root.dir + "/config-xpui.ini"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.installed = true;
            root.wearing = /^\s*current_theme\s*=\s*Hyprshell\s*$/m.test(text());
        }
        onLoadFailed: { root.installed = false; root.wearing = false; }
    }

    // ── colours ───────────────────────────────────────────────────────────
    function hex(c) {
        function two(n) {
            const s = Math.round(Math.max(0, Math.min(255, n * 255))).toString(16);
            return s.length < 2 ? "0" + s : s;
        }
        return two(c.r) + two(c.g) + two(c.b);
    }
    // A translucent token flattened onto what it sits on: Spotify's colours
    // are solid.
    function over(top, under) {
        const a = top.a;
        return Qt.rgba(top.r * a + under.r * (1 - a), top.g * a + under.g * (1 - a),
                       top.b * a + under.b * (1 - a), 1);
    }

    readonly property var ap: Config.Appearance
    readonly property color danger: ap.dark ? "#ff5a52" : "#d93a32"
    readonly property string colorIni: {
        const a = ap;
        // The panels sit a shade off the ground, as the shell's do on the
        // desktop; cards a shade further.
        const side = over(Qt.rgba(a.surface.r, a.surface.g, a.surface.b, 0.45), a.ground);
        const card = a.surface;
        const rows = [
            ["text", a.ink],
            ["subtext", a.ink2],
            ["main", a.ground],
            ["main-elevated", card],
            ["sidebar", side],
            ["player", side],
            ["card", card],
            ["highlight", over(a.hover, side)],
            ["highlight-elevated", over(a.sel, card)],
            ["shadow", Qt.rgba(0, 0, 0, 1)],
            ["selected-row", a.ink],
            ["button", a.accent],
            ["button-active", Qt.lighter(a.accent, 1.12)],
            ["button-disabled", a.ink3],
            ["tab-active", over(a.sel, side)],
            ["notification", card],
            ["notification-error", root.danger],
            ["misc", a.ink3]
        ];
        return "; Written by Hyprshell (services/Spicetify.qml) from the shell's theme;\n"
             + "; changes here are replaced the next time the theme changes.\n"
             + "[shell]\n"
             + rows.map(r => r[0] + " = " + hex(r[1])).join("\n") + "\n";
    }

    // ── the stylesheet ────────────────────────────────────────────────────
    FileView {
        id: template
        path: (Quickshell.shellDir || Quickshell.shellRoot || "") + "/assets/spicetify/user.css"
        preload: true
        printErrors: false
    }
    readonly property string userCss: template.text() === "" ? "" :
        ":root {\n"
        + "    --hs-r: " + ap.rPanel + "px;\n"
        + "    --hs-rsm: " + ap.rSm + "px;\n"
        + "    --hs-font: \"" + ap.fontFamily + "\";\n"
        + "    --hs-on-accent: #" + hex(ap.inkOnAccent) + ";\n"
        + "}\n\n" + template.text()

    // ── writing it out ────────────────────────────────────────────────────
    FileView { id: colorFile; path: root.themeDir + "/color.ini"; preload: true; printErrors: false; atomicWrites: true }
    FileView { id: cssFile; path: root.themeDir + "/user.css"; preload: true; printErrors: false; atomicWrites: true }

    Process { id: mkdir }
    // Into Spotify, if it's wearing this theme; never restarting it.
    // A change while one is going in is put in after it.
    property bool refreshAgain: false
    Process {
        id: refresh
        onExited: if (root.refreshAgain) { root.refreshAgain = false; running = true; }
        command: ["sh", "-c",
            'for s in spicetify "$HOME/.spicetify/spicetify" "$HOME/.local/bin/spicetify"; do '
            + 'command -v "$s" >/dev/null 2>&1 && exec "$s" -n refresh >/dev/null 2>&1; done; exit 0']
    }

    // Spicetify set up since the shell started (spotify/install.sh asks,
    // through hyprshellctl syncTheming): look again, and write.
    function recheck() {
        spiceConfig.reload();
        apply();
    }

    function apply() {
        if (!enabled || !installed || userCss === "") return;
        mkdir.command = ["mkdir", "-p", root.themeDir];
        mkdir.running = true;
        write.restart();
    }
    Timer {
        id: write
        interval: 400
        onTriggered: {
            let changed = false;
            if (colorFile.text() !== root.colorIni) { colorFile.setText(root.colorIni); changed = true; }
            if (cssFile.text() !== root.userCss) { cssFile.setText(root.userCss); changed = true; }
            if (!changed || !root.wearing) return;
            if (refresh.running) root.refreshAgain = true;
            else refresh.running = true;
        }
    }

    // Written when anything in either file would differ, and when Spicetify
    // turns up.
    readonly property string watched: enabled && installed ? colorIni + userCss : ""
    onWatchedChanged: apply()
}
