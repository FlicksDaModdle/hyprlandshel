pragma Singleton
import QtQuick
import Quickshell
// Same directory, imported explicitly rather than leaning on QML's implicit
// one — every other reference to these singletons in the tree is qualified,
// and this keeps the static checks able to resolve it.
import "." as Config

// The dock's pinned apps (mockup: APPS in Hyprshell Live.dc.html), plus the
// class→glyph mapping the dock, task buttons and overview all share.
//
// `match` is tested against each window's Hyprland class / Wayland appId to
// decide whether a window belongs to a pinned app. These defaults assume a
// fairly generic setup — edit `exec` / `match` to whatever you actually run.
Singleton {
    id: root

    // The pinned list is editable: the dock's right-click menu writes it, and
    // it persists in theme.json. `defaultPinned` is what a fresh install gets
    // and what "Reset pinned apps" goes back to.
    //
    // `match` is a regex, which JSON has no form for, so it is stored as its
    // source string and compiled back here.
    readonly property var pinned: {
        const raw = Config.Appearance.dockPinned;
        if (!raw) return defaultPinned;
        try {
            const list = JSON.parse(raw);
            if (!Array.isArray(list) || list.length === 0) return defaultPinned;
            return list.map(e => {
                // A saved tile keeps the regex it was saved with, for
                // ever. That is right for one you re-pointed at another
                // application and wrong for one you never touched: the
                // moment anything writes the dock out — changing a
                // tile's icon does — every default is frozen as it was
                // that day, and a later release that teaches the
                // Terminal tile about a new terminal never reaches you.
                //
                // That is not hypothetical. hyprshell-term became the
                // shell's terminal, the default learned to match it, and
                // a dock saved before then went on matching kitty — so
                // the focused terminal lit no tile, showed no name, and
                // appeared a second time as an unpinned app.
                //
                // So a saved tile matches what it was saved with *or*
                // what its default says. Guarded on the source not
                // already being in there, which makes it idempotent:
                // without that, every save would wrap the last one again
                // and the regex would grow without end.
                const def = root.defaultPinned.find(d => d.key === e.key);
                const stored = e.match || "^$";
                const source = (def && stored.indexOf(def.match.source) < 0)
                    ? "(?:" + stored + ")|(?:" + def.match.source + ")"
                    : stored;
                // The same for what a tile runs: one saved while the Web
                // tile still ran plain `firefox` would never open Hyprshell
                // Browser. Only the untouched default is upgraded — a tile
                // re-pointed at another browser keeps what you chose.
                const exec = (e.key === "appWeb" && e.exec && e.exec.length === 1
                              && e.exec[0] === "firefox" && def) ? def.exec : (e.exec || []);
                return {
                    key: e.key,
                    label: e.label || (def && def.label) || "",
                    icon: e.icon,
                    exec: exec,
                    match: new RegExp(source, "i")
                };
            });
        } catch (err) {
            // A hand-edited theme.json shouldn't cost you your dock.
            console.warn("Apps: dockPinned is not valid JSON, using defaults —", err);
            return defaultPinned;
        }
    }

    function serialise(list) {
        return JSON.stringify(list.map(e => ({
            key: e.key, label: e.label, icon: e.icon,
            exec: e.exec || [],
            // RegExp.source round-trips; String(re) would keep the slashes.
            match: (e.match && e.match.source) || "^$"
        })));
    }

    function save(list) { Config.Appearance.dockPinned = serialise(list); }

    function isPinned(key) { return pinned.some(e => e.key === key); }

    function unpin(key) {
        const next = pinned.filter(e => e.key !== key);
        // Never leave an empty dock — an empty list means "use the defaults",
        // so unpinning the last app would silently restore all of them.
        save(next.length > 0 ? next : [{ key: "appSettings", label: "Settings",
                                         icon: "settings", exec: [], match: /^$/ }]);
    }

    // Moves a pinned tile to position `to` in the list, everything between
    // closing up behind it — what dropping a dragged dock tile, or Move
    // left / right in its menu, does. Out-of-range positions are clamped,
    // and a move to where it already is writes nothing.
    function move(key, to) {
        const list = pinned.slice();
        const from = list.findIndex(e => e.key === key);
        if (from < 0) return;
        const at = Math.max(0, Math.min(list.length - 1, Math.round(to)));
        if (at === from) return;
        const moved = list.splice(from, 1)[0];
        list.splice(at, 0, moved);
        save(list);
    }

    function indexOf(key) { return pinned.findIndex(e => e.key === key); }

    // Adds a running app the user right-clicked. `cls` is its Hyprland class,
    // which is also the only reliable thing to match it by later.
    //
    // What it runs comes from the app's desktop entry when there is one:
    // the class is often not the name of anything that can be started
    // (org.gnome.Nautilus, a Flatpak), and the entry's Exec line is also
    // the full path that installers like browser/install.sh write, where a
    // bare name would have to be found on a PATH that may not have it.
    function pinClass(cls, label, icon) {
        if (!cls) return;
        const key = "app:" + cls;
        if (isPinned(key)) return;
        const next = pinned.slice();
        // Before the trailing Settings tile, so that stays last as in the mockup.
        const at = next.findIndex(e => e.key === "appSettings");
        const found = DesktopEntries.heuristicLookup(cls);
        const exec = (found && found.command && found.command.length > 0)
            ? found.command.slice() : [cls];
        const entry = { key: key, label: label || cls, icon: icon || "square",
                        exec: exec, match: new RegExp("^" + cls.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$", "i") };
        if (at >= 0) next.splice(at, 0, entry); else next.push(entry);
        save(next);
    }

    // Re-points an existing tile at a different application, keeping its slot.
    // This is what right-clicking a tile and picking "Choose application" does.
    function assign(key, label, exec, icon, cls) {
        const next = pinned.map(e => e.key !== key ? e : ({
            key: e.key,
            label: label || e.label,
            icon: icon || e.icon,
            exec: exec && exec.length > 0 ? exec : e.exec,
            match: new RegExp("^" + String(cls || (exec && exec[0]) || "$^")
                              .replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$", "i")
        }));
        save(next);
    }

    // Just the glyph, leaving everything else about the tile alone.
    //
    // Not assign() with only the icon filled in: assign() rebuilds the
    // match regex from the exec it is given, so calling it to change a
    // picture would quietly re-point the tile at a different application.
    function setIcon(key, icon) {
        if (!key || !icon) return;
        save(pinned.map(e => e.key !== key ? e : ({
            key: e.key, label: e.label, icon: icon,
            exec: e.exec || [], match: e.match
        })));
    }

    // The command behind a pinned slot, as one shell word list joined for
    // Lua. Used by the keybind generator, which has to put it in a string.
    // What launches a pinned entry, as one shell line — which is the form
    // a Hyprland keybind takes.
    //
    // Two of these carry no argv at all: the terminal and the file manager
    // are found rather than named, because a bare name is looked up in the
    // compositor's PATH and misses ~/.local/bin. Returning "" for them
    // emitted `exec_cmd("")` into the generated keybinds, so rebinding
    // Terminal or File manager in Settings produced a shortcut that did
    // nothing. The finder script is the honest answer to "what launches
    // it", and it is exactly what hyprland.lua's own binds run.
    function execFor(key) {
        if (key === "appTerm") return termFinder;
        if (key === "appFiles") return filesFinder;
        // A script, not a word list: joined with spaces the sh -c would lose
        // its quoting.
        if (key === "appWeb") return webFinder;
        const e = pinned.find(x => x.key === key);
        if (!e || !e.exec || e.exec.length === 0) return "";
        return isBare(e.exec) ? finderFor(e.exec[0]) : e.exec.join(" ");
    }

    // What starting a pinned app actually runs. Its exec as saved, except a
    // lone bare name — which is what "Pin to dock" saved before it looked
    // for desktop entries, and still saves when there is none — goes
    // through a finder like the terminal's and the file manager's. Run as
    // it was, a bare name is looked up on Hyprland's PATH, which a session
    // started from a display manager often lacks ~/.local/bin on: a
    // pinned Hyprshell Browser focused its window while it had one and
    // started nothing once it was closed.
    function commandFor(app) {
        const ex = (app && app.exec) || [];
        return isBare(ex) ? ["sh", "-c", finderFor(ex[0]), "open-app"] : ex;
    }

    // One word, no path, no arguments: a name that has to be looked up.
    function isBare(ex) {
        return !!ex && ex.length === 1 && ex[0].indexOf("/") < 0 && !/\s/.test(ex[0]);
    }

    // The same search as a single shell string, for a keybind's exec_cmd.
    function finderFor(name) {
        const q = "'" + String(name).replace(/'/g, "'\\''") + "'";
        return "n=" + q + "; "
            + 'command -v "$n" >/dev/null 2>&1 && exec "$n" "$@"; '
            + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin '
            + '"$HOME/.local/share/flatpak/exports/bin" /var/lib/flatpak/exports/bin; do '
            + '[ -x "$d/$n" ] && exec "$d/$n" "$@"; done; '
            + 'notify-send "$n" "Could not find $n to start it" 2>/dev/null; exit 127';
    }

    function resetPinned() { Config.Appearance.dockPinned = ""; }

    // Pinned entries that are the shell's own windows rather than programs
    // to spawn. They carry no exec; this maps them to the command that
    // opens them, so the dock, the launcher and the tile menu do not each
    // keep their own list of which keys are special.
    readonly property var shellTiles: ({
        "appSettings": "openSettings",
        // The next three are not shell surfaces any more, but they are
        // still routed through the command table, because that is where
        // the knowledge of how to find the binary lives. A tile whose
        // `exec` is a bare name cannot look in ~/.local/bin, and cannot
        // fall back to a different program when the first is not there.
        "appFiles":    "openFiles",
        "appTerm":     "openTerminal",
        "appMusic":    "openMusic"
    })

    function isShellTile(key) { return !!shellTiles[key]; }

    // Launching the file manager, which is a separate application.
    //
    // Not a bare argv: execDetached looks the name up in the *shell's*
    // PATH, which is Hyprland's environment rather than the one your
    // terminal has, and ~/.local/bin — where install.sh puts it by
    // default — is frequently not in it. That is a launch that works when
    // you type it and silently does nothing from a keybind. So look on
    // PATH first, then in the places it is actually installed to, and say
    // something if it is in none of them.
    readonly property string filesFinder:
        'command -v hyprshell-files >/dev/null 2>&1 && exec hyprshell-files "$@"; '
        + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
        + '[ -x "$d/hyprshell-files" ] && exec "$d/hyprshell-files" "$@"; done; '
        + 'notify-send "Files" "hyprshell-files is not installed" 2>/dev/null; exit 127'

    function filesCommand(arg) {
        const cmd = ["sh", "-c", filesFinder, "open-files"];
        if (arg) cmd.push(arg);
        return cmd;
    }

    // Starting an app from the shell — launcher, dock, app menu.
    //
    // The shell's environment is the one Hyprland gave it at login, and
    // nothing can change it afterwards, so anything set since — the
    // pointer's theme and size above all (Services.Cursor) — would not
    // reach an app started from here. session.env holds the current
    // values; each launch reads it on the way out. A missing file is
    // simply skipped.
    readonly property string sessionEnvRunner:
        'f="${XDG_STATE_HOME:-$HOME/.local/state}/hyprshell/session.env"; '
        + '[ -r "$f" ] && . "$f"; '
        + 'if [ -n "$HYPRSHELL_CWD" ]; then cd "$HYPRSHELL_CWD" 2>/dev/null; unset HYPRSHELL_CWD; fi; '
        + 'exec "$@"'

    function launch(argv, workingDirectory) {
        if (!argv || argv.length === 0) return;
        const cmd = ["sh", "-c", sessionEnvRunner, "launch"];
        if (workingDirectory) cmd.splice(0, 0, "env", "HYPRSHELL_CWD=" + workingDirectory);
        for (const a of argv) cmd.push(String(a));
        Quickshell.execDetached(cmd);
    }

    // A desktop entry, through the same door. Its parsed command where the
    // entry has one; its own execute() otherwise.
    function launchEntry(entry) {
        if (!entry) return;
        const c = entry.command ? Array.from(entry.command) : [];
        if (c.length > 0) launch(c, entry.workingDirectory || "");
        else entry.execute();
    }

    function launchFiles(arg) { launch(filesCommand(arg)); }

    // The task manager (tasks/), found the same way as the file manager.
    readonly property string tasksFinder:
        'command -v hyprshell-tasks >/dev/null 2>&1 && exec hyprshell-tasks "$@"; '
        + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
        + '[ -x "$d/hyprshell-tasks" ] && exec "$d/hyprshell-tasks" "$@"; done; '
        + 'notify-send "Task Manager" "Not installed yet — run tasks/install.sh from the hyprshell folder" 2>/dev/null; exit 127'

    function tasksCommand(view) {
        const cmd = ["sh", "-c", tasksFinder, "open-tasks"];
        if (view) { cmd.push("--view"); cmd.push(view); }
        return cmd;
    }
    function launchTasks(view) { launch(tasksCommand(view)); }

    // The Files app, run as one file dialog: it prints what was chosen on
    // stdout, one path per line, and exits 1 if it was cancelled.
    //
    // This is how a shell surface gets a file dialog at all. An ordinary
    // application asks the desktop portal and the portal asks this same
    // program (see files/hyprshell.portal), but Quickshell has no file
    // dialog and no way to make a portal call and wait for the Response
    // signal that answers it — so the shell goes in the other door and
    // runs the dialog itself.
    //
    // `filters` are "Name:*.a *.b" strings; `start` is a folder, or a
    // file whose folder it opens in.
    function filesPickCommand(start, filters) {
        const cmd = ["sh", "-c", filesFinder, "pick-files", "--pick"];
        if (start) { cmd.push("--start"); cmd.push(String(start)); }
        for (const f of (filters || [])) { cmd.push("--filter"); cmd.push(f); }
        return cmd;
    }

    // Launching the terminal, the same way as the file manager above and
    // for the same reason: a bare name is looked up in Hyprland's PATH,
    // not the one a login shell built, and ~/.local/bin is routinely
    // missing from it.
    //
    // Whatever was there before is the fallback, in order, so uninstalling
    // hyprshell-term leaves a working Terminal tile rather than a dead one.
    readonly property string termFinder:
        'command -v hyprshell-term >/dev/null 2>&1 && exec hyprshell-term "$@"; '
        + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
        + '[ -x "$d/hyprshell-term" ] && exec "$d/hyprshell-term" "$@"; done; '
        + 'for t in kitty foot alacritty wezterm xterm; do '
        + 'command -v "$t" >/dev/null 2>&1 && exec "$t" "$@"; done; '
        + 'notify-send "Terminal" "no terminal is installed" 2>/dev/null; exit 127'

    // Hyprshell Browser when it is installed (browser/install.sh), Firefox
    // when it is not, whatever else is there after that. Same shape as the
    // terminal's: the launcher may be in ~/.local/bin, which a session
    // started from a display manager does not always have on its PATH.
    readonly property string webFinder:
        'command -v hyprshell-browser >/dev/null 2>&1 && exec hyprshell-browser "$@"; '
        + '[ -x "$HOME/.local/bin/hyprshell-browser" ] && exec "$HOME/.local/bin/hyprshell-browser" "$@"; '
        + 'for b in firefox chromium google-chrome-stable brave; do '
        + 'command -v "$b" >/dev/null 2>&1 && exec "$b" "$@"; done; '
        + 'notify-send "Web" "no browser is installed" 2>/dev/null; exit 127'

    // `Apps.termCommand()` opens a shell; `Apps.termCommand(["-e", "htop"])`
    // runs something in one.
    function termCommand(args) {
        const cmd = ["sh", "-c", termFinder, "open-terminal"];
        for (const a of (args || [])) cmd.push(String(a));
        return cmd;
    }

    function launchTerm(args) { launch(termCommand(args)); }

    readonly property var defaultPinned: [
        { key: "appTerm",     label: "Terminal", icon: "terminal",   exec: [],           match: /^(hyprshell-term|kitty|foot|alacritty|wezterm|org\.wezfurlong\.wezterm)$/i },
        { key: "appFiles",    label: "Files",    icon: "folder",     exec: [],           match: /^(hyprshell-files|org\.gnome\.Nautilus|nautilus|thunar|dolphin|nemo|pcmanfm.*)$/i },
        { key: "appWeb",      label: "Web",      icon: "globe",      exec: ["sh", "-c", root.webFinder, "open-web"],  match: /^(hyprshell-browser|firefox.*|chromium|google-chrome.*|brave-browser|zen.*)$/i },
        { key: "appCode",     label: "Code",     icon: "code",       exec: ["neovide"],  match: /^(neovide|code|code-oss|codium|dev\.zed\.Zed|jetbrains-.*)$/i },
        { key: "appNotes",    label: "Notes",    icon: "stickyNote", exec: ["obsidian"], match: /^(obsidian|org\.gnome\.TextEditor|logseq)$/i },
        { key: "appMusic",    label: "Music",    icon: "music",      exec: [],           match: /^(ncmpcpp|spotify|org\.gnome\.Rhythmbox3|io\.bassi\.Amberol)$/i },
        { key: "appSettings", label: "Settings", icon: "settings",   exec: [],           match: /^$/ }
        // appSettings matches nothing on purpose: the Settings window is a
        // Quickshell surface and carries Quickshell's app id, which the
        // other shell windows carry too, so matching on it would bind the
        // wrong ones.
    ]

    // Class fragments → pack glyph, checked in order. Used for any window
    // that isn't one of the pinned apps, so an unpinned running app still
    // gets a sensible icon instead of a generic block.
    readonly property var glyphHints: [
        { re: /term|foot|kitty|alacritty|wezterm|konsole|tmux/i,        icon: "terminal" },
        { re: /nautilus|thunar|dolphin|nemo|pcmanfm|files|ranger/i,     icon: "folder" },
        { re: /firefox|chrom|brave|epiphany|zen|browser|webkit/i,       icon: "globe" },
        { re: /code|nvim|neovide|vim|zed|jetbrains|emacs|idea|studio/i, icon: "code" },
        { re: /obsidian|logseq|notes|texteditor|gedit|writer/i,         icon: "stickyNote" },
        { re: /spotify|music|mpd|ncmpcpp|audacious|amberol|rhythmbox/i, icon: "music" },
        { re: /pavucontrol|volume|audio|helvum|easyeffects/i,           icon: "sliders" },
        { re: /settings|control|config|tweaks/i,                        icon: "settings" },
        { re: /image|viewer|loupe|eog|imv|gwenview|gimp|inkscape/i,     icon: "image" },
        { re: /video|mpv|vlc|celluloid|obs/i,                           icon: "monitor" },
        { re: /discord|telegram|signal|element|slack|chat|mail|thunderbird/i, icon: "stickyNote" },
        { re: /steam|game|lutris|heroic/i,                              icon: "gamepad" },
        { re: /bluetooth|blueman/i,                                     icon: "bluetooth" },
        { re: /network|nm-|wifi/i,                                      icon: "wifi" },
        { re: /screenshot|grim|slurp|capture|flameshot/i,               icon: "camera" },
        { re: /pkg|package|software|discover|store|pamac/i,             icon: "pkg" },
        { re: /monitor|htop|btop|system|resources|task/i,               icon: "cpu" }
    ]

    // Resolves an icon name from a .desktop entry, a tray item or a
    // notification into something IconImage can actually load. Returns "" when
    // the icon theme has no such icon, so callers can fall back to the
    // bespoke pack rather than showing a broken image.
    function themeIcon(name) {
        if (!name) return "";
        // Already a usable source: absolute path, or a URL scheme Quickshell
        // hands out (tray items come through as image:// providers).
        if (name.charAt(0) === "/" || name.indexOf("file:") === 0
            || name.indexOf("image:") === 0 || name.indexOf("qrc:") === 0
            || name.indexOf("http") === 0) return name;
        return Quickshell.iconPath(name, true);
    }

    function pinnedFor(cls) {
        if (!cls) return null;
        return pinned.find(a => a.match.test(cls)) || null;
    }

    function iconFor(cls) {
        const app = pinnedFor(cls);
        if (app) return app.icon;
        for (const hint of glyphHints) {
            if (hint.re.test(cls || "")) return hint.icon;
        }
        return "square";
    }

    // Prefer the pinned app's own label, then the window's desktop entry
    // name, then a tidied-up class string ("org.gnome.Nautilus" → "Nautilus").
    function labelFor(cls) {
        const app = pinnedFor(cls);
        if (app) return app.label;
        if (!cls) return "Window";
        const entry = DesktopEntries.heuristicLookup(cls);
        if (entry && entry.name) return entry.name;
        const tail = cls.split(".").pop();
        return tail.charAt(0).toUpperCase() + tail.slice(1);
    }
}
