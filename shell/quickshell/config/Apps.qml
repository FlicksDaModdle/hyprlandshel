pragma Singleton
import QtQuick
import Quickshell

// The dock's pinned app row (mockup: APPS in Hyprshell Live.dc.html).
// `match` is a case-insensitive regex tested against each Wayland
// toplevel's appId (Quickshell.Wayland.Toplevel.appId) to decide whether
// that toplevel belongs to this pinned app.
//
// These defaults assume a fairly generic setup — edit `exec`/`match` to
// whatever's actually installed. Some apps in the original mockup (mpd as
// a "Music" tile) don't have one obvious real equivalent, so pick a real
// client you use.
Singleton {
    id: root

    readonly property var pinned: [
        { key: "appTerm",     label: "Terminal", icon: "terminal",      exec: ["foot"],                 match: /^foot$/i },
        { key: "appFiles",    label: "Files",    icon: "folder",        exec: ["nautilus"],              match: /^org\.gnome\.Nautilus$/i },
        { key: "appWeb",      label: "Web",      icon: "globe",         exec: ["firefox"],               match: /^firefox/i },
        { key: "appCode",     label: "Code",     icon: "code",          exec: ["neovide"],               match: /^neovide$/i },
        { key: "appNotes",    label: "Notes",    icon: "stickyNote",    exec: ["obsidian"],              match: /^obsidian$/i },
        { key: "appMusic",    label: "Music",    icon: "music",         exec: ["footclient", "-e", "ncmpcpp"], match: /^ncmpcpp$/i },
        { key: "appSettings", label: "Settings", icon: "settings",      exec: [],                        match: /^$/ }
    ]
}
