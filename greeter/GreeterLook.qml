import QtQuick
import Quickshell
import Quickshell.Io

// The login screen at your desktop's size, with your pointer.
//
// The greeter's Hyprland starts with its own defaults — every screen at
// its preferred mode and Hyprland's automatic scale, and the default
// pointer at 24 px — so the login screen came up at a different size from
// the desktop it leads to, with a different cursor. Your shell keeps what
// your desktop uses in your greeter folder (services/GreeterSync.qml):
//
//   screens.json   each screen's mode, position and scale
//   cursor.json    the cursor theme and size
//   cursor/        the theme itself, when it is one in your home (the
//                  accent cursor is) that the greeter could not read
//
// and this hands them to the greeter's Hyprland when it starts, and again
// if a different person is picked.
//
// It also keeps them for next time, as look.lua in the greeter's cache,
// which greeter/hyprland.lua runs before anything is drawn: so the login
// screen comes up at your scale and with your pointer from its first
// frame, rather than at Hyprland's own and changing a moment later. The
// pointer is set there for the greeter itself too (XCURSOR_THEME), for a
// Qt that draws its own instead of asking Hyprland to.
//
// The theme folder is linked into the greeter's own icon folder, in the
// home greeter/hyprland.lua gives its Hyprland — where hyprcursor looks when
// told to use a theme by name — and on XCURSOR_PATH.
//
// Everything read here was written by a person, not by the greeter, so it
// is checked to be what it should be — names of screens and themes, and
// numbers — before any of it goes near a command.
//
// In a preview (not run by greetd) nothing is applied: it would be your own
// Hyprland it changed. HYPRSHELL_GREETER_LOOK_DRYRUN=1 prints what would be.
Scope {
    id: look

    required property var greeter
    readonly property string userDir: greeter.userDir
    readonly property string cacheDir: {
        const f = String(greeter.stateFile);
        return f.slice(0, f.lastIndexOf("/"));
    }
    // The greeter's Hyprland's own ~/.local/share/icons (hyprland.lua says
    // why it has a home of its own).
    readonly property string iconsDir: cacheDir + "/home/.local/share/icons"
    readonly property bool live: !greeter.preview
    readonly property bool dryRun: Quickshell.env("HYPRSHELL_GREETER_LOOK_DRYRUN") === "1"

    property var screens: null
    property var cursor: null
    property bool screensRead: false
    property bool cursorRead: false

    FileView {
        path: look.userDir !== "" ? look.userDir + "/screens.json" : ""
        printErrors: false
        onPathChanged: { look.screens = null; look.screensRead = false; }
        onLoaded: {
            try { look.screens = JSON.parse(text()); } catch (e) { look.screens = null; }
            look.screensRead = true;
        }
        onLoadFailed: look.screensRead = true
    }
    FileView {
        path: look.userDir !== "" ? look.userDir + "/cursor.json" : ""
        printErrors: false
        onPathChanged: { look.cursor = null; look.cursorRead = false; }
        onLoaded: {
            try { look.cursor = JSON.parse(text()); } catch (e) { look.cursor = null; }
            look.cursorRead = true;
        }
        onLoadFailed: look.cursorRead = true
    }

    // Both read (or found missing) for the person picked: apply, once.
    readonly property string ready: screensRead && cursorRead ? userDir : ""
    onReadyChanged: if (ready !== "") settle.restart()
    Timer { id: settle; interval: 50; onTriggered: look.apply() }

    function num(v, lo, hi) {
        const n = Number(v);
        return isFinite(n) && n >= lo && n <= hi ? n : null;
    }

    // hl.monitor for each screen, in the same form the shell sends.
    function monitorLua() {
        if (!Array.isArray(look.screens)) return "";
        let lua = "";
        for (const m of look.screens) {
            if (!m || !/^[A-Za-z0-9_.:-]{1,64}$/.test(String(m.name))) continue;
            const w = look.num(m.width, 1, 16384), h = look.num(m.height, 1, 16384);
            const hz = look.num(m.refreshRate, 1, 1000), sc = look.num(m.scale, 0.25, 8);
            const x = look.num(m.x, -65536, 65536), y = look.num(m.y, -65536, 65536);
            if (w === null || h === null || hz === null || sc === null) continue;
            lua += 'hl.monitor({ output = "' + m.name + '", mode = "' + Math.round(w) + "x" + Math.round(h)
                 + "@" + (Math.round(hz * 1000) / 1000) + '", position = "'
                 + (x === null || y === null ? "auto" : Math.round(x) + "x" + Math.round(y))
                 + '", scale = ' + (Math.round(sc * 1e6) / 1e6) + " }) ";
        }
        return lua;
    }

    function apply() {
        const lua = look.monitorLua();
        const c = look.cursor || ({});
        const theme = /^[A-Za-z0-9 _.+-]{1,64}$/.test(String(c.theme || "")) ? String(c.theme) : "";
        const size = Math.round(look.num(c.size, 8, 256) || 24);
        if (lua === "" && theme === "") return;
        // For the next start: the same screens, and the pointer as
        // environment, which is how Hyprland and Qt pick one up at launch.
        let boot = lua.replace(/\) hl\.monitor/g, ")\nhl.monitor");
        if (theme !== "")
            for (const v of ["XCURSOR_THEME", "HYPRCURSOR_THEME"])
                boot += '\nhl.env("' + v + '", "' + theme + '")';
        for (const v of ["XCURSOR_SIZE", "HYPRCURSOR_SIZE"])
            boot += '\nhl.env("' + v + '", "' + size + '")';
        if (!look.live) {
            if (look.dryRun) console.log("greeter look:", JSON.stringify({ lua: lua, theme: theme, size: size,
                                                                          link: look.userDir + "/cursor", boot: boot }));
            return;
        }
        run.command = ["sh", "-c", run.script, "greeter-look",
                       look.iconsDir, theme, String(size), look.userDir + "/cursor", lua,
                       look.cacheDir + "/look.lua", "-- Written by the greeter (GreeterLook.qml) for its next start.\n" + boot + "\n"];
        run.running = true;
    }

    // Screens first: the pointer is scaled with the screen it is on.
    Process {
        id: run
        readonly property string script: `
            icons=$1 theme=$2 size=$3 src=$4 lua=$5 boot=$6 bootlua=$7
            [ -n "$lua" ] && hyprctl eval "$lua" >/dev/null 2>&1
            printf '%s' "$bootlua" > "$boot.tmp" && mv -f "$boot.tmp" "$boot"
            if [ -n "$theme" ]; then
                mkdir -p "$icons"
                # The person picked's own copy, or none: a theme of the same
                # name left linked from someone else would be theirs.
                if [ -d "$src" ]; then ln -sfn "$src" "$icons/$theme"
                elif [ -L "$icons/$theme" ]; then rm -f "$icons/$theme"; fi
                hyprctl setcursor "$theme" "$size" >/dev/null 2>&1
            fi
            exit 0`
    }
}
