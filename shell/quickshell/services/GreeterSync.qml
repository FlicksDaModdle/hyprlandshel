pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

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

    readonly property string user: Quickshell.env("USER") || ""
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

    // Changes made together (a theme import, dragging a slider) go as one.
    Timer {
        id: syncSoon
        interval: 1200
        onTriggered: root.sync()
    }

    // The copy of theme.json, written once the files it names are in place.
    property string pending: ""
    FileView {
        id: out
        path: root.dir + "/theme.json"
        atomicWrites: true
        printErrors: false
    }

    function ext(p) {
        const m = /\.[A-Za-z0-9]{1,5}$/.exec(String(p));
        return m ? m[0].toLowerCase() : "";
    }

    function sync() {
        if (!root.active || copy.running) { if (copy.running) syncSoon.restart(); return; }
        let t;
        try { t = JSON.parse(theme.text()); } catch (e) { return; }
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

        root.pending = JSON.stringify(t, null, 2);
        const args = [];
        for (const [a, b] of media) args.push(a, b);
        copy.command = ["sh", "-c", copy.script, "greeter-sync", root.dir].concat(args);
        copy.running = true;
    }

    // Copies what changed — a file is copied again when it is a different
    // file or has changed since (size and time) — removes copies nothing
    // names any more, and leaves everything readable by the greeter.
    Process {
        id: copy
        readonly property string script: `
            dir=$1; shift
            keep=" theme.json "
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
            exit 0`
        onExited: {
            if (root.pending === "") return;
            out.setText(root.pending);
            root.lastSynced = new Date().toISOString();
            root.pending = "";
        }
    }
}
