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
            return list.map(e => ({
                key: e.key,
                label: e.label,
                icon: e.icon,
                exec: e.exec || [],
                match: new RegExp(e.match || "^$", "i")
            }));
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

    // Adds a running app the user right-clicked. `cls` is its Hyprland class,
    // which is also the only reliable thing to match it by later.
    function pinClass(cls, label, icon) {
        if (!cls) return;
        const key = "app:" + cls;
        if (isPinned(key)) return;
        const next = pinned.slice();
        // Before the trailing Settings tile, so that stays last as in the mockup.
        const at = next.findIndex(e => e.key === "appSettings");
        const entry = { key: key, label: label || cls, icon: icon || "square",
                        exec: [cls], match: new RegExp("^" + cls.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$", "i") };
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
    function execFor(key) {
        const e = pinned.find(x => x.key === key);
        return (e && e.exec && e.exec.length > 0) ? e.exec.join(" ") : "";
    }

    function resetPinned() { Config.Appearance.dockPinned = ""; }

    // Pinned entries that are the shell's own windows rather than programs
    // to spawn. They carry no exec; this maps them to the command that
    // opens them, so the dock, the launcher and the tile menu do not each
    // keep their own list of which keys are special.
    readonly property var shellTiles: ({
        "appSettings": "openSettings",
        // Not a shell surface any more, but still routed through the
        // command table, because that is where the knowledge of how to find
        // the binary lives.
        "appFiles":    "openFiles"
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

    function launchFiles(arg) { Quickshell.execDetached(filesCommand(arg)); }

    readonly property var defaultPinned: [
        { key: "appTerm",     label: "Terminal", icon: "terminal",   exec: ["kitty"],    match: /^(kitty|foot|alacritty|wezterm|org\.wezfurlong\.wezterm)$/i },
        { key: "appFiles",    label: "Files",    icon: "folder",     exec: [],           match: /^(hyprshell-files|org\.gnome\.Nautilus|nautilus|thunar|dolphin|nemo|pcmanfm.*)$/i },
        { key: "appWeb",      label: "Web",      icon: "globe",      exec: ["firefox"],  match: /^(firefox.*|chromium|google-chrome.*|brave-browser|zen.*)$/i },
        { key: "appCode",     label: "Code",     icon: "code",       exec: ["neovide"],  match: /^(neovide|code|code-oss|codium|dev\.zed\.Zed|jetbrains-.*)$/i },
        { key: "appNotes",    label: "Notes",    icon: "stickyNote", exec: ["obsidian"], match: /^(obsidian|org\.gnome\.TextEditor|logseq)$/i },
        { key: "appMusic",    label: "Music",    icon: "music",      exec: ["kitty", "-e", "ncmpcpp"], match: /^(ncmpcpp|spotify|org\.gnome\.Rhythmbox3|io\.bassi\.Amberol)$/i },
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
