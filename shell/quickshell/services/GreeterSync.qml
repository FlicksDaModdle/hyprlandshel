pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Keeps the login screen dressed like your desktop.
//
// The greeter runs as greetd's own user, who cannot read your home folder,
// so it cannot read your theme.json or your wallpaper where they are. The
// greeter's installer gives each person a folder it can read and they can
// write — /var/lib/hyprshell-greeter/users/<you> — and this keeps a copy of
// your theme there, and of the picture or video it names, every time either
// changes: change the accent in Settings and the next login screen has it.
//
// The copy of theme.json points at the copies (wallpaper.<ext>, live.<ext>,
// live-<n>.<ext> for a screen's own video, face for your picture), so the
// greeter draws them with the same code the desktop and the lock screen
// do. Lists that are only yours — the folders videos are found in — are
// left out.
//
// Without that folder (the greeter not installed, or installed before
// this), it does nothing.
Singleton {
    id: root

    // $USER, or who `id` says this is when the session was started without
    // it.
    property string user: Quickshell.env("USER") || ""
    Process {
        running: root.user === ""
        command: ["id", "-un"]
        stdout: StdioCollector { onStreamFinished: root.user = text.trim() }
    }
    readonly property string dir: "/var/lib/hyprshell-greeter/users/" + root.user
    readonly property string home: Quickshell.env("HOME") || ""

    // Whether there is a folder to keep the copy in, and it is ours.
    property bool active: false
    property string lastSynced: ""

    Process {
        id: probe
        running: root.user !== ""
        command: ["sh", "-c", 'test -d "$1" && test -w "$1"', "probe", root.dir]
        onExited: code => {
            root.active = code === 0;
            if (root.active) syncSoon.restart();
        }
    }

    // Installed while the shell runs: noticed within a minute.
    Timer {
        running: !root.active && root.user !== ""
        interval: 60000
        repeat: true
        onTriggered: probe.running = true
    }

    // Your theme, watched: the shell writes it on every change.
    FileView {
        id: theme
        path: Config.Appearance.configDir + "/theme.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: if (root.active) syncSoon.restart()
    }

    // The watch can be lost — the shell replaces theme.json rather than
    // writing into it, and a watched file that is replaced is no longer the
    // one being watched — so it is also read again every minute, and copied
    // only if it changed.
    Timer {
        running: root.active
        interval: 60000
        repeat: true
        onTriggered: theme.reload()
    }

    // Changes made together (a theme import, dragging a slider) go as one.
    Timer {
        id: syncSoon
        interval: 1200
        onTriggered: root.sync()
    }

    // The screens as the desktop has them — mode, position and scale — so
    // the login screen is the same size as the desktop rather than at
    // Hyprland's automatic scale. From what Hyprland reports, so a scale
    // set in hyprland.lua counts as much as one set in Settings.
    readonly property string screensText: JSON.stringify((Services.Compositor.monitors || [])
        .filter(m => m && m.name)
        .map(m => {
            const o = m.lastIpcObject || ({});
            return {
                name: String(m.name),
                width: o.width || m.width, height: o.height || m.height,
                refreshRate: o.refreshRate || 60,
                x: o.x !== undefined ? o.x : m.x, y: o.y !== undefined ? o.y : m.y,
                scale: m.scale || o.scale || 1
            };
        }), null, 2)
    // And the pointer: the accent theme (copied, as it lives in your home)
    // or the system one named in Settings, at your size.
    readonly property string cursorText: JSON.stringify({
        theme: Services.Cursor.enabled ? Services.Cursor.themeName
                                       : (Config.Appearance.cursorSystemTheme || "Adwaita"),
        size: Services.Cursor.size
    }, null, 2)
    onScreensTextChanged: if (root.active) syncSoon.restart()
    onCursorTextChanged: if (root.active) syncSoon.restart()
    // A rebuilt accent cursor — a new accent — is copied once it is built.
    Connections {
        target: Services.Cursor
        function onBuildingChanged() { if (!Services.Cursor.building && root.active) syncSoon.restart(); }
    }

    // The copy of theme.json, written once the files it names are in place.
    FileView {
        id: out
        path: root.dir + "/theme.json"
        atomicWrites: true
        printErrors: false
    }
    FileView {
        id: outScreens
        path: root.dir + "/screens.json"
        atomicWrites: true
        printErrors: false
    }
    FileView {
        id: outCursor
        path: root.dir + "/cursor.json"
        atomicWrites: true
        printErrors: false
    }
    // What was last written to each, to write only what changed.
    property var written: ({})
    property var pendingFiles: ({})

    function ext(p) {
        const m = /\.[A-Za-z0-9]{1,5}$/.exec(String(p));
        return m ? m[0].toLowerCase() : "";
    }

    function sync() {
        if (!root.active || copy.running) { if (copy.running) syncSoon.restart(); return; }
        const source = theme.text();
        let t;
        try { t = JSON.parse(source); } catch (e) { return; }
        if (!t || typeof t !== "object") return;

        const media = [];       // [from, to]
        if (t.wallpaper) {
            const to = root.dir + "/wallpaper" + root.ext(t.wallpaper);
            media.push([t.wallpaper, to]);
            t.wallpaper = to;
        }
        const chosen = t.liveWallpaper || "";
        if (chosen) {
            const to = root.dir + "/live" + root.ext(chosen);
            media.push([chosen, to]);
            t.liveWallpaper = to;
        }
        if (t.liveScreens) {
            try {
                const m = JSON.parse(t.liveScreens) || {};
                let n = 0;
                for (const k of Object.keys(m)) {
                    if (!m[k]) continue;
                    if (m[k] === chosen) { m[k] = t.liveWallpaper; continue; }
                    const to = root.dir + "/live-" + (n++) + root.ext(m[k]);
                    media.push([m[k], to]);
                    m[k] = to;
                }
                t.liveScreens = JSON.stringify(m);
            } catch (e) { t.liveScreens = ""; }
        }
        // Only yours, and of no use to a login screen.
        t.liveFolders = "";
        t.liveFiles = "";
        t.liveLast = "";
        media.push([root.home + "/.face", root.dir + "/face"]);

        // Each written only when it is new, or the copy there has gone (the
        // greeter reinstalled); the files they name are checked every time,
        // and copied only when they changed.
        root.pendingFiles = {
            "theme.json": JSON.stringify(t, null, 2),
            "screens.json": root.screensText,
            "cursor.json": root.cursorText
        };
        const args = [];
        for (const [a, b] of media) args.push(a, b);
        const cursorTheme = Services.Cursor.enabled ? Services.Cursor.themeName
                                                    : (Config.Appearance.cursorSystemTheme || "");
        copy.command = ["sh", "-c", copy.script, "greeter-sync", root.dir, cursorTheme,
                        Services.Cursor.dataHome].concat(args);
        copy.running = true;
    }

    // Copies what changed — a file is copied again when it is a different
    // file or has changed since (size and time) — removes copies nothing
    // names any more, and leaves everything readable by the greeter.
    Process {
        id: copy
        readonly property string script: `
            dir=$1 curname=$2 datahome=$3; shift 3
            keep=" theme.json screens.json cursor.json "
            # The cursor theme, when it is one in your home the greeter cannot
            # read: the whole folder, again whenever anything in it changed.
            src=""
            if [ -n "$curname" ]; then
                for d in "$datahome/icons/$curname" "$HOME/.icons/$curname"; do
                    [ -d "$d" ] && { src=$d; break; }
                done
            fi
            if [ -n "$src" ]; then
                stamp="$src $(find "$src" -printf '%T@\n' 2>/dev/null | sort -n | tail -n1)"
                if [ ! -d "$dir/cursor" ] || [ "$(cat "$dir/.cursor.from" 2>/dev/null)" != "$stamp" ]; then
                    rm -rf "$dir/cursor.part"
                    cp -a "$src" "$dir/cursor.part" 2>/dev/null && chmod -R a+rX "$dir/cursor.part" \
                        && rm -rf "$dir/cursor" && mv "$dir/cursor.part" "$dir/cursor" \
                        && printf '%s' "$stamp" > "$dir/.cursor.from"
                fi
            else
                rm -rf "$dir/cursor" "$dir/.cursor.from"
            fi
            while [ $# -ge 2 ]; do
                from=$1; to=$2; shift 2
                name=\${to##*/}
                [ -f "$from" ] || continue
                keep="$keep$name "
                stamp="$from $(stat -Lc '%s %Y' "$from" 2>/dev/null)"
                if [ ! -f "$to" ] || [ "$(cat "$dir/.$name.from" 2>/dev/null)" != "$stamp" ]; then
                    cp -fL --reflink=auto "$from" "$to.part" 2>/dev/null && mv -f "$to.part" "$to" \\
                        && chmod 644 "$to" && printf '%s' "$stamp" > "$dir/.$name.from"
                fi
            done
            for f in "$dir"/*; do
                [ -f "$f" ] || continue
                n=\${f##*/}
                case "$keep" in *" $n "*) ;; *) rm -f "$f" "$dir/.$n.from" ;; esac
            done
            chmod 755 "$dir" 2>/dev/null
            for n in theme.json screens.json cursor.json; do [ -f "$dir/$n" ] && echo "$n"; done
            exit 0`
        stdout: StdioCollector { id: copyOut }
        onExited: {
            const there = copyOut.text.split("\n");
            const views = { "theme.json": out, "screens.json": outScreens, "cursor.json": outCursor };
            const done = Object.assign({}, root.written);
            let any = false;
            for (const name in root.pendingFiles) {
                const text = root.pendingFiles[name];
                if (text === root.written[name] && there.indexOf(name) >= 0) continue;
                views[name].setText(text);
                done[name] = text;
                any = true;
            }
            root.written = done;
            root.pendingFiles = ({});
            if (any) {
                root.lastSynced = new Date().toISOString();
                console.log("GreeterSync: login screen updated in", root.dir);
            }
        }
    }
}
