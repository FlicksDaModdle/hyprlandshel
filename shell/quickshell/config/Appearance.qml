pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Design tokens, ported from the Claude Design mockup's CSS custom
// properties ([data-shell] / [data-shell="dark"] in Hyprshell Live.dc.html),
// plus every knob the mockup's Settings → Appearance / Bar / Dock /
// Notifications panes can turn.
//
// Everything the user can change is persisted to theme.json (the same file
// the mockup's Files window shows in ~/.config/quickshell) via a JsonAdapter,
// so a shell reload keeps your theme. Derived colors/radii below are read-only
// and recompute from those values.
Singleton {
    id: root

    // ── persistence ───────────────────────────────────────────────────────
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
                                        + "/quickshell/hyprshell"

    FileView {
        id: store
        path: root.configDir + "/theme.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        // A missing file is normal on first run: write defaults out so the
        // file exists and is editable by hand.
        onLoadFailed: error => { if (error === FileViewError.FileNotFound) writeAdapter(); }

        JsonAdapter {
            id: prefs

            // Appearance
            property string theme: "light"          // "light" | "dark" | "auto"
            property int accent: 0                    // index into accentPresets, -1 = custom
            property string customAccent: "#3b6ef5"
            property int translucency: 50             // 0-100 %, how much shows through panels
            property int rounding: 100                // 0-160 %
            property string tint: "Warm"              // "Warm" | "Neutral" | "Cool"
            property string wallpaper: ""             // absolute path; empty = tinted gradient

            // Bar
            property int barHeight: 40                // 32-56 px
            property bool clock24: true
            property bool showTray: true
            property bool trayOpen: false
            property bool showTasks: false

            // Dock
            property string dockPosition: "Bottom"    // "Bottom" | "Left"
            property int dockSize: 42                 // 34-58 px
            property int dockIcon: 50                 // 30-72 %
            property bool dockLabels: true
            property bool dockHide: false
            // The pinned apps, as a JSON array of
            // { key, label, icon, exec[], match } — empty means "use the
            // defaults in config/Apps.qml". Carried as text because a
            // JsonAdapter property is a scalar and `match` is a regex
            // source, which has no JSON form of its own.
            property string dockPinned: ""

            // Input devices. These are applied to Hyprland at startup and
            // whenever they change — Hyprland's config is write-only over
            // IPC, so the shell has to be the thing that remembers them.
            property int repeatRate: 25
            property int repeatDelay: 600
            property bool numlock: false
            property int followMouse: 1
            property real sensitivity: 0
            property string accelProfile: "adaptive"
            property bool leftHanded: false
            property bool mouseNaturalScroll: false
            property real mouseScrollFactor: 1
            property bool hideCursorOnKey: true
            property int cursorTimeout: 0
            property bool tapToClick: true
            property bool tapAndDrag: true
            property bool dragLock: false
            property bool padNaturalScroll: true
            property real padScrollFactor: 1
            property bool disableWhileTyping: true
            property bool clickfinger: false
            property string tapButtonMap: "lrm"
            property bool middleEmulation: false

            // Per-output display state, as JSON:
            //   { "DP-1": { "mode": "2560x1440@165", "scale": 1.25 }, ... }
            // Re-applied at startup, since Hyprland goes back to whatever
            // hyprland.lua says on every launch.
            property string displays: ""

            // Typography
            property int fontScale: 100               // 75-150 %
            property int barFontSize: 12              // 10-18 px
            property int barTitleSize: 12             // window title beside the app name
            property int barAppSize: 16               // the focused app's name
            property int barClockSize: 13             // the clock's time
            property int barBadgeSize: 11             // notification count
            property int dockLabelSize: 12            // dock tooltips and the active label
            property int launcherTitleSize: 13        // launcher entry names
            property int launcherMetaSize: 11         // launcher categories and hints

            // Launcher geometry
            property int launcherWidth: 720
            property int launcherHeight: 560
            property int launcherTileSize: 70
            property int launcherColumns: 4

            // How much of the window shows through a dropdown or the colour
            // picker. 0 is fully opaque.
            property int menuTranslucency: 8          // 0-60 %

            // Hyprland window frame
            property int gapsIn: 4
            property int gapsOut: 8
            property int borderSize: 1
            property bool borderFollowsAccent: true

            // Notifications
            property bool dnd: false
            property bool badges: true
            property string grouping: "App"           // "App" | "Time"
            property int popupTimeout: 5              // seconds a banner stays up

            // Shell state, not a device reading: see ControlCenter's tile.
            property bool gameMode: false
        }
    }

    // Persisted values are exposed as plain aliases so call sites read
    // `Appearance.barHeight`, not `Appearance.prefs.barHeight`.
    property alias theme: prefs.theme
    property alias accentIndex: prefs.accent
    property alias customAccent: prefs.customAccent
    property alias translucency: prefs.translucency
    property alias roundingPct: prefs.rounding
    property alias tint: prefs.tint
    property alias wallpaper: prefs.wallpaper
    property alias barHeight: prefs.barHeight
    property alias clock24: prefs.clock24
    property alias showTray: prefs.showTray
    property alias trayOpen: prefs.trayOpen
    property alias showTasks: prefs.showTasks
    property alias dockPositionName: prefs.dockPosition
    property alias dockTileSize: prefs.dockSize
    property alias dockIconPct: prefs.dockIcon
    property alias dockLabels: prefs.dockLabels
    property alias dockAutoHide: prefs.dockHide
    property alias dockPinned: prefs.dockPinned

    // ── input devices ─────────────────────────────────────────────────────
    property alias repeatRate: prefs.repeatRate
    property alias repeatDelay: prefs.repeatDelay
    property alias numlock: prefs.numlock
    property alias followMouse: prefs.followMouse
    property alias sensitivity: prefs.sensitivity
    property alias accelProfile: prefs.accelProfile
    property alias leftHanded: prefs.leftHanded
    property alias mouseNaturalScroll: prefs.mouseNaturalScroll
    property alias mouseScrollFactor: prefs.mouseScrollFactor
    property alias hideCursorOnKey: prefs.hideCursorOnKey
    property alias cursorTimeout: prefs.cursorTimeout
    property alias tapToClick: prefs.tapToClick
    property alias tapAndDrag: prefs.tapAndDrag
    property alias dragLock: prefs.dragLock
    property alias padNaturalScroll: prefs.padNaturalScroll
    property alias padScrollFactor: prefs.padScrollFactor
    property alias disableWhileTyping: prefs.disableWhileTyping
    property alias clickfinger: prefs.clickfinger
    property alias tapButtonMap: prefs.tapButtonMap
    property alias middleEmulation: prefs.middleEmulation
    property alias displays: prefs.displays

    // ── typography ────────────────────────────────────────────────────────
    property alias fontScale: prefs.fontScale
    property alias barFontSize: prefs.barFontSize
    property alias barTitleSize: prefs.barTitleSize
    property alias barAppSize: prefs.barAppSize
    property alias barClockSize: prefs.barClockSize
    property alias barBadgeSize: prefs.barBadgeSize
    property alias dockLabelSize: prefs.dockLabelSize
    property alias launcherTitleSize: prefs.launcherTitleSize
    property alias launcherMetaSize: prefs.launcherMetaSize

    property alias launcherWidth: prefs.launcherWidth
    property alias launcherHeight: prefs.launcherHeight
    property alias launcherTileSize: prefs.launcherTileSize
    property alias launcherColumns: prefs.launcherColumns

    property alias menuTranslucency: prefs.menuTranslucency

    property alias gapsIn: prefs.gapsIn
    property alias gapsOut: prefs.gapsOut
    property alias borderSize: prefs.borderSize
    property alias borderFollowsAccent: prefs.borderFollowsAccent
    property alias dnd: prefs.dnd
    property alias badges: prefs.badges
    property alias grouping: prefs.grouping
    property alias popupTimeout: prefs.popupTimeout
    property alias gameMode: prefs.gameMode

    // ── theme resolution ──────────────────────────────────────────────────
    // "auto" follows the clock: dark from 19:00 to 07:00. The mockup calls
    // this "follow sunset"; without a location service this is the honest
    // approximation, and it re-evaluates every minute.
    SystemClock {
        id: themeClock
        precision: SystemClock.Minutes
        enabled: root.theme === "auto"
    }
    readonly property bool autoDark: themeClock.hours >= 19 || themeClock.hours < 7
    readonly property bool dark: theme === "auto" ? autoDark : theme === "dark"

    function setTheme(name) { theme = name; }
    function cycleTheme() { theme = theme === "light" ? "dark" : (theme === "dark" ? "auto" : "light"); }
    function toggleTheme() { theme = dark ? "light" : "dark"; }

    // ── accent ────────────────────────────────────────────────────────────
    readonly property var accentPresets: [
        { light: "#ec3013", dark: "#ff563c" },
        { light: "#ae1800", dark: "#e8452b" },
        { light: "#2d2b2b", dark: "#d7d3d3" },
        { light: "#7c1405", dark: "#c94b39" }
    ]

    readonly property color accent: {
        if (accentIndex === -1) return customAccent;
        const preset = accentPresets[Math.max(0, Math.min(accentPresets.length - 1, accentIndex))];
        return dark ? preset.dark : preset.light;
    }
    // Ink laid *on* the accent — same relative-luminance rule the mockup uses,
    // so a light custom accent flips to dark text instead of going unreadable.
    readonly property color onAccent: {
        const c = accent;
        const lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
        return lum > 0.62 ? "#201e1d" : "#fff8f6";
    }

    // ── neutrals ──────────────────────────────────────────────────────────
    readonly property color ground: dark ? "#201e1d" : "#f3f2f2"
    readonly property color surface: dark ? "#2d2b2b" : "#eae9e9"
    readonly property color ink: dark ? "#f8f4f4" : "#201e1d"
    readonly property color ink2: dark ? "#bab6b6" : "#605d5d"
    readonly property color ink3: dark ? "#8a8686" : "#6b6868"

    readonly property color edge: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.16) : Qt.rgba(0.125, 0.118, 0.114, 0.14)
    readonly property color rule: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.10) : Qt.rgba(0.125, 0.118, 0.114, 0.09)
    readonly property color div: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.22) : Qt.rgba(0.125, 0.118, 0.114, 0.18)

    // Panel and sheet alpha, driven by the Translucency slider. 50% lands on
    // the mockup's own values (0.78 light / 0.72 dark); 0% makes the chrome
    // fully opaque and 100% is as see-through as stays legible.
    //
    // What shows through is the compositor's blur of whatever is behind the
    // surface — hyprland.lua sets a layer_rule per namespace to enable that.
    // With blur off in Hyprland these still read correctly, just flatter.
    readonly property real translucencyFactor: Math.max(0, Math.min(100, translucency)) / 100
    readonly property real panelAlpha: 1.0 - translucencyFactor * (dark ? 0.56 : 0.44)
    readonly property real sheetAlpha: 1.0 - translucencyFactor * (dark ? 0.24 : 0.20)

    readonly property color panel: dark ? Qt.rgba(0.114, 0.106, 0.102, panelAlpha)
                                        : Qt.rgba(0.973, 0.969, 0.969, panelAlpha)
    readonly property color sheet: dark ? Qt.rgba(0.137, 0.129, 0.125, sheetAlpha)
                                        : Qt.rgba(0.980, 0.976, 0.976, sheetAlpha)

    // Fully opaque. A dropdown or popup drawn *inside* a translucent window
    // has nothing blurred behind it — it just shows that window's own
    // content through itself, which is illegible. Menus use this.
    readonly property color solid: dark ? "#1f1d1c" : "#fbfafa"

    // What a dropdown or the colour picker is filled with. Mostly opaque by
    // default: these float over the window's own rows, not over the desktop,
    // so anything showing through is text rather than wallpaper. The control
    // is in Appearance for anyone who wants more of it.
    readonly property real menuAlpha:
        1.0 - Math.max(0, Math.min(60, menuTranslucency)) / 100
    readonly property color menuSurface:
        Qt.rgba(solid.r, solid.g, solid.b, menuAlpha)

    readonly property color hover: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.09) : Qt.rgba(0.125, 0.118, 0.114, 0.07)
    readonly property color sel: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.14) : Qt.rgba(0.125, 0.118, 0.114, 0.10)
    readonly property color gloss: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.6)
    readonly property color seam: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.24 : 0.18)
    readonly property color scrim: dark ? Qt.rgba(0.078, 0.075, 0.071, 0.5) : Qt.rgba(0.125, 0.118, 0.114, 0.24)

    // ── wallpaper tint ramps ──────────────────────────────────────────────
    // The mockup's TINTS table. Wallpaper.qml paints these as one linear
    // base plus two radial washes.
    readonly property var tintSpec: {
        const table = {
            light: {
                Warm:    { a: "#f6f4f3", b: "#e7e3e1", g1: "#ffd9d0", g2: "#dcd8d6" },
                Neutral: { a: "#f5f4f4", b: "#e4e2e2", g1: "#e9e7e6", g2: "" },
                Cool:    { a: "#f2f4f5", b: "#e2e5e7", g1: "#d7dee2", g2: "#dcdcde" }
            },
            dark: {
                Warm:    { a: "#24211f", b: "#161514", g1: "#4a2119", g2: "#2a2827" },
                Neutral: { a: "#221f1e", b: "#151413", g1: "#33302f", g2: "" },
                Cool:    { a: "#1d2022", b: "#131516", g1: "#1e2b33", g2: "#24282a" }
            }
        };
        const set = table[dark ? "dark" : "light"];
        return set[tint] || set.Warm;
    }

    // ── radii — one family scaled by `roundingPct` (0 = square) ───────────
    readonly property real rf: roundingPct / 100
    readonly property real rSm: Math.round(9 * rf)
    readonly property real r: Math.round(14 * rf)
    readonly property real rWin: r
    readonly property real rPanel: r
    readonly property real rTile: r
    readonly property real rCard: r
    readonly property real rPill: r
    readonly property real rDock: r
    readonly property real rCap: r

    // ── typography ────────────────────────────────────────────────────────
    // Inter throughout, as in the mockup; the fallback chain keeps the shell
    // legible if it isn't installed.
    // One multiplier over every text size in the shell, so the whole thing
    // scales without each module carrying its own setting.
    readonly property real fontFactor: Math.max(75, Math.min(150, fontScale)) / 100
    function fs(px) { return Math.round(px * fontFactor); }

    // The bar's own sizes, derived from one setting so they keep the
    // design's relative proportions instead of each needing its own slider.
    // barFontSize is the body size; the focused app's name is four steps
    // larger and the notification badge one smaller, which is the 16/12/11
    // the mockup specifies at the default of 12.
    function barFs(delta) { return fs(Math.max(6, barFontSize + (delta || 0))); }

    // Hyprland wants colours as rgba(rrggbbaa), which is not a form Qt hands
    // out, so it is built by hand.
    function hyprColor(c, alphaByte) {
        const h = x => {
            const v = Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16);
            return v.length < 2 ? "0" + v : v;
        };
        return "rgba(" + h(c.r) + h(c.g) + h(c.b) + (alphaByte || "ff") + ")";
    }

    readonly property string fontFamily: "Inter"
    readonly property string monoFamily: "JetBrains Mono"

    // ── dock geometry ─────────────────────────────────────────────────────
    readonly property bool dockLeft: dockPositionName === "Left"
    readonly property real dockIconSize: Math.round(dockTileSize * dockIconPct / 100)
    readonly property real dockGlyphSize: Math.round(dockIconSize * 0.82)

    readonly property real dockPadH: 7
    readonly property real dockPadV: 5
    readonly property real dockTileSpacing: 3
    readonly property real dockEdgeGap: 16
    readonly property real dockTooltipRoom: 46
    readonly property real dockPanelBreadth: dockTileSize + dockPadV * 2

    // ── shared panel geometry ─────────────────────────────────────────────
    // Dropdowns hang this far below the bar and this far in from the right
    // edge, matching the mockup's top:50px / right:12px.
    readonly property real panelGap: 10
    readonly property real panelEdgeGap: 12
    readonly property real panelTop: barHeight + panelGap
}
