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
            property int workspaceScale: 100          // 60-160 % of the switcher
            // One multiplier over every animation in the shell. 0 turns
            // them off outright rather than making them very fast, since
            // "instant" is what people who turn animations down want.
            property int animSpeed: 100               // 0-250 %
            // Per-output shell scale, as {"eDP-1": 85, "DP-1": 100}. The
            // compositor's own scale makes everything on that output
            // bigger, the shell included; this is how much of that the
            // shell gives back.
            property string screenScales: ""
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

            // key → accelerator, for shortcuts changed from their default.
            // Only overrides are stored, so the defaults can move without
            // stranding anyone on an old value.
            property string keybinds: ""

            // Which modifier the Windows key actually sends. SUPER (Mod4) is
            // the normal answer, but a keyboard remapped in xkb, a Mac
            // layout, or kb_options like altwin:swap_alt_win can put it
            // somewhere else — and then every SUPER bind silently matches
            // nothing. Written into the generated binds in place of SUPER.
            property string modKey: "SUPER"

            // Typography
            property int fontScale: 100               // 75-150 %
            property int barFontSize: 12              // 10-18 px
            property int barTitleSize: 12             // window title beside the app name
            property int barAppSize: 16               // the focused app's name
            property int barMenuSize: 13              // the "Window" menu button
            property int barClockSize: 13             // the clock's time
            property int barBadgeSize: 11             // notification count
            property int dockLabelSize: 12            // dock tooltips and the active label
            property int barIcon: 100                 // 60-180 % of the bar's glyphs
            // "off" | "layer" | "curve" — see MonoIcon.
            property string iconSmoothing: "layer"
            // The launcher grows out of the dock's pill rather than
            // appearing above it.
            property bool launcherMorph: true
            property int launcherTitleSize: 13        // launcher entry names
            property int launcherMetaSize: 11         // launcher categories and hints

            // How glyphs are rasterised.
            //
            // Qt Quick's default is a distance field: one texture per glyph,
            // scaled and rotated freely, and slightly soft at the small
            // sizes a shell is made of. "native" hands rasterising to the
            // platform's font engine, which hints stems onto the pixel grid
            // — noticeably crisper, at the cost of looking wrong under a
            // fractional scale, because it cannot be resampled.
            property bool textNative: true

            // Write the shell's palette into kdeglobals, so Dolphin, Ark and
            // the rest of the KDE applications take their colours from the
            // same theme the shell does. Off by default: it rewrites a file
            // outside this shell's own config.
            property bool themeQtApps: false

            // Generate a Kvantum theme from this one and select it. Kvantum
            // is a Qt style that draws widgets from an SVG, so this changes
            // how KDE applications are *drawn*, not only their colours —
            // which is as close as a file manager gets to the design without
            // being rewritten.
            property bool kvantumTheme: false


            // Subpixel order, written to fontconfig for every app, not just
            // this one: "" leaves your existing setting alone, "none" is
            // grayscale antialiasing, and rgb/bgr/vrgb/vbgr name the stripe
            // order of the panel.
            //
            // Grayscale is the right answer on most OLED panels: their
            // subpixels are not in a straight RGB row (WRGB, or a pentile
            // diamond), so a renderer that assumes one paints colour fringes
            // onto every edge.
            property string subpixel: ""
            property bool fontHinting: true

            // Launcher geometry: one number.
            //
            // Width, height, tile and icon were separately settable, then a
            // layout picker and a size. Both are gone. Everything below is
            // one shape scaled evenly, because every combination that was
            // not that shape looked wrong and none of them was worth a
            // control.
            property int launcherSize: 145            // 70-220 % of the base

            // Optional, on top of the overall size. These stretch the panel
            // in one direction without touching the other or the content:
            // the type and the padding stay put, the room around them grows.
            property int launcherWide: 100             // 100-200 % width
            property int launcherTall: 100             // 100-200 % height
            property int launcherIconScale: 100        // 50-200 % glyph

            // How much of the window shows through a dropdown or the colour
            // picker. 0 is fully opaque.
            // Settings as a floating layer-shell surface (the design's own
            // window, above everything, movable between monitors) or as an
            // ordinary toplevel the compositor tiles like any other app.
            property bool settingsTiled: false

            property int menuTranslucency: 8          // 0-60 %
            property bool menuBlur: true              // frost what's behind a popup

            // Hyprland window frame and behaviour
            property int gapsIn: 4
            property int gapsOut: 8
            property int borderSize: 1
            property bool borderFollowsAccent: true
            property int hyprRounding: 12
            property bool hyprBlur: true
            property int hyprBlurSize: 4
            property int hyprBlurPasses: 2
            property bool hyprShadow: true
            property int hyprAnimSpeed: 100          // 25-300 %
            property bool hyprAnimEnabled: true
            property string hyprLayout: "dwindle"    // dwindle | master
            property int hyprInactiveOpacity: 100    // 40-100 %
            property bool hyprFocusFollowsMouse: true

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
    property alias workspaceScale: prefs.workspaceScale
    property alias animSpeed: prefs.animSpeed
    property alias screenScales: prefs.screenScales
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
    property alias keybinds: prefs.keybinds
    property alias modKey: prefs.modKey

    // ── typography ────────────────────────────────────────────────────────
    property alias fontScale: prefs.fontScale
    property alias barFontSize: prefs.barFontSize
    property alias barTitleSize: prefs.barTitleSize
    property alias barAppSize: prefs.barAppSize
    property alias barMenuSize: prefs.barMenuSize
    property alias barClockSize: prefs.barClockSize
    property alias barBadgeSize: prefs.barBadgeSize
    property alias dockLabelSize: prefs.dockLabelSize
    property alias barIconPct: prefs.barIcon
    property alias iconSmoothing: prefs.iconSmoothing
    property alias launcherMorph: prefs.launcherMorph
    property alias launcherTitleSize: prefs.launcherTitleSize
    property alias launcherMetaSize: prefs.launcherMetaSize

    property alias textNative: prefs.textNative
    property alias themeQtApps: prefs.themeQtApps
    property alias kvantumTheme: prefs.kvantumTheme
    property alias subpixel: prefs.subpixel
    property alias fontHinting: prefs.fontHinting

    property alias launcherSize: prefs.launcherSize
    property alias launcherWide: prefs.launcherWide
    property alias launcherTall: prefs.launcherTall
    property alias launcherIconScale: prefs.launcherIconScale

    // The shape everything is scaled from, at 100%.
    readonly property var launcherBase: ({ w: 620, h: 500, tile: 60, icon: 22,
                                           cols: 4 })

    // Everything the launcher measures itself by, derived. Nothing else in
    // the shell had to change: these are the same property names it always
    // read, they are just no longer settable one at a time.
    function launcherScaled(px) {
        return Math.round(px * Math.max(40, launcherSize) / 100);
    }
    function launcherStretch(n) { return Math.max(50, Math.min(220, n)) / 100; }

    readonly property int launcherWidth:
        Math.round(launcherScaled(launcherBase.w) * launcherStretch(launcherWide))
    readonly property int launcherHeight:
        Math.round(launcherScaled(launcherBase.h) * launcherStretch(launcherTall))
    readonly property int launcherTileSize: launcherScaled(launcherBase.tile)
    readonly property int launcherIconSize:
        Math.round(launcherScaled(launcherBase.icon)
                   * launcherStretch(launcherIconScale))

    // Extra width becomes extra columns rather than extra padding: a wider
    // start menu should hold more apps per row, not the same four with more
    // air between them.
    readonly property int launcherColumns:
        Math.max(3, Math.min(10,
            Math.round(launcherBase.cols * launcherStretch(launcherWide))))

    property alias settingsTiled: prefs.settingsTiled
    property alias menuTranslucency: prefs.menuTranslucency
    property alias menuBlur: prefs.menuBlur

    property alias gapsIn: prefs.gapsIn
    property alias gapsOut: prefs.gapsOut
    property alias borderSize: prefs.borderSize
    property alias borderFollowsAccent: prefs.borderFollowsAccent
    property alias hyprRounding: prefs.hyprRounding
    property alias hyprBlur: prefs.hyprBlur
    property alias hyprBlurSize: prefs.hyprBlurSize
    property alias hyprBlurPasses: prefs.hyprBlurPasses
    property alias hyprShadow: prefs.hyprShadow
    property alias hyprAnimSpeed: prefs.hyprAnimSpeed
    property alias hyprAnimEnabled: prefs.hyprAnimEnabled
    property alias hyprLayout: prefs.hyprLayout
    property alias hyprInactiveOpacity: prefs.hyprInactiveOpacity
    property alias hyprFocusFollowsMouse: prefs.hyprFocusFollowsMouse
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

    // Ink laid *on* the accent, so a light custom accent flips to dark text
    // instead of going unreadable.
    //
    // Named inkOnAccent, not onAccent, and that is not a style choice. A
    // property whose name is `on` followed by a capital and whose
    // initialiser is a brace block is parsed as a signal handler: the block
    // becomes handler code that never runs, and the property keeps its
    // type's default — black, for a colour. It fails silently, with no
    // warning at load and no error at run time, and it had been doing so
    // here for as long as this property has existed: every glyph and label
    // drawn on the accent was black rather than this. The same name with a
    // one-line expression binding works, which is why it is easy to miss.
    // `qmlparse.py` now refuses the shape outright.
    readonly property color inkOnAccent: {
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
    // Never zero, whatever the percentage says: a glyph asked to draw at no
    // size draws nothing at all, and a dock tile with a fill and no icon in
    // it reads as a missing icon rather than as a setting turned down.
    readonly property real dockIconSize:
        Math.max(8, Math.round(dockTileSize * dockIconPct / 100))
    // The utility tiles — overview, settings, show desktop — used to draw at
    // 82% of the app tiles, which is a distinction nobody asked for and read
    // as the corner icons being smaller than the rest. They use dockIconSize
    // now, like everything else in the dock.

    // ── bar glyphs ────────────────────────────────────────────────────────
    // The design's own 16 and 14, scaled by one preference so the bar's
    // icons and the tray's stay in proportion with each other.
    readonly property real barIconSize: Math.max(8, Math.round(16 * barIconPct / 100))
    readonly property real barTrayIconSize: Math.max(8, Math.round(14 * barIconPct / 100))

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

    // ── animation ─────────────────────────────────────────────────────────
    // Every duration in the shell goes through this, so one slider governs
    // the lot and 0% is genuinely instant rather than merely brisk. Qt
    // treats a zero-length NumberAnimation as "jump there", which is what
    // is wanted.
    function anim(ms) {
        if (animSpeed <= 0) return 0;
        return Math.max(1, Math.round(ms * 100 / Math.max(10, animSpeed)));
    }
    // A few places want to know without asking for a number.
    readonly property bool animated: animSpeed > 0

    // ── per-output scale ──────────────────────────────────────────────────
    // A laptop panel run at a compositor scale that makes applications
    // legible makes the shell large to match, because a layer-shell surface
    // is specified in logical pixels and the compositor multiplies them.
    // This is the shell's own correction, per output, so a 150% laptop can
    // carry a 100% bar while the desktop monitor beside it is unchanged.
    readonly property var screenScaleMap: {
        const out = ({});
        for (const line of String(screenScales || "").split("\n")) {
            const m = /^\s*([^=]+?)\s*=\s*(\d+)\s*$/.exec(line);
            if (m) out[m[1]] = Math.max(40, Math.min(200, parseInt(m[2], 10)));
        }
        return out;
    }
    function screenScale(name) {
        const v = screenScaleMap[name || ""];
        return (v === undefined ? 100 : v) / 100;
    }
}
