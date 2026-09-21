pragma Singleton
import QtQuick
import Quickshell

// The dock's pinned apps (mockup: APPS in Hyprshell Live.dc.html), plus the
// class→glyph mapping the dock, task buttons and overview all share.
//
// `match` is tested against each window's Hyprland class / Wayland appId to
// decide whether a window belongs to a pinned app. These defaults assume a
// fairly generic setup — edit `exec` / `match` to whatever you actually run.
Singleton {
    id: root

    readonly property var pinned: [
        { key: "appTerm",     label: "Terminal", icon: "terminal",   exec: ["foot"],     match: /^(foot|kitty|alacritty|wezterm|org\.wezfurlong\.wezterm)$/i },
        { key: "appFiles",    label: "Files",    icon: "folder",     exec: ["nautilus"], match: /^(org\.gnome\.Nautilus|nautilus|thunar|dolphin|nemo|pcmanfm.*)$/i },
        { key: "appWeb",      label: "Web",      icon: "globe",      exec: ["firefox"],  match: /^(firefox.*|chromium|google-chrome.*|brave-browser|zen.*)$/i },
        { key: "appCode",     label: "Code",     icon: "code",       exec: ["neovide"],  match: /^(neovide|code|code-oss|codium|dev\.zed\.Zed|jetbrains-.*)$/i },
        { key: "appNotes",    label: "Notes",    icon: "stickyNote", exec: ["obsidian"], match: /^(obsidian|org\.gnome\.TextEditor|logseq)$/i },
        { key: "appMusic",    label: "Music",    icon: "music",      exec: ["footclient", "-e", "ncmpcpp"], match: /^(ncmpcpp|spotify|org\.gnome\.Rhythmbox3|io\.bassi\.Amberol)$/i },
        { key: "appSettings", label: "Settings", icon: "settings",   exec: [],           match: /^$/ }
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
