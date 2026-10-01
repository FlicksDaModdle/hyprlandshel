import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import Quickshell.Services.Pipewire
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The Settings app.
//
// It draws its own title bar rather than taking a toplevel's. As a real
// FloatingWindow it got whatever decoration Qt felt like drawing — on Wayland
// that is a client-side title bar that looks nothing like the mockup and is
// only suppressed by an environment variable set before Qt starts. Owning the
// whole surface is the only way the chrome is reliably the designed one.
//
// The trade for that is it floats above the desktop rather than tiling with
// real windows. Move it by its title bar; the three buttons are the mockup's
// and each does what it says.
//
// Every row acts on the live system and, where it's a shell preference,
// persists to theme.json immediately. There's no Apply button because there's
// nothing to apply: the shell repaints as you drag.
// Two kinds of window, one set of panes.
//
// Floating is the default and what the mockup draws: a layer-shell surface
// with our own title bar, above the desktop, movable between monitors.
//
// Tiled is an ordinary toplevel, so Hyprland treats Settings like any other
// application — it takes a slot in the layout and obeys your window rules
// and binds. The shell already sets QT_WAYLAND_DISABLE_WINDOWDECORATION, so
// Qt draws no title bar of its own and the chrome is still the designed one.
//
// Both mount the same SettingsFrame, and everything below is shared.
Scope {
    id: root

    readonly property bool tiled: Config.Appearance.settingsTiled
    readonly property string pane: Config.UiState.settingsPane

    // Settings → Wallpaper, with a wallpaper per screen: which screen the
    // pictures choose for. Empty is every screen without one of its own.
    property string liveScreenPick: ""

    // Gradient, Topographic, Image or Live, as picked at the top of Settings →
    // Wallpaper. Empty follows what the desktop has; set, it holds a
    // choice not yet made — Image with no image picked, Live with none
    // chosen — so the controls for it stay up while you pick.
    property string wallpaperMode: ""
    readonly property string wallpaperShown: wallpaperMode !== "" ? wallpaperMode
        : Services.LiveWallpaper.enabled ? "live"
        : Config.Appearance.wallpaper !== "" ? "image"
        : Config.Appearance.wallpaperStyle === "topo" ? "topo" : "gradient"

    // The galleries' search and filter. Objects rather than properties of
    // this Scope, so typing into them does not rebuild the rows — which
    // would take the field it is being typed into away.
    QtObject {
        id: liveUi
        property string search: ""
    }

    function setWallpaperMode(v) {
        const A = Config.Appearance, L = Services.LiveWallpaper;
        // What is being switched away from is kept, to come back to.
        if (A.wallpaper !== "") A.wallpaperLast = A.wallpaper;
        if (L.enabled) A.liveLast = A.liveWallpaper;
        if (v === "gradient" || v === "topo") {
            A.wallpaper = "";
            A.wallpaperStyle = v;
            if (L.enabled) L.stop();
            root.wallpaperMode = "";
        } else if (v === "image") {
            if (L.enabled) L.stop();
            if (A.wallpaper === "" && A.wallpaperLast !== "") A.wallpaper = A.wallpaperLast;
            root.wallpaperMode = A.wallpaper === "" ? "image" : "";
        } else {
            if (!L.enabled && A.liveLast !== "" && L.find(A.liveLast)) L.choose(A.liveLast);
            root.wallpaperMode = L.enabled || (A.liveLast !== "" && L.find(A.liveLast)) ? "" : "live";
        }
    }

    // The live wallpaper list is whatever is in its folders now, so it is
    // looked for again each time the pane opens — after saving a video
    // there, say.
    readonly property bool showingWallpaper: Config.UiState.settingsOpen
        && root.pane === "Wallpaper"
    onShowingWallpaperChanged: {
        if (!showingWallpaper) return;
        root.wallpaperMode = "";
        Services.LiveWallpaper.scan();
    }

    readonly property var paneMeta: ({
        "Display":       { icon: "monitor",   group: "System", note: "Every connected display, with its own resolution, refresh rate, scale and colour." },
        "Keyboard":      { icon: "keyboard",  group: "System", note: "Layout, key repeat and the modifier behaviour libinput exposes." },
        "Mouse":         { icon: "mouse",     group: "System", note: "Pointer speed, acceleration profile, buttons and wheel." },
        "Touchpad":      { icon: "touchpad",  group: "System", note: "Tapping, scrolling, palm rejection and click behaviour." },
        "Network":       { icon: "wifi",      group: "System", note: "Wi-Fi networks — joining, university sign-in, saved networks and connection details." },
        "Bluetooth":     { icon: "bluetooth", group: "System", note: "Your devices, and adding new ones." },
        "Sound":         { icon: "volume",    group: "System", note: "Output and input levels and the active device." },
        "Power":         { icon: "battery",   group: "System", note: "Power profile, idle timing and battery care." },
        "Hyprland":      { icon: "grid",      group: "System", note: "The compositor itself — gaps, borders, blur, animations and layout, applied live." },
        "About":         { icon: "cpu",       group: "System", note: "This machine and the shell running on it." },
        "Appearance":    { icon: "palette",   group: "Shell",  note: "Theme, accent, translucency, corners and motion. Every change repaints the shell live." },
        "Wallpaper":     { icon: "image",     group: "Shell",  note: "The desktop's ground — a tint, an image, or a live wallpaper." },
        "Icons":         { icon: "package",   group: "Shell",  note: "Every place an app icon appears, sized in one list." },
        "App theming":   { icon: "sunMoon",   group: "Shell",  note: "Handing this theme to applications that are not part of the shell." },
        "Bar":           { icon: "layout",    group: "Shell",  note: "The top bar: height, clock, tray and the task list." },
        "Dock":          { icon: "dock",      group: "Shell",  note: "The dock: position, size, labels and auto-hide." },
        "Alt+Tab":       { icon: "layoutDashboard", group: "Shell", note: "The window switcher: its shortcut, which windows it offers, and how it looks." },
        "Notifications": { icon: "bell",      group: "Shell",  note: "Banner behaviour, badge counts and how the center stacks items." },
        "Launcher":      { icon: "search",    group: "Shell",  note: "Size of the start menu, its grid, and its text." },
        "Fonts":         { icon: "font",      group: "Shell",  note: "Every typeface the shell uses, and one scale over all of them." },
        "Keybinds":      { icon: "keyboard",  group: "Shell",  note: "Hyprland bindings this shell listens for." }
    })

    // System first, then Shell. The device panes are the ones people open
    // Settings *for*; the shell's own appearance is the thing you set once.
    readonly property var paneGroups: [
        { label: "System", items: ["Display", "Keyboard", "Mouse", "Touchpad",
                                   "Network", "Bluetooth", "Sound", "Power",
                                   "Hyprland", "About"] },
        { label: "Shell",  items: ["Appearance", "Wallpaper", "Icons", "Fonts",
                                   "App theming", "Bar", "Dock", "Alt+Tab", "Launcher",
                                   "Notifications", "Keybinds"] }
    ]


    // ══ floating ═════════════════════════════════════════════════════════
    // One surface per monitor, of which exactly one is mapped.
    //
    // This was a single PanelWindow with no `screen`, so the compositor put
    // it on one output and there it stayed — there was no second surface for
    // it to move onto, which is why it could not be dragged to another
    // display. Now every screen has one, `settingsScreen` decides which is
    // live, and dragging past an edge hands the window to the neighbour.
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData

            screen: modelData ?? null

            // "" means follow the focused monitor, which is what a freshly opened
            // window should do; once dragged across, it stays where it was put.
            readonly property bool isMine: Config.UiState.settingsScreen === ""
                ? Services.Compositor.isFocusedScreen(modelData)
                : (modelData && modelData.name === Config.UiState.settingsScreen)

            visible: Config.UiState.settingsOpen && isMine && !root.tiled
            color: "transparent"
            exclusiveZone: 0

            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true

            WlrLayershell.namespace: "quickshell:panel"
            WlrLayershell.layer: WlrLayer.Top
            // Needs real keyboard focus: the sliders have type-in numeric fields.
            WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            // Only the window itself takes input; the rest of the desktop stays live.
            mask: Region { item: frame }

            // The host contract SettingsFrame reads.
            readonly property bool tiled: false

            // Dragging past a screen edge hands the window to the monitor next door.
            //
            // Each surface only covers its own output, so x is always screen-local:
            // crossing the boundary means switching which surface is mapped and
            // re-entering from the opposite side, not letting x run past the width.
            function moveTo(x, y) {
                const mons = Services.Compositor.monitors || [];
                const here = modelData ? modelData.name : "";

                if (mons.length > 1 && frame) {
                    // Ordered left to right by their real position in the layout.
                    const ordered = mons.slice().sort((a, b) => a.x - b.x);
                    const at = ordered.findIndex(m => m.name === here);

                    if (x + frame.width > win.width + 8 && at >= 0 && at < ordered.length - 1) {
                        Config.UiState.settingsScreen = ordered[at + 1].name;
                        // Re-enter just inside the left edge of the new screen.
                        Config.UiState.settingsX = 8;
                        Config.UiState.settingsY = y;
                        return;
                    }
                    if (x < -8 && at > 0) {
                        Config.UiState.settingsScreen = ordered[at - 1].name;
                        Config.UiState.settingsX = Math.max(
                            8, (ordered[at - 1].width || win.width) - frame.width - 8);
                        Config.UiState.settingsY = y;
                        return;
                    }
                }

                Config.UiState.settingsX = x;
                Config.UiState.settingsY = y;
            }

            readonly property bool maximised: Config.UiState.settingsMaximized

            readonly property real normalWidth: 900
            readonly property real normalHeight: 596
            // Maximised fills the work area, leaving the bar and dock reachable.
            readonly property real workTop: Config.Appearance.barHeight + 8
            readonly property real workBottom: win.height - 8
                - (Config.Appearance.dockLeft ? 0 : Config.Appearance.dockPanelBreadth + Config.Appearance.dockEdgeGap)


            SettingsFrame {
                id: frame
                host: win
                app: root
            }
        }
    }

    // ══ tiled ════════════════════════════════════════════════════════════
    FloatingWindow {
        id: toplevel

        visible: Config.UiState.settingsOpen && !Config.UiState.locked && root.tiled

        // Closed by the compositor rather than by the X in its own title
        // bar — Super+Q, or a titlebar the compositor draws — the window
        // goes and settingsOpen stays true. Opening Settings again then
        // writes true over true, which changes nothing, and Settings
        // cannot be opened again for the rest of the session. The X
        // button never had this because it clears the flag itself.
        onVisibleChanged: if (!visible && Config.UiState.settingsOpen)
                              Config.UiState.closeSettings()
        title: "Settings"
        color: Config.Appearance.sheet

        implicitWidth: 900
        implicitHeight: 620

        // The host contract SettingsFrame reads. Tiled, the compositor owns
        // the geometry, so the parts about placing a window of our own are
        // constants that nothing acts on.
        readonly property bool tiled: true
        readonly property bool maximised: false
        readonly property real normalWidth: width
        readonly property real normalHeight: height
        readonly property real workTop: 0
        readonly property real workBottom: height
        function moveTo(x, y) {}

        // No anchors.fill: the frame already takes its size and position
        // from the host, and setting both would have QML resolve a conflict
        // it warns about rather than one of them simply winning.
        SettingsFrame {
            host: toplevel
            app: root
        }
    }


    // ══ pane contents ════════════════════════════════════════════════════

    readonly property var keybinds: [
        { n: "Launcher",             k: "super" },
        { n: "Overview",             k: "super Tab" },
        { n: "Control center",       k: "super C" },
        { n: "Notifications",        k: "super N" },
        { n: "Settings",             k: "super ," },
        { n: "Terminal",             k: "super Return" },
        { n: "File manager",         k: "super E" },
        { n: "Close window",         k: "super Q" },
        { n: "Float window",         k: "super V" },
        { n: "Fullscreen",           k: "super F" },
        { n: "Toggle theme",         k: "super shift T" },
        { n: "Lock",                 k: "super L" },
        { n: "Screenshot region",    k: "super shift S" },
        { n: "Reload shell",         k: "super shift R" },
        { n: "Switch workspace",     k: "super 1 – 0" },
        { n: "Move window there",    k: "super shift 1 – 0" }
    ]

    readonly property var rows: {
        const A = Config.Appearance;
        switch (pane) {

        // The shell's own look: colour, surfaces, shape and motion.
        case "Appearance": return [
            { type: "header", n: "Colour",
              s: "Light or dark, and the one colour everything picks up" },
            { n: "Theme", s: "Light, dark, or follow the clock after sunset", type: "seg",
              options: [{ label: "Light", value: "light" }, { label: "Dark", value: "dark" }, { label: "Auto", value: "auto" }],
              value: A.theme, set: v => A.theme = v },
            { n: "Accent", s: A.accentIndex === -1
                ? "Custom · " + String(A.customAccent).toUpperCase()
                : "Pick a preset, or cycle the custom swatch", type: "swatch" },
        ].concat(root.cursorRows()).concat([
            { type: "header", n: "Surfaces",
              s: "The bar, the dock, panels and menus" },
            { n: "Translucency", s: "How much of the desktop shows through the bar, dock and panels",
              type: "slider", min: 0, max: 100, unit: "%",
              value: A.translucency, set: v => A.translucency = v },
            { n: "Frosted menus", s: "Blur what's behind a dropdown or the colour "
                 + "picker. They sit inside a window rather than on the desktop, so "
                 + "what gets blurred is the rows underneath them.",
              type: "toggle", value: A.menuBlur, set: v => A.menuBlur = v },
            { n: "Menu translucency", s: "How much shows through — with frosting on, "
                 + "this is how strong the frost reads",
              type: "slider", min: 0, max: 60, unit: "%",
              value: A.menuTranslucency, set: v => A.menuTranslucency = v },
            { type: "header", n: "Shape",
              s: "How round everything is" },
            { n: "Corner rounding", s: "Scales every radius — the shell, its apps, the browser and "
                 + "the window corners. 0% is fully square", type: "slider",
              min: 0, max: 160, unit: "%", value: A.roundingPct, set: v => A.roundingPct = v },
        ]).concat(root.cornerRows()).concat([

            { type: "header", n: "Motion",
              s: "One control over every animation the shell draws" },
            { n: "Animation speed",
              s: "Scales every duration in the shell — panels, the dock, "
                 + "the start menu, toggles, the lot. 0% is genuinely "
                 + "instant rather than merely fast, which is what turning "
                 + "animations down is usually for.",
              type: "slider", min: 0, max: 250, unit: "%",
              value: A.animSpeed, set: v => A.animSpeed = v },

            { type: "header", n: "This window",
              s: "How Settings itself is put on screen" },
            { n: "Window mode",
              s: "Floating is the design's own window: it sits above the "
                 + "desktop with the title bar you see here, and you can drag "
                 + "it between monitors. Tiled makes it an ordinary "
                 + "application window, so Hyprland gives it a slot in the "
                 + "layout and your window binds work on it.",
              type: "seg",
              options: [{ label: "Floating", value: "floating" },
                        { label: "Tiled",    value: "tiled" }],
              value: A.settingsTiled ? "tiled" : "floating",
              set: v => A.settingsTiled = (v === "tiled") }
        ]);

        case "Wallpaper": return root.wallpaperRows();


        case "Icons": return [
            { type: "header", n: "Icon sizes",
              s: "Every place an app icon appears, in one list. Each of "
                 + "these is the same setting as the one in that part's own "
                 + "pane, so moving it here moves it there" },
            { n: "Dock icons",
              s: "The glyph inside a dock tile, as a share of the tile. The "
                 + "tile itself is sized under Dock.",
              type: "slider", min: 30, max: 72, unit: "%",
              value: A.dockIconPct, set: v => A.dockIconPct = v },
            { n: "Launcher icons",
              s: "The glyph inside each app tile in the start menu, without "
                 + "changing how many fit on a row.",
              type: "slider", min: 50, max: 200, unit: "%",
              value: A.launcherIconScale, set: v => A.launcherIconScale = v },
            { n: "Bar and tray icons",
              s: "The top bar's own glyphs and the system tray's, together "
                 + "so they stay in proportion. 100% is the design's 16px "
                 + "and 14px.",
              type: "slider", min: 60, max: 180, unit: "%",
              value: A.barIconPct, set: v => A.barIconPct = v },
            { n: "Icon edge smoothing",
              s: "How the shell's glyphs are antialiased. Multisampled is "
                 + "the safe default. Analytic gives the cleanest curves but "
                 + "is a newer code path that drops glyphs entirely on some "
                 + "drivers — a dock tile with nothing on it is what that "
                 + "looks like. Off is the raw triangulated edge.",
              type: "seg",
              options: [{ label: "Off",          value: "off" },
                        { label: "Multisampled", value: "layer" },
                        { label: "Analytic",     value: "curve" }],
              value: A.iconSmoothing, set: v => A.iconSmoothing = v },
            { n: "File manager icons",
              s: "Set inside the file manager itself — Ctrl + and Ctrl - in "
                 + "its window, or Ctrl 0 to go back to normal. It is a "
                 + "separate application and keeps its own settings.",
              type: "info", value: "Ctrl +  /  Ctrl -" },
        ];

        case "App theming": return [
            { type: "header", n: "Other applications",
              s: "Colours the shell can hand to things that are not part of "
                 + "it" },
            { n: "Theme KDE applications",
              s: "Writes this theme's palette into kdeglobals, so Dolphin, "
                 + "Ark and Okular use the same charcoal and the same accent "
                 + "on selection. Colours only — it cannot change their "
                 + "layout, icons or rounded corners. Your other kdeglobals "
                 + "settings are kept.",
              type: "toggle", value: A.themeQtApps,
              set: v => { A.themeQtApps = v; if (v) Services.Theming.applyKde(); } },

            { n: "Kvantum widget theme",
              s: "Generates a Kvantum theme from this one and selects it. "
                 + "Kvantum draws Qt widgets from an SVG, so this changes how "
                 + "KDE applications are drawn — flat surfaces, hairline "
                 + "borders, the shell's radii and accent — not only their "
                 + "colours. Needs the kvantum package; applications pick it "
                 + "up when they next start.",
              type: "toggle", value: A.kvantumTheme,
              set: v => { A.kvantumTheme = v;
                          if (v) Services.Kvantum.apply();
                          // Either way: turning it on selects Kvantum as the
                          // widget style, turning it off deselects it again.
                          Services.Theming.applyKde(); } },
            { n: "Theme written to", s: "Regenerated whenever the theme changes",
              type: "info", value: "Kvantum/Hyprshell/" }
        ];

        case "Bar": return [
            { n: "Workspace switcher size",
              s: "The pills on the left of the bar, on their own. They are "
                 + "the widest thing there and usually the first to feel "
                 + "oversized.",
              type: "slider", min: 60, max: 160, unit: "%",
              value: A.workspaceScale, set: v => A.workspaceScale = v },
            { n: "Bar height", s: "Top bar thickness", type: "slider",
              min: 32, max: 56, unit: "px", value: A.barHeight, set: v => A.barHeight = v },
            { n: "Auto-hide",
              s: "Slide up off the top edge until the pointer reaches it. "
                 + "A panel opened from the bar holds it out while it is "
                 + "open, and windows get the space back.",
              type: "toggle",
              value: A.barAutoHide, set: v => A.barAutoHide = v },
            { type: "header", n: "Text",
              s: "Body size moves everything together; the rest are offsets from it" },
            { n: "Body text", s: "The window title, the date and the status capsule",
              type: "slider", min: 8, max: 22, unit: "px", value: A.barFontSize,
              set: v => A.barFontSize = v },
            { n: "App name", s: "The focused app's name, beside the workspace pills",
              type: "slider", min: 8, max: 28, unit: "px", value: A.barAppSize,
              set: v => A.barAppSize = v },
            { n: "Window menu", s: "The \u201CWindow\u201D button beside the app name, "
                 + "which opens the window\u2019s own actions",
              type: "slider", min: 8, max: 24, unit: "px", value: A.barMenuSize,
              set: v => A.barMenuSize = v },
            { n: "Window title", s: "The live title after the app name",
              type: "slider", min: 8, max: 22, unit: "px", value: A.barTitleSize,
              set: v => A.barTitleSize = v },
            { n: "Clock", s: "The time; the date follows body text",
              type: "slider", min: 8, max: 24, unit: "px", value: A.barClockSize,
              set: v => A.barClockSize = v },
            { n: "Notification badge", s: "The count on the bell",
              type: "slider", min: 7, max: 16, unit: "px", value: A.barBadgeSize,
              set: v => A.barBadgeSize = v },
            { type: "header", n: "Behaviour", s: "" },
            { n: "Clock format", s: "24-hour, or 12-hour with meridiem", type: "seg",
              options: [{ label: "24 h", value: "24" }, { label: "12 h", value: "12" }],
              value: A.clock24 ? "24" : "12", set: v => A.clock24 = (v === "24") },
            { n: "System tray", s: "Collapsible group of background app icons", type: "toggle",
              value: A.showTray, set: v => A.showTray = v },
            { n: "Tray expanded", s: "Start with the tray group revealed", type: "toggle",
              value: A.trayOpen, set: v => A.trayOpen = v },
            { n: "Task buttons", s: "Window list beside the app name", type: "toggle",
              value: A.showTasks, set: v => A.showTasks = v }
        ];

        case "Alt+Tab": {
            const K = Services.Keybinds;
            const on = A.altTabEnabled;
            const modName = { ALT: "Alt", SUPER: "Super", CTRL: "Ctrl" }[K.altTabMod] || "Alt";
            const clash = on ? K.altTabClash() : "";
            return [
            { n: "Window switcher",
              s: on ? "Hold " + modName + " and tap Tab to walk your windows, most "
                      + "recent first; let go to switch. A quick tap flips "
                      + "straight back to the window you were in before."
                    : "Off — " + modName + " + Tab goes to applications as usual",
              type: "toggle", value: on, set: v => A.altTabEnabled = v },
            { n: "Shortcut",
              s: clash !== ""
                 ? K.altTabAccel(false) + " — this takes the chord from "
                   + clash + ", which stops working until you pick another "
                   + "modifier or rebind it in Keybinds"
                 : (K.altTabMod === "CTRL"
                    ? "Ctrl + Tab, with Shift to go back. Browsers and editors "
                      + "use this chord to switch tabs, and will lose it"
                    : K.altTabAccel(false) + ", with Shift to go back"),
              type: "seg",
              options: [{ label: "Alt", value: "ALT" }, { label: "Super", value: "SUPER" },
                        { label: "Ctrl", value: "CTRL" }],
              value: K.altTabMod, set: v => A.altTabMod = v },
            { n: "Show windows from",
              s: A.altTabScope === "all" ? "Every workspace on every monitor. Picking a "
                   + "window on another workspace takes you there"
                 : A.altTabScope === "monitor" ? "Every workspace on the monitor you are on"
                 : "Only the workspace you are on, like Windows 11's default",
              type: "seg",
              options: [{ label: "This workspace", value: "workspace" },
                        { label: "This monitor", value: "monitor" },
                        { label: "Everywhere", value: "all" }],
              value: A.altTabScope, set: v => A.altTabScope = v },
            { n: "Style",
              s: A.altTabStyle === "icons" ? "Large app icons, and the chosen window's title beneath"
                 : A.altTabStyle === "list" ? "A column of titles — the most windows on screen at once"
                 : "A picture of each window. Only the selected one moves; "
                   + "the rest are caught once when the switcher opens",
              type: "seg",
              options: [{ label: "Thumbnails", value: "thumbnails" },
                        { label: "Icons", value: "icons" },
                        { label: "List", value: "list" }],
              value: A.altTabStyle, set: v => A.altTabStyle = v },
            { n: "Size", s: "Of the pictures, icons or rows", type: "slider",
              min: 60, max: 160, unit: "%", value: A.altTabSize, set: v => A.altTabSize = v },
            { n: "One entry per app",
              s: "Collapse an app's windows into its most recent one, with a "
                 + "count. Off lists every window on its own",
              type: "toggle", value: A.altTabGroup, set: v => A.altTabGroup = v },
            { n: "Scratchpad windows",
              s: "Include windows on a special workspace that is open over "
                 + "the one you are on",
              type: "toggle", value: A.altTabSpecial, set: v => A.altTabSpecial = v },
            { n: "Workspace tags",
              s: "Mark each window with its workspace — shown only when the "
                 + "list spans more than one",
              type: "toggle", value: A.altTabWorkspaceTags,
              set: v => A.altTabWorkspaceTags = v },
            { n: "Switch when",
              s: A.altTabHold
                 ? "You let go of " + modName + ", as on Windows"
                 : "You press Enter or click a window. " + modName
                   + " can be let go of and Tab keeps stepping",
              type: "seg",
              options: [{ label: modName + " is released", value: "hold" },
                        { label: "Enter or a click", value: "sticky" }],
              value: A.altTabHold ? "hold" : "sticky",
              set: v => A.altTabHold = (v === "hold") },
            { n: "Appear after",
              s: A.altTabHold
                 ? "A quick " + modName + "+Tab shorter than this switches "
                   + "without showing anything. Pressing Tab again shows it "
                   + "at once"
                 : "Not used while switching waits for Enter or a click",
              type: A.altTabHold ? "slider" : "info",
              min: 0, max: 400, unit: " ms",
              value: A.altTabDelay, set: v => A.altTabDelay = v },
            { n: "Keys",
              s: "Tab, Shift+Tab or the arrows to move · Enter to switch · "
                 + "Esc to cancel · Delete or middle-click to close a window",
              type: "info", value: "" },
            { n: "Try it",
              s: "Opens the switcher without switching — Esc or a click puts it away",
              type: "action", label: "Show", set: () => Services.Switcher.preview() }
            ];
        }

        case "Dock": return [
            { n: "Position", s: "Bottom slab or left column", type: "seg",
              options: ["Bottom", "Left"], value: A.dockPositionName, set: v => A.dockPositionName = v },
            { n: "Dock size", s: "Tile edge length — sets the dock's thickness", type: "slider",
              min: 34, max: 58, unit: "px", value: A.dockTileSize, set: v => A.dockTileSize = v },
            { n: "Icon size", s: "Glyph scale inside the tile — does not resize the dock", type: "slider",
              min: 30, max: 72, unit: "%", value: A.dockIconPct, set: v => A.dockIconPct = v },
            { n: "Spacing",
              s: "The gap around the dock — the same above it, between it "
                 + "and your windows, as below it, between it and the screen "
                 + "edge. 0 puts it flush against the edge.",
              type: "slider", min: 0, max: 40, unit: " px",
              value: A.dockGapPx, set: v => A.dockGapPx = v },
            { n: "Label for active app", s: "Expand the focused app into a labelled pill", type: "toggle",
              value: A.dockLabels, set: v => A.dockLabels = v },
            { n: "Window previews",
              s: A.dockLeft
                 ? "Only with the dock along the bottom edge — on the left "
                   + "there is no room above a tile for the pictures"
                 : "Hover a running app for a live picture of each of its "
                   + "windows, and click one to go to it",
              type: "toggle",
              value: A.dockPreviews, set: v => A.dockPreviews = v },
            { n: "Show windows from",
              s: A.dockScope === "all"
                 ? "Every workspace. An app running anywhere shows as running "
                   + "here, and clicking it takes you to its window"
                 : "Only the workspace each monitor is showing, like Windows "
                   + "11's desktops. An app whose windows are all elsewhere "
                   + "looks closed here, and clicking it opens one here",
              type: "seg",
              options: [{ label: "This workspace", value: "workspace" },
                        { label: "All workspaces", value: "all" }],
              value: A.dockScope, set: v => A.dockScope = v },
            { n: "Auto-hide", s: "Slide off the screen edge until the pointer reaches it", type: "toggle",
              value: A.dockAutoHide, set: v => A.dockAutoHide = v },
            { n: "Pinned apps",
              s: "Right-click any dock tile to re-point it at a different "
                 + "application, unpin it, or pin one that's only running",
              type: "info",
              value: Config.Apps.pinned.length + " pinned" },
            { n: "Reset pinned apps", s: "Back to the set this shell ships with",
              type: "action", label: "Reset", set: () => Config.Apps.resetPinned() }
        ];

        case "Launcher": return [
            { type: "header", n: "Size",
              s: "One control for the whole panel. Everything — the panel, "
                 + "the tiles, the icons — scales together, so it keeps its "
                 + "proportions instead of being stretched." },
            { n: "Overall size", s: "Everything at once — the panel, the "
                 + "tiles, the icons and the type, in proportion",
              type: "slider", min: 70, max: 220, unit: "%",
              value: A.launcherSize, set: v => A.launcherSize = v },

            { type: "header", n: "Stretch",
              s: "Optional, on top of the size above. These change one "
                 + "dimension and leave the content alone." },
            { n: "Grow out of the dock",
              s: "The start menu opens as the dock's own pill stretching "
                 + "into it, rather than a separate panel appearing above "
                 + "it, and shrinks back into it on the way out. With "
                 + "auto-hide on, the dock slides out first and the menu "
                 + "grows from it.",
              type: "toggle", value: A.launcherMorph,
              set: v => A.launcherMorph = v },
            { n: "Width", s: "Spent on more columns rather than on more space "
                 + "between the same tiles. Below 100% the menu is narrower "
                 + "and holds fewer. While it grows out of the dock it is "
                 + "never wider than the dock itself.",
              type: "slider", min: 50, max: 200, unit: "%",
              value: A.launcherWide, set: v => A.launcherWide = v },
            { n: "Height", s: "Spent on more rows of apps, so the menu is "
                 + "taller because there is more in it rather than because "
                 + "there is more empty panel. Below 100% it shows fewer.",
              type: "slider", min: 50, max: 200, unit: "%",
              value: A.launcherTall, set: v => A.launcherTall = v },
            { n: "Icon size", s: "The glyph inside each tile, without "
                 + "changing the tile",
              type: "slider", min: 50, max: 200, unit: "%",
              value: A.launcherIconScale, set: v => A.launcherIconScale = v },
            { n: "Opens at", s: "What all of the above comes out to",
              type: "info",
              value: A.launcherWidth + " × " + A.launcherHeight + " px, "
                     + A.launcherColumns + " columns, "
                     + Math.max(2, Math.round(3 * A.launcherHeightStretch))
                     + " rows, " + A.launcherIconSize + " px icons" },

            { type: "header", n: "Text", s: "" },
            { n: "Entry names", s: "App and command names in the grid and results",
              type: "slider", min: 8, max: 26, unit: "px", value: A.launcherTitleSize,
              set: v => A.launcherTitleSize = v },
            { n: "Secondary text", s: "Categories, hints and the section headings",
              type: "slider", min: 7, max: 22, unit: "px", value: A.launcherMetaSize,
              set: v => A.launcherMetaSize = v }
        ];

        case "Keybinds": {
            const rows = [];

            rows.push({ type: "header", n: "The modifier key",
                s: "Every shortcut below is written with this in place of SUPER" });
            rows.push({
                n: "Windows key sends",
                s: "SUPER (Mod4) is what a standard PC keyboard sends. If none of "
                   + "your Super shortcuts fire, it is probably not what yours "
                   + "sends — a remapped layout, a Mac keyboard or an "
                   + "altwin: kb_option will put it somewhere else, and then "
                   + "every SUPER bind matches nothing.",
                type: "seg",
                options: [{ label: "Super", value: "SUPER" },
                          { label: "Alt",   value: "ALT" },
                          { label: "Ctrl",  value: "CTRL" },
                          { label: "Hyper", value: "HYPER" }],
                value: A.modKey,
                set: v => { A.modKey = v; Services.Keybinds.write(); } });
            rows.push({
                n: "Test it",
                s: "Press the key you want to use as Super. This reports what the "
                   + "keyboard actually sent, which is the answer to the row above.",
                type: "keybind", probe: true,
                value: root.modProbe,
                set: v => root.modProbe = v || "—" });

            rows.push({
                type: "header", n: "Shell",
                s: "Click a shortcut and press the keys you want. Escape cancels, "
                   + "Backspace restores the default."
            });
            const list = Services.Keybinds.actions;
            for (let i = 0; i < list.length; i++) {
                const a = list[i];
                if (i === 10) rows.push({ type: "header", n: "Applications", s: "" });
                if (i === 13) rows.push({ type: "header", n: "Windows", s: "" });
                rows.push({
                    n: a.n,
                    s: Services.Keybinds.isCustom(a.key)
                       ? "Changed from " + a.def : "Default",
                    type: "keybind",
                    value: Services.Keybinds.displayAccel(a.key),
                    set: v => Services.Keybinds.setAccel(a.key, v)
                });
            }
            rows.push({ type: "header", n: "The generated file", s: "" });
            rows.push({
                n: "Where these are written",
                s: "hyprland.lua reads it last, so these replace the defaults "
                   + "without the shell ever rewriting your own config",
                type: "info", value: "hypr/binds.lua" });
            rows.push({ n: "Reset all shortcuts", s: "Back to the defaults this shell ships",
                type: "action", label: "Reset",
                set: () => Services.Keybinds.resetAll() });
            return rows;
        }

        case "Fonts": return [
            { type: "header", n: "Scale",
              s: "One multiplier over every text size in the shell" },
            { n: "Interface scale", s: "Applies to the bar, dock, launcher, "
                 + "panels and this window — 100% is the size the design specifies",
              type: "slider", min: 75, max: 150, unit: "%",
              value: A.fontScale, set: v => A.fontScale = v },

            { type: "header", n: "Typefaces",
              s: "Edit theme.json to change these — the shell reloads them live" },
            { n: "Interface", s: "Everything except the readouts below. The design "
                 + "specifies Inter; without it installed, the system sans is used.",
              type: "info", value: A.fontFamily },
            { n: "Monospaced", s: "Clock digits, the hex field in the colour "
                 + "picker, and the terminal's own config",
              type: "info", value: A.monoFamily },

            { type: "header", n: "Text rendering",
              s: "How glyphs are drawn onto pixels, which is most of what "
                 + "makes text look sharp or soft" },
            { n: "Rasteriser", s: "Sharp hints each stem onto the pixel grid. "
                 + "Smooth is Qt's default and survives fractional scaling, "
                 + "which Sharp does not — on a display at 125% or 150%, "
                 + "Smooth is the better-looking of the two.",
              type: "seg",
              options: [{ label: "Sharp",  value: "sharp" },
                        { label: "Smooth", value: "smooth" }],
              value: A.textNative ? "sharp" : "smooth",
              set: v => A.textNative = (v === "sharp") },
            { n: "Subpixel order", s: "Your panel's stripe order. Grayscale is "
                 + "right for most OLEDs: their subpixels are not in a "
                 + "straight RGB row, so colour antialiasing fringes every "
                 + "edge. Written to fontconfig for every app, and picked up "
                 + "when each one next starts.",
              type: "seg",
              options: [{ label: "Leave alone", value: "" },
                        { label: "Grayscale",   value: "none" },
                        { label: "RGB",         value: "rgb" },
                        { label: "BGR",         value: "bgr" }],
              value: A.subpixel, set: v => A.subpixel = v },
            { n: "Vertical panels", s: "Set the order above for a display whose "
                 + "subpixels stack instead of sitting side by side",
              type: "seg",
              options: [{ label: "Horizontal", value: "" },
                        { label: "VRGB",       value: "vrgb" },
                        { label: "VBGR",       value: "vbgr" }],
              value: (A.subpixel === "vrgb" || A.subpixel === "vbgr") ? A.subpixel : "",
              set: v => { if (v !== "") A.subpixel = v;
                          else if (A.subpixel === "vrgb" || A.subpixel === "vbgr")
                              A.subpixel = "rgb"; } },
            { n: "Hinting", s: "Nudges stems onto whole pixels. Off is truer to "
                 + "the typeface's own shapes and slightly blurrier.",
              type: "toggle", value: A.fontHinting, set: v => A.fontHinting = v },
            { n: "Written to", s: "Delete this file, or set the order back to "
                 + "Leave alone, to hand the decision back to fontconfig",
              type: "info", value: "fontconfig/conf.d/99-hyprshell-text.conf" },

            { type: "header", n: "Sizes in use",
              s: "What each one comes out at with the scale above applied" },
            { n: "Bar labels", s: "Set in Shell → Bar", type: "info",
              value: A.fs(A.barFontSize) + " px" },
            { n: "Settings rows", s: "Row titles in this window", type: "info",
              value: A.fs(13) + " px" },
            { n: "Row descriptions", s: "The smaller grey line under each title",
              type: "info", value: A.fs(12) + " px" },
            { n: "Menus and tooltips", s: "Dock tooltips, dropdown options, context menus",
              type: "info", value: A.fs(12) + " px" }
        ];

        case "Notifications": return [
            { n: "Do not disturb", s: "Silence banners, keep them in the center", type: "toggle",
              value: A.dnd, set: v => A.dnd = v },
            { n: "Badge counts", s: "Numeric badge on the bar bell", type: "toggle",
              value: A.badges, set: v => A.badges = v },
            { n: "Grouping", s: "Stack by source app, or by arrival time", type: "seg",
              options: ["App", "Time"], value: A.grouping, set: v => A.grouping = v },
            { n: "Banner timeout", s: "How long a banner stays up before it retires to the center",
              type: "slider", min: 2, max: 20, unit: "s",
              value: A.popupTimeout, set: v => A.popupTimeout = v },
            { n: "Waiting in the center", s: "Notifications the shell is currently holding",
              type: "info", value: Services.Notifications.count }
        ];

        case "Display": {
            const mons = Services.Compositor.monitors;
            if (!mons || mons.length === 0)
                return [{ n: "No display", s: "Hyprland reported no monitors",
                          type: "info", value: "—" }];

            // One display at a time, chosen by the picker at the top.
            //
            // Stacking every output's settings meant a two-monitor machine
            // scrolled through twenty-odd rows to reach the second one, and
            // it got worse with each display. The picker costs one row and
            // the rest of the pane is only ever about the screen you chose.
            const m = mons.find(x => x.name === root.displayPick) || mons[0];
            const ipc = m.lastIpcObject || ({});
            const pxW = ipc.width || m.width || 0;
            const pxH = ipc.height || m.height || 0;
            const rate = ipc.refreshRate || 0;
            const curRes = pxW + "x" + pxH;
            const scale = m.scale || ipc.scale || 1;

            const rows = [];

            if (mons.length > 1) {
                rows.push({ n: "Display", s: "Which screen these settings apply to",
                    type: "seg",
                    options: mons.map(x => ({
                        label: x.name + (x.focused ? " ·" : ""), value: x.name })),
                    value: m.name,
                    set: v => root.displayPickRaw = v });
            }

            rows.push({ type: "header", n: m.name,
                s: (m.description || "Display")
                   + (m.focused ? "  ·  focused" : "")
                   + "  ·  " + curRes + " at " + Math.round(rate) + " Hz" });

            // availableModes comes through as "2560x1440@165.00Hz" strings.
            // Splitting resolution from refresh rate lets each be its own
            // control, as every other settings panel does it.
            const byRes = ({});
            for (let k = 0; k < (ipc.availableModes || []).length; k++) {
                const parsed = /^(\d+)x(\d+)@([\d.]+)/.exec(ipc.availableModes[k]);
                if (!parsed) continue;
                const res = parsed[1] + "x" + parsed[2];
                if (!byRes[res]) byRes[res] = [];
                const hz = parseFloat(parsed[3]);
                // Deduped on the rounded value: 59.997 and 60.000 are one
                // rate to a person, and two rows both labelled "60 Hz" would
                // make the menu's lookup ambiguous.
                let seen = false;
                for (let q = 0; q < byRes[res].length; q++) {
                    if (Math.round(byRes[res][q]) === Math.round(hz)) { seen = true; break; }
                }
                if (!seen) byRes[res].push(hz);
            }
            const resList = Object.keys(byRes).sort((a, b) => {
                const A2 = a.split("x"), B2 = b.split("x");
                return (B2[0] * B2[1]) - (A2[0] * A2[1]);
            });
            const rateList = (byRes[curRes] || []).slice().sort((a, b) => b - a);

            rows.push({ n: "Resolution", s: resList.length > 1
                    ? resList.length + " modes reported by this output"
                    : "Only one mode reported",
                type: resList.length > 1 ? "menu" : "info",
                options: resList,
                value: curRes,
                set: v => root.applyMode(m.name, v,
                                             root.nearestRate(byRes[v] || [], root.pluggedRate(m.name, rate))) });

            // Labels go out, labels come back — the menu hands back the
            // string it displayed. So the label is looked up in the list it
            // came from rather than parsed: a rate is really 164.836 Hz and a
            // scale really 1.333333, and re-reading "165 Hz" or "133%" would
            // send a value the panel does not have.
            const rateLabels = rateList.map(r => root.formatHz(r));
            // The rate chosen for plugged in, which is what this menu sets;
            // on battery the output may be running another (below).
            const saved = Services.Devices.displayMap()[m.name] || ({});
            const mainRate = root.pluggedRate(m.name, rate);
            const onBatteryRate = Services.Devices.onBattery && saved.batteryRate > 0;
            // Shown as running, unless it is at its battery rate on purpose:
            // a display that fell back to 60 has to read 60 here, or picking
            // the rate it should be at looks like no change at all.
            const offTarget = !onBatteryRate && saved.mode && Math.abs(rate - mainRate) >= 0.5;
            rows.push({ n: "Refresh rate", s: rateList.length <= 1 ? "Only one rate at this resolution"
                    : onBatteryRate ? "Plugged in — on battery now, at " + Math.round(rate) + " Hz"
                    : offTarget ? "Set to " + Math.round(mainRate) + " Hz, running at " + Math.round(rate)
                                  + " Hz — the shell is putting it back"
                    : "Rates available at " + curRes,
                type: rateList.length > 1 ? "menu" : "info",
                options: rateLabels,
                value: root.formatHz(onBatteryRate ? mainRate : rate),
                set: v => { const k = rateLabels.indexOf(v);
                            if (k >= 0) root.applyMode(m.name, curRes, rateList[k]); } });

            // Laptops: the rate unplugged. "Same" keeps the one above on
            // battery too, and the shell holds it there (Devices.enforce) —
            // a panel re-initialised on unplugging, or asusd's bat_command,
            // used to leave it at 60.
            if (rateList.length > 1 && UPower.displayDevice && UPower.displayDevice.isLaptopBattery) {
                const same = "Same as plugged in";
                const fought = Services.Devices.contested[m.name];
                const batLabels = [same].concat(rateLabels);
                rows.push({ n: "On battery",
                    s: fought !== undefined
                       ? m.name + " went back to " + fought + " Hz three times after being set. Either "
                         + "something else sets it — a bat_command in /etc/asusd/asusd.ron, a power "
                         + "tool — or the driver refuses the rate right now, which Hyprland's log "
                         + "says. The shell has stopped retrying; pick the rate again to retry."
                       : saved.batteryRate > 0 ? "Drops to " + Math.round(saved.batteryRate) + " Hz unplugged, to save power"
                       : "Stays at " + Math.round(mainRate) + " Hz unplugged",
                    type: "menu", options: batLabels,
                    value: saved.batteryRate > 0 ? root.formatHz(saved.batteryRate) : same,
                    set: v => { const k = rateLabels.indexOf(v);
                                Services.Devices.setBatteryRate(m.name, k >= 0 ? rateList[k] : 0); } });
            }

            // A menu, not a slider. Hyprland rejects any scale that doesn't
            // divide the mode into whole logical pixels, and says so only in
            // its log — so a slider spends most of its travel on values that
            // quietly don't apply.
            const scales = Services.Compositor.validScales(pxW, pxH);
            const scaleLabels = scales.map(x => Math.round(x * 100) + "%");
            rows.push({ n: "Scale", s: scales.length > 1
                    ? "Whole-pixel scales available at " + curRes
                    : "No fractional scale divides " + curRes + " cleanly",
                type: scales.length > 1 ? "menu" : "info",
                options: scaleLabels,
                value: Math.round(scale * 100) + "%",
                set: v => { const k = scaleLabels.indexOf(v);
                            if (k >= 0) root.applyScale(m.name, scales[k]); } });

            rows.push({ n: "Adaptive sync", s: "VRR while a fullscreen client is focused",
                type: "toggle", value: (ipc.vrr || 0) !== 0,
                set: v => Services.Compositor.setConfig({ misc: { vrr: v ? 2 : 0 } }) });

            // ── colour ────────────────────────────────────────────────
            //
            // Everything below is read out of what the compositor reports
            // for this output rather than assumed. hardwareDetails is the
            // EDID's own claims, currentFormat is the DRM format actually
            // in use, and colorManagementPreset is the preset that
            // actually took — which is not always the one asked for, so
            // both are shown.
            const hw = ipc.hardwareDetails || ({});
            // `saved`, this output's entry, is read above with the refresh rate.

            // Hyprland's supportsWideColor() believes the EDID unless
            // supports_wide_color overrides it, and supportsHDR() needs
            // wide colour *and* HDR metadata. An HDR preset on a panel
            // that fails either silently becomes sRGB, so those options
            // are only offered once one of the two is true.
            const forcedWide = saved.supports_wide_color === 1;
            const forcedHdr = saved.supports_hdr === 1;
            const canWide = hw.bt2020 === true || forcedWide;
            const canHdr = (canWide && hw.hdr === true) || forcedHdr;
            const canEdid = hw.chroma === true;

            const fmt = String(ipc.currentFormat || "");
            const live10 = fmt.indexOf("2101010") >= 0;
            const want10 = saved.bitdepth === 10;
            const livePreset = String(ipc.colorManagementPreset || "srgb");
            const wantPreset = saved.cm !== undefined ? saved.cm : livePreset;

            const claims = [];
            if (hw.bt2020 === true) claims.push("wide gamut");
            if (hw.hdr === true) claims.push("HDR metadata");
            if (hw.chroma === true) claims.push("its own colour primaries");
            rows.push({ type: "header", n: "Colour",
                s: claims.length > 0
                   ? m.name + " advertises " + claims.join(", ")
                     + " in its EDID"
                   : m.name + " advertises neither wide gamut nor HDR in "
                     + "its EDID. The overrides at the bottom are for a "
                     + "panel that undersells itself." });

            rows.push({ n: "Colour depth",
                s: want10 && !live10
                   ? "Asked for 10-bit, running 8-bit — this output offers "
                     + "no 10-bit format, so the request was dropped. "
                     + "Nothing is broken; it simply has nowhere to go."
                   : (live10
                      ? "10-bit, about a billion colours — " + fmt
                      : "8-bit, 16.7 million colours"
                        + (fmt !== "" ? " — " + fmt : "")
                        + ". Switch to 10-bit to try; this line will say "
                        + "if the panel refuses."),
                type: "seg",
                options: [{ label: "8-bit", value: "8" },
                          { label: "10-bit", value: "10" }],
                // Segmented speaks strings both ways, so the value is a
                // string here and a number in the entry — a numeric 10
                // assigned to its string property comes back as "10" and
                // would never match.
                value: want10 ? "10" : "8",
                set: v => Services.Devices.rememberColour(m.name,
                              { bitdepth: v === "10" ? 10 : 8 }) });

            // Hyprland's own preset names. All nine are spelled out, not
            // because all nine are offered, but because a preset can
            // arrive from hyprland.lua and the menu draws its value as the
            // label: an unlisted one shows up as the bare token "dcip3".
            const cmAll = [
                { label: "Standard (sRGB)", value: "srgb" },
                { label: "Automatic", value: "auto" },
                { label: "Wide gamut (BT.2020)", value: "wide" },
                { label: "HDR", value: "hdr" },
                { label: "The display's primaries", value: "edid" },
                { label: "HDR, display's primaries", value: "hdredid" },
                { label: "DCI-P3", value: "dcip3" },
                { label: "Display P3", value: "dp3" },
                { label: "Adobe RGB", value: "adobe" }
            ];

            // What this output can actually hold. An unsupported preset is
            // accepted, logged and then quietly replaced with sRGB, which
            // from the panel looks exactly like the setting not working —
            // so the ones that would be replaced are not offered.
            const cmOffered = v => {
                switch (v) {
                case "srgb": case "auto":  return true;
                case "edid":               return canEdid;
                case "hdr":                return canHdr;
                case "hdredid":            return canHdr && canEdid;
                case "wide":               return canWide;
                // The three gamut presets Hyprland applies without
                // checking anything. They are for matching a display whose
                // primaries you already know, which is not what this pane
                // is for, so they are only ever here to be shown.
                default:                   return false;
                }
            };

            // Whatever is running, or saved, is in the list whether or not
            // this output advertises it. The compositor is already doing
            // it: leaving it out would show a preset the menu cannot map
            // back to a value, and offer no way to return to it once you
            // had picked something else.
            const cmOptions = cmAll.filter(o => cmOffered(o.value)
                                             || o.value === livePreset
                                             || o.value === wantPreset);
            const cmLabels = cmOptions.map(o => o.label);
            const cmLabelFor = v => {
                const hit = cmAll.find(o => o.value === v);
                return hit ? hit.label : v;
            };

            // Automatic is the one preset that is *meant* to come back as
            // something else: Hyprland resolves it to wide or sRGB and
            // reports the answer, so reading the difference as a fallback
            // would accuse it of failing every time it worked.
            const cmResolves = wantPreset === "auto";
            rows.push({ n: "Colour range",
                s: !cmResolves && wantPreset !== livePreset
                   ? "Asked for " + cmLabelFor(wantPreset) + ", running "
                     + cmLabelFor(livePreset) + " — this output can't hold "
                     + "it, so Hyprland fell back."
                   : (cmResolves
                      ? "Wide gamut where the panel is 10-bit and says it "
                        + "can, sRGB otherwise. Currently "
                        + cmLabelFor(livePreset) + "."
                      : "Currently " + cmLabelFor(livePreset)
                        + (canHdr ? "" : canWide
                           ? ". HDR also needs HDR metadata in the EDID."
                           : ". Wide gamut and HDR need a panel that "
                             + "advertises BT.2020.")),
                type: "menu",
                options: cmLabels,
                value: cmLabelFor(wantPreset),
                set: v => { const k = cmLabels.indexOf(v);
                            if (k >= 0) Services.Devices.rememberColour(
                                m.name, { cm: cmOptions[k].value }); } });

            // Only while an HDR preset is actually running. These do
            // nothing outside one, and a slider that does nothing is worse
            // than no slider.
            if (livePreset === "hdr" || livePreset === "hdredid") {
                rows.push({ n: "SDR brightness",
                    s: "How bright ordinary windows are inside the HDR "
                       + "blend. At 100% their white sits at the reference "
                       + "80 nits, which beside HDR highlights reads as "
                       + "grey.",
                    type: "slider", min: 50, max: 300, unit: "%",
                    value: Math.round((ipc.sdrBrightness || 1) * 100),
                    set: v => Services.Devices.rememberColour(m.name,
                                  { sdrbrightness: Math.round(v) / 100 }) });
                rows.push({ n: "SDR saturation",
                    s: "sRGB colours stretched into the wider gamut come "
                       + "out oversaturated. Pull this down if reds and "
                       + "greens have gone lurid.",
                    type: "slider", min: 50, max: 150, unit: "%",
                    value: Math.round((ipc.sdrSaturation || 1) * 100),
                    set: v => Services.Devices.rememberColour(m.name,
                                  { sdrsaturation: Math.round(v) / 100 }) });
            }

            // The escape hatch, and only where it would change anything.
            // A fair number of panels are perfectly capable and say
            // nothing about it in their EDID, which is the one case where
            // overriding the hardware's own answer is the right call.
            if (hw.bt2020 !== true) {
                rows.push({ n: "Force wide gamut",
                    s: "Tell Hyprland this panel can do BT.2020 even "
                       + "though its EDID doesn't say so. Harmless to try: "
                       + "if it can't, colours will look wrong and you "
                       + "turn it back off.",
                    type: "toggle", value: forcedWide,
                    set: v => Services.Devices.rememberColour(m.name,
                                  { supports_wide_color: v ? 1 : 0 }) });
            }
            if (hw.hdr !== true && canWide) {
                rows.push({ n: "Force HDR",
                    s: "Same, for HDR. Needs wide gamut above to be on or "
                       + "advertised, because Hyprland will not consider "
                       + "HDR without it.",
                    type: "toggle", value: forcedHdr,
                    set: v => Services.Devices.rememberColour(m.name,
                                  { supports_hdr: v ? 1 : 0 }) });
            }

            // How much of this output's scale the shell gives back. The
            // compositor's scale enlarges everything on the screen, the
            // shell included; this is the only way to say that the bar on
            // a 150% laptop should not be 150% of a bar.
            rows.push({ n: "Shell size on this display",
                s: "The bar, dock and menus on " + m.name + ", independently "
                   + "of the display scale above. A laptop panel scaled up "
                   + "so applications are legible makes the shell large to "
                   + "match; this gives that back.",
                type: "slider", min: 60, max: 140, unit: "%",
                value: Math.round(A.screenScale(m.name) * 100),
                set: v => root.setScreenScale(m.name, v) });

            if (mons.length > 1) {
                rows.push({ n: "Arrangement",
                    s: "Drag a screen to where it actually is. Released near "
                       + "another it lands flush against it — a one pixel gap "
                       + "between two outputs is a column of desktop the "
                       + "pointer cannot cross.",
                    type: "monitors",
                    monitors: mons.map(x => ({
                        name: x.name, x: x.x, y: x.y,
                        width: (x.lastIpcObject || {}).width || x.width,
                        height: (x.lastIpcObject || {}).height || x.height,
                        scale: x.scale || 1, focused: x.focused })),
                    value: m.name,
                    pick: n => root.displayPickRaw = n,
                    set: (n, px, py) => {
                        Services.Compositor.setMonitorPosition(n, px, py);
                        // Remembered, like the mode and the scale beside
                        // it: a runtime monitor line is gone at the next
                        // login.
                        Services.Devices.rememberDisplayPosition(n, px, py);
                    } });
                rows.push({ n: "Position", s: "Top-left corner in the layout, in logical pixels",
                    type: "info", value: m.x + ", " + m.y });
            }

            rows.push({ type: "header", n: "When you leave it alone",
                s: Services.Idle.available
                   ? "Written to hypridle.conf. Anything you put in that "
                     + "file yourself is left alone."
                   : "Install hypridle to use these" });

            const idleUnit = v => v === 0 ? "Never"
                                : (v === 1 ? "1 minute" : v + " minutes");
            rows.push({ n: "Turn the screen off after",
                s: Services.Idle.screenOffAfter === 0
                   ? "Never — the panel stays on until something else "
                     + "turns it off"
                   : idleUnit(Services.Idle.screenOffAfter)
                     + " of stillness, and back on when you touch anything",
                type: Services.Idle.available ? "slider" : "info",
                min: 0, max: 60, unit: " min",
                value: Services.Idle.screenOffAfter,
                set: v => { Services.Idle.screenOffAfter = v; Services.Idle.save(); } });

            rows.push({ n: "Sleep after",
                s: Services.Idle.suspendAfter === 0
                   ? "Never — this machine will not suspend on its own"
                   : idleUnit(Services.Idle.suspendAfter) + " of stillness",
                type: Services.Idle.available ? "slider" : "info",
                min: 0, max: 180, unit: " min",
                value: Services.Idle.suspendAfter,
                set: v => { Services.Idle.suspendAfter = v; Services.Idle.save(); } });

            rows.push({ n: "Lock after",
                s: Services.Idle.lockAfter === 0 ? "Never locks on its own"
                   : idleUnit(Services.Idle.lockAfter) + " of stillness",
                type: Services.Idle.available ? "slider" : "info",
                min: 0, max: 120, unit: " min",
                value: Services.Idle.lockAfter,
                set: v => { Services.Idle.lockAfter = v; Services.Idle.save(); } });

            rows.push({ type: "header", n: "All displays",
                s: "These apply to every screen" });

            rows.push({ n: "Brightness",
                s: !Services.Brightness.available
                   ? "No backlight on this machine"
                   : (Services.Brightness.lastError !== ""
                      ? "brightnessctl: " + Services.Brightness.lastError
                      : "Backlight on " + Services.Brightness.device),
                type: Services.Brightness.available ? "slider" : "info",
                min: 1, max: 100, unit: "%",
                value: Services.Brightness.percent,
                set: v => Services.Brightness.set(v / 100) });
            rows.push({ n: "Night shift", s: Services.NightLight.available
                    ? "Warm the panel — " + Services.NightLight.temperature + " K"
                    : "Install hyprsunset or wlsunset to enable", type: "toggle",
                value: Services.NightLight.active,
                set: v => Services.NightLight.setActive(v) });
            rows.push({ n: "Colour temperature", s: "Warmth applied while night shift is on",
                type: "slider", min: 2500, max: 6000, unit: "K",
                value: Services.NightLight.temperature,
                set: v => Services.NightLight.setTemperature(v) });
            rows.push({ n: "Forget saved layouts",
                s: "Drops the remembered mode, scale, arrangement and colour "
                   + "settings for every output, so they fall back to what "
                   + "hyprland.lua says at the next reload",
                type: "action", label: "Forget",
                set: () => Services.Devices.forgetDisplays() });
            return rows;
        }

        // ── Network and Bluetooth ─────────────────────────────────────────
        // Each a pane of its own (WifiPanel.qml, BluetoothPanel.qml), and
        // deliberately reading nothing live here: the spec stays the same
        // object, so the pane is never rebuilt under someone typing into it.
        case "Network":
            return [{ type: "panel", panel: "wifi" }];
        case "Bluetooth":
            return [{ type: "panel", panel: "bluetooth" }];

        // ── Sound ─────────────────────────────────────────────────────────
        case "Sound": {
            const au = Services.Audio;
            const rows = [
                { type: "header", n: "Output",
                  s: au.sinkName || "No output device" },
                { n: "Volume", s: au.muted ? "Muted" : "Output level",
                  type: "slider", min: 0, max: 100, unit: "%",
                  value: au.volumePercent,
                  set: v => au.setVolume(v / 100) },
                { n: "Mute output", s: "Silence everything without moving the "
                     + "level", type: "toggle", value: au.muted,
                  set: v => au.setMuted(v) },

                { type: "header", n: "Input",
                  s: au.sourceName || "No input device" },
                { n: "Microphone", s: au.inputMuted ? "Muted" : "Input level",
                  type: "slider", min: 0, max: 100, unit: "%",
                  value: au.inputPercent,
                  set: v => au.setInputVolume(v / 100) },
                { n: "Mute microphone", s: "Applies to everything using the "
                     + "default source", type: "toggle", value: au.inputMuted,
                  set: v => { if (v !== au.inputMuted) au.toggleInputMute(); } }
            ];

            const sinks = au.sinks || [];
            if (sinks.length > 1) {
                rows.push({ type: "header", n: "Devices",
                            s: "Switch what the default output is" });
                for (let i = 0; i < sinks.length; i++) {
                    const n = sinks[i];
                    const isDefault = au.sink === n;
                    rows.push({ n: n.nickname || n.description || n.name,
                                s: isDefault ? "Current output" : "Available",
                                type: "action",
                                label: isDefault ? "In use" : "Use",
                                set: () => au.setDefaultSink(n) });
                }
            }
            return rows;
        }

        // ── Power ─────────────────────────────────────────────────────────
        case "Power": {
            const bat = UPower.displayDevice;
            const hasBattery = !!bat && bat.isLaptopBattery;
            const rows = [
                { type: "header", n: "Profile",
                  s: PowerProfiles.hasPerformanceProfile
                     ? "What the firmware is asked to prioritise"
                     : "power-profiles-daemon is not available, so this "
                       + "machine has one profile" }
            ];

            if (PowerProfiles.hasPerformanceProfile)
                rows.push({ n: "Power profile",
                            s: "Balanced suits most work; Performance costs "
                               + "battery and runs hotter",
                            type: "seg",
                            options: [{ label: "Saver",       value: "saver" },
                                      { label: "Balanced",    value: "balanced" },
                                      { label: "Performance", value: "performance" }],
                            value: root.powerProfileName,
                            set: v => root.setPowerProfile(v) });

            rows.push({ type: "header", n: "Battery",
                        s: hasBattery ? "" : "No battery — this is a desktop" });
            if (hasBattery) {
                rows.push({ n: "Charge",
                            s: bat.state === UPowerDeviceState.Charging
                               ? "Charging"
                               : (bat.state === UPowerDeviceState.FullyCharged
                                  ? "Full" : "On battery"),
                            type: "meter",
                            value: Math.max(0, Math.min(1, bat.percentage)),
                            label: Math.round(bat.percentage * 100) + "%",
                            color: Config.Appearance.accent });
                rows.push({ n: "Health", s: "Capacity against when it was new",
                            type: "info",
                            value: bat.healthSupported
                                   ? Math.round(bat.healthPercentage) + "%" : "—" });
            }

            rows.push({ type: "header", n: "Screen",
                        s: "Backlight and colour temperature" });
            if (Services.Brightness.available)
                rows.push({ n: "Brightness", s: Services.Brightness.device
                                || "The backlight this machine exposes",
                            type: "slider", min: 1, max: 100, unit: "%",
                            value: Services.Brightness.percent,
                            set: v => Services.Brightness.set(v / 100) });
            else
                rows.push({ n: "Brightness", s: "No backlight device was found",
                            type: "info", value: "—" });

            rows.push({ n: "Night light", s: "Warms the screen after dark. "
                           + "Driven by " + Services.NightLight.backend + ".",
                        type: "toggle", value: Services.NightLight.active,
                        set: v => Services.NightLight.setActive(v) });
            rows.push({ n: "Colour temperature",
                        s: "Lower is warmer. Only applies while night light is on.",
                        type: "slider", min: 2500, max: 6000, unit: " K",
                        value: Services.NightLight.temperature,
                        set: v => Services.NightLight.setTemperature(v) });
            return rows;
        }

        // ── Hyprland ──────────────────────────────────────────────────────
        // Every row here is a live `hl.config` call through Devices, which
        // also re-applies them after a compositor reload — so these survive
        // `hyprctl reload` rather than lasting until the next one.
        case "Hyprland": return [
            { type: "header", n: "Layout",
              s: "How new windows are placed. Applied immediately." },
            { n: "Tiling layout", s: "Dwindle splits the focused window; "
                 + "master keeps one large window beside a stack",
              type: "seg",
              options: [{ label: "Dwindle", value: "dwindle" },
                        { label: "Master",  value: "master" }],
              value: A.hyprLayout,
              set: v => { A.hyprLayout = v; Services.Devices.applyFrame(); } },
            { n: "Focus follows mouse", s: "Move the pointer onto a window to "
                 + "focus it, without clicking",
              type: "toggle", value: A.hyprFocusFollowsMouse,
              set: v => { A.hyprFocusFollowsMouse = v; Services.Devices.applyFrame(); } },

            { type: "header", n: "Gaps and borders", s: "" },
            { n: "Inner gap", s: "Between tiled windows", type: "slider",
              min: 0, max: 40, unit: "px", value: A.gapsIn,
              set: v => { A.gapsIn = v; Services.Devices.applyFrame(); } },
            { n: "Outer gap", s: "Between windows and the screen edge",
              type: "slider", min: 0, max: 60, unit: "px", value: A.gapsOut,
              set: v => { A.gapsOut = v; Services.Devices.applyFrame(); } },
            { n: "Border width", s: "0 removes window borders entirely",
              type: "slider", min: 0, max: 8, unit: "px", value: A.borderSize,
              set: v => { A.borderSize = v; Services.Devices.applyFrame(); } },
            { n: "Border follows accent", s: "The focused window's border "
                 + "takes the shell's accent colour",
              type: "toggle", value: A.borderFollowsAccent,
              set: v => { A.borderFollowsAccent = v; Services.Devices.applyFrame(); } },
            // Applied by Services.Devices as soon as the colour it produces
            // changes, so these only store the value. The outline beside
            // each is the border itself, as Hyprland will draw it.
            { n: "Active border brightness",
              s: "The focused window's border as a darker or lighter shade of "
                 + "the accent — 100% is the accent itself"
                 + (A.borderFollowsAccent ? "" : ". Only while Border follows accent is on"),
              type: "slider", min: 20, max: 160, unit: "%", value: A.activeBorderPct,
              preview: v => { const c = A.shade(A.accent, v);
                              return Qt.rgba(c.r, c.g, c.b, 0xee / 255); },
              set: v => A.activeBorderPct = v },
            { n: "Inactive border brightness",
              s: "Every other window's border. Lower is darker, higher is "
                 + "lighter; 100% is the default",
              type: "slider", min: 0, max: 200, unit: "%", value: A.inactiveBorderPct,
              preview: v => { const c = A.shade(A.div, v);
                              return Qt.rgba(c.r, c.g, c.b, 0xaa / 255); },
              set: v => A.inactiveBorderPct = v },
            { n: "Corner radius", s: "Window corners at 100% Corner rounding; that "
                 + "setting under Appearance scales them along with everything else",
              type: "slider", min: 0, max: 24, unit: "px", value: A.hyprRounding,
              set: v => { A.hyprRounding = v; Services.Devices.applyFrame(); } },

            { type: "header", n: "Effects",
              s: "Blur and shadows are the expensive ones on a weak GPU" },
            { n: "Blur behind windows", s: "Applies to anything translucent",
              type: "toggle", value: A.hyprBlur,
              set: v => { A.hyprBlur = v; Services.Devices.applyFrame(); } },
            { n: "Blur size", s: "Radius of each pass", type: "slider",
              min: 1, max: 20, unit: "", value: A.hyprBlurSize,
              set: v => { A.hyprBlurSize = v; Services.Devices.applyFrame(); } },
            { n: "Blur passes", s: "More passes look smoother and cost more",
              type: "slider", min: 1, max: 5, unit: "", value: A.hyprBlurPasses,
              set: v => { A.hyprBlurPasses = v; Services.Devices.applyFrame(); } },
            { n: "Blur behind the shell",
              s: A.shellBlur === "live"
                 ? "Bar, dock and menus blur whatever is behind them, re-blurred on every frame — "
                   + "costly, and what makes menus drop frames on a high refresh rate"
                 : "Bar, dock and menus blur the wallpaper, blurred once and kept — smooth, like "
                   + "Windows 11's Mica",
              type: "seg",
              options: [{ label: "Wallpaper", value: "wallpaper" }, { label: "Live", value: "live" }],
              value: A.shellBlur,
              set: v => { A.shellBlur = v; Services.Devices.applyShellBlur(); } },
            { n: "Window shadows", s: "A drop shadow under floating windows",
              type: "toggle", value: A.hyprShadow,
              set: v => { A.hyprShadow = v; Services.Devices.applyFrame(); } },
            { n: "Inactive opacity", s: "How much unfocused windows fade back. "
                 + "100% leaves them solid.",
              type: "slider", min: 40, max: 100, unit: "%",
              value: A.hyprInactiveOpacity,
              set: v => { A.hyprInactiveOpacity = v; Services.Devices.applyFrame(); } },

            { type: "header", n: "Animations", s: "" },
            { n: "Animations", s: "Off is the fastest the compositor gets",
              type: "toggle", value: A.hyprAnimEnabled,
              set: v => { A.hyprAnimEnabled = v; Services.Devices.applyFrame(); } },
            { n: "Speed", s: "Higher is quicker. 100% is what this shell ships.",
              type: "slider", min: 25, max: 300, unit: "%", value: A.hyprAnimSpeed,
              set: v => { A.hyprAnimSpeed = v; Services.Devices.applyFrame(); } },

            { type: "header", n: "The config file", s: "" },
            { n: "Where these are written",
              s: "Changes here are applied live and saved to theme.json, then "
                 + "re-applied after every compositor reload. hyprland.lua is "
                 + "never rewritten — your own edits to it stay yours.",
              type: "info", value: "hypr/hyprland.lua" },
            { n: "Reload Hyprland", s: "Re-read hyprland.lua, then put these "
                 + "back on top of it",
              type: "action", label: "Reload",
              set: () => Services.Compositor.reloadConfig() }
        ];

        case "Keyboard": return [
            { n: "Layout", s: "xkb layout list, comma-separated — e.g. us,de",
              type: "info", value: Services.SysInfo.keymap || "—" },
            { n: "Repeat rate", s: "Repeats per second while a key is held",
              type: "slider", min: 10, max: 60, unit: "/s", value: A.repeatRate,
              set: v => { A.repeatRate = v;
                          Services.Devices.applyInput(); } },
            { n: "Repeat delay", s: "Milliseconds before a held key starts repeating",
              type: "slider", min: 150, max: 900, unit: "ms", value: A.repeatDelay,
              set: v => { A.repeatDelay = v;
                          Services.Devices.applyInput(); } },
            { n: "Num Lock at start-up", s: "Turn the numeric keypad on when Hyprland starts",
              type: "toggle", value: A.numlock,
              set: v => { A.numlock = v;
                          Services.Devices.applyInput(); } },
            // Segmented deals in strings — its `value` is a string property and
            // its signal carries one — so the numeric option is carried as text
            // and converted here. Sent as a number, or Hyprland gets "1".
            { n: "Focus follows mouse", s: "Whether moving the pointer over a window focuses it",
              type: "seg",
              options: [{ label: "Off", value: "0" }, { label: "Loose", value: "2" },
                        { label: "Full", value: "1" }],
              value: String(A.followMouse),
              set: v => { A.followMouse = parseInt(v, 10);
                          Services.Devices.applyInput(); } },
            { n: "Keymap", s: "What the compositor currently has loaded",
              type: "info", value: Services.SysInfo.keymap || "—" }
        ];

        case "Mouse": return [
            { n: "Pointer speed", s: "For mice, -100 slowest to +100 fastest. The "
                 + "touchpad has its own, under Touchpad",
              type: "slider", min: -100, max: 100, unit: "",
              value: Math.round(A.sensitivity * 100),
              set: v => { A.sensitivity = v / 100;
                          Services.Devices.applyInput(); } },
            { n: "Acceleration", s: "Adaptive speeds up with fast movement; flat is "
                 + "1:1, the choice for games and precise work",
              type: "seg",
              options: [{ label: "Adaptive", value: "adaptive" }, { label: "Flat", value: "flat" }],
              value: A.accelProfile,
              set: v => { A.accelProfile = v;
                          Services.Devices.applyInput(); } },
            { n: "Left-handed", s: "Swap the primary and secondary buttons",
              type: "toggle", value: A.leftHanded,
              set: v => { A.leftHanded = v;
                          Services.Devices.applyInput(); } },
            { n: "Natural scrolling", s: "Content follows the wheel rather than the view",
              type: "toggle", value: A.mouseNaturalScroll,
              set: v => { A.mouseNaturalScroll = v;
                          Services.Devices.applyInput(); } },
            { n: "Scroll speed", s: "Multiplier applied to every wheel step",
              type: "slider", min: 25, max: 300, unit: "%",
              value: Math.round(A.mouseScrollFactor * 100),
              set: v => { A.mouseScrollFactor = v / 100;
                          Services.Devices.applyInput(); } },
            { n: "Pointer hides while typing", s: "Hide the cursor on the next key press",
              type: "toggle", value: A.hideCursorOnKey,
              set: v => { A.hideCursorOnKey = v;
                          Services.Devices.applyInput(); } },
            { n: "Hide when idle", s: "Seconds of stillness before the pointer disappears — 0 never",
              type: "slider", min: 0, max: 30, unit: "s", value: A.cursorTimeout,
              set: v => { A.cursorTimeout = v;
                          Services.Devices.applyInput(); } }
        ];

        case "Touchpad": return [
            // Its own speed and acceleration, apart from the mouse's. They
            // start out following the mouse's values, so nothing changes
            // until one of these is moved.
            { n: "Pointer speed", s: "For the touchpad only, -100 slowest to +100 "
                 + "fastest. The mouse has its own, under Mouse",
              type: "slider", min: -100, max: 100, unit: "",
              value: Math.round(A.padSensitivityNow * 100),
              set: v => { A.padSensitivity = v / 100;
                          Services.Devices.applyTouchpads(); } },
            { n: "Acceleration", s: "Adaptive speeds up with fast movement; flat is 1:1",
              type: "seg",
              options: [{ label: "Adaptive", value: "adaptive" }, { label: "Flat", value: "flat" }],
              value: A.padAccelNow,
              set: v => { A.padAccelProfile = v;
                          Services.Devices.applyTouchpads(); } },
            { n: "Touchpads found",
              s: Services.Devices.touchpads.length > 0
                 ? "These take the two settings above; every other pointer takes the Mouse ones"
                 : "None found by name, so every pointer is using the Mouse speed and "
                   + "acceleration. " + (Services.Devices.pointers.length > 0
                       ? "Pointers seen: " + Services.Devices.pointers.join(", ") : ""),
              type: "info",
              value: Services.Devices.touchpads.length > 0
                     ? Services.Devices.touchpads.join(", ") : "none" },
            { n: "Tap to click", s: "A tap counts as a click without pressing down",
              type: "toggle", value: A.tapToClick,
              set: v => { A.tapToClick = v;
                          Services.Devices.applyInput(); } },
            { n: "Tap and drag", s: "Tap then hold to drag, without a physical click",
              type: "toggle", value: A.tapAndDrag,
              set: v => { A.tapAndDrag = v;
                          Services.Devices.applyInput(); } },
            { n: "Drag lock", s: "Keep dragging through a brief lift of the finger",
              type: "toggle", value: A.dragLock,
              set: v => { A.dragLock = v;
                          Services.Devices.applyInput(); } },
            { n: "Natural scrolling", s: "Content follows finger direction",
              type: "toggle", value: A.padNaturalScroll,
              set: v => { A.padNaturalScroll = v;
                          Services.Devices.applyInput(); } },
            { n: "Scroll speed", s: "Multiplier applied to two-finger scrolling",
              type: "slider", min: 25, max: 300, unit: "%",
              value: Math.round(A.padScrollFactor * 100),
              set: v => { A.padScrollFactor = v / 100;
                          Services.Devices.applyInput(); } },
            { n: "Disable while typing", s: "Ignore the pad briefly after a key press",
              type: "toggle", value: A.disableWhileTyping,
              set: v => { A.disableWhileTyping = v;
                          Services.Devices.applyInput(); } },
            { n: "Right click", s: "Two-finger click, or a press in the bottom-right corner",
              type: "seg",
              options: [{ label: "Two fingers", value: "finger" },
                        { label: "Corner", value: "corner" }],
              value: A.clickfinger ? "finger" : "corner",
              set: v => { A.clickfinger = v === "finger";
                          Services.Devices.applyInput(); } },
            { n: "Tap button map", s: "Which button two- and three-finger taps send",
              type: "seg",
              options: [{ label: "L R M", value: "lrm" }, { label: "L M R", value: "lmr" }],
              value: A.tapButtonMap,
              set: v => { A.tapButtonMap = v;
                          Services.Devices.applyInput(); } },
            { n: "Middle-click emulation", s: "Left and right together counts as a middle click",
              type: "toggle", value: A.middleEmulation,
              set: v => { A.middleEmulation = v;
                          Services.Devices.applyInput(); } }
        ];

        case "About": return [
            { n: "Device", s: Services.SysInfo.distro || "Linux", type: "info",
              value: Services.SysInfo.host || "—" },
            { n: "Processor", s: Services.SysInfo.cpuLabel, type: "info",
              value: Services.SysInfo.cpuModel || "—" },
            { n: "Memory", s: Services.SysInfo.memLabel, type: "meter",
              value: Services.SysInfo.memRatio,
              label: Math.round(Services.SysInfo.memRatio * 100) + "%",
              color: Config.Appearance.ink2 },
            { n: "Storage", s: Services.SysInfo.diskLabel, type: "meter",
              value: Services.SysInfo.diskRatio,
              label: Math.round(Services.SysInfo.diskRatio * 100) + "%",
              color: Config.Appearance.ink2 },
            { n: "Kernel", s: "Running kernel release", type: "info",
              value: Services.SysInfo.kernel || "—" },
            { n: "Compositor", s: "Wayland session", type: "info",
              value: Services.SysInfo.compositorVersion
                     ? "hyprland " + Services.SysInfo.compositorVersion : "hyprland" },
            // Whether the shell can actually talk to Hyprland, and what it
            // sees. If the workspace pills or the window menu look inert,
            // this row says whether anything is getting through at all.
            { n: "Compositor link",
              s: Services.Compositor.ipcReady
                 ? "Quickshell's own Hyprland IPC — live events"
                 : "No IPC; falling back to polling hyprctl",
              type: "info",
              value: Services.Compositor.ipcReady ? "connected" : "degraded" },
            { n: "Workspaces seen", s: "What the bar's pills are drawn from — "
                 + "focused is " + Services.Compositor.focusedId,
              type: "info",
              value: Services.Compositor.workspaces.length
                     + " of " + Services.Compositor.workspaceSlots.length + " slots" },
            { n: "Uptime", s: "Since last boot", type: "info", value: Services.SysInfo.uptimeLabel },
            { n: "Shell config", s: Config.Appearance.configDir + "/theme.json", type: "info",
              value: "theme.json" },
            { n: "Reload shell", s: "Re-read the QML tree without logging out", type: "action",
              label: "Reload", set: () => Services.Session.reloadShell() }
        ];
        }
        return [];
    }

    // The device settings themselves live in theme.json via
    // Config.Appearance, and Services.Devices is what pushes them to
    // Hyprland — at startup as well as on change, since Hyprland forgets
    // everything not in hyprland.lua each time it launches.

    // ── helpers ───────────────────────────────────────────────────────────
    function batteryDetail(bat) {
        if (!bat) return "";
        switch (bat.state) {
        case UPowerDeviceState.Charging:
            return bat.timeToFull > 0
                ? "Charging · " + formatDuration(bat.timeToFull) + " to full" : "Charging";
        case UPowerDeviceState.FullyCharged:
            return "Fully charged";
        case UPowerDeviceState.Discharging:
            return bat.timeToEmpty > 0
                ? "Discharging · about " + formatDuration(bat.timeToEmpty) + " left" : "Discharging";
        default:
            return UPowerDeviceState.toString(bat.state);
        }
    }

    function formatDuration(seconds) {
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        if (h > 0) return h + " h " + m + " m";
        return m + " m";
    }

    // Which display the Display pane is showing. Empty follows the focused
    // monitor, so opening the pane lands on the screen you are looking at.
    // What the "Test it" row last captured, so pressing a key reports the
    // modifier it really produced rather than silently rebinding something.
    property string modProbe: "press a key"

    // PowerProfiles.profile is an enum; the segmented control speaks
    // strings, so the two are mapped here rather than inside the row.
    readonly property string powerProfileName: {
        switch (PowerProfiles.profile) {
        case PowerProfile.PowerSaver:  return "saver";
        case PowerProfile.Performance: return "performance";
        default:                       return "balanced";
        }
    }

    function setPowerProfile(name) {
        if (name === "saver") PowerProfiles.profile = PowerProfile.PowerSaver;
        else if (name === "performance") PowerProfiles.profile = PowerProfile.Performance;
        else PowerProfiles.profile = PowerProfile.Balanced;
    }

    property string displayPickRaw: ""
    readonly property string displayPick: displayPickRaw !== ""
        ? displayPickRaw : Services.Compositor.focusedMonitorName

    // ── display helpers ───────────────────────────────────────────────────
    // hl.monitor takes the output by name, so a change is addressed to one
    // screen and the rest are left alone. `position` is deliberately not
    // sent: passing "auto" would re-run Hyprland's placement and shuffle a
    // multi-monitor layout the user arranged themselves.
    // One line per output in a newline-separated list, so a name with any
    // character in it survives — outputs are called things like
    // "Dell Inc. DELL U2720Q" when Hyprland reports them by description.
    function setScreenScale(name, pct) {
        const A = Config.Appearance;
        const keep = [];
        for (const line of String(A.screenScales || "").split("\n")) {
            const m = /^\s*([^=]+?)\s*=\s*(\d+)\s*$/.exec(line);
            if (m && m[1] !== name) keep.push(m[1] + "=" + m[2]);
        }
        if (pct !== 100) keep.push(name + "=" + Math.round(pct));
        A.screenScales = keep.join("\n");
    }

    // Saved first, then applied from what was saved. The two used to be
    // separate — one table built here and sent, another written to
    // theme.json — and they agreed only as long as the table had three
    // fields in it. Going through the entry means a resolution change
    // carries this output's colour settings with it by construction
    // rather than by remembering to.
    function applyMode(name, res, hz) {
        const m = Services.Compositor.monitors.find(x => x.name === name);
        if (!m) return;
        const rate = hz > 0 ? hz : Math.round((m.lastIpcObject || {}).refreshRate || 60);
        // Remembered, so it comes back after a logout — Hyprland reverts to
        // whatever hyprland.lua says otherwise.
        Services.Devices.rememberDisplay(name, res + "@" + formatHzPlain(rate),
                                         m.scale || 1);
        Services.Devices.applyDisplay(name);
        // And re-read, or the dropdown keeps showing the mode you just
        // changed away from: these controls are drawn from the compositor's
        // own report of the monitor, and nothing else asks it to refresh.
        // Checked, too: a display already on that rule but not at its rate
        // is one Hyprland skips, and Devices then puts it there.
        Services.Devices.checkSoon();
    }

    function applyScale(name, scale) {
        const m = Services.Compositor.monitors.find(x => x.name === name);
        if (!m) return;
        const ipc = m.lastIpcObject || ({});
        const pxW = ipc.width || m.width, pxH = ipc.height || m.height;
        // The saved mode when there is one: on battery the output may be
        // running its battery rate, which is not the one to keep.
        const saved = (Services.Devices.displayMap()[name] || {}).mode;
        Services.Devices.rememberDisplay(
            name, saved || (pxW + "x" + pxH + "@" + formatHzPlain(ipc.refreshRate || 60)), scale);
        Services.Devices.applyDisplay(name);
        Services.Compositor.refreshMonitors();
    }

    // Panels report fractional rates — 59.997 and 164.836 are real numbers a
    // monitor returns — but nobody wants to read "164.80 Hz" in a menu. Shown
    // as a whole number, and sent back at the precision it arrived with, so
    // Hyprland matches the mode the value actually came from.
    // The rate saved for plugged in, or `fallback` when none is: on battery
    // the output may be running at its battery rate instead.
    function pluggedRate(name, fallback) {
        const mode = (Services.Devices.displayMap()[name] || {}).mode;
        return mode ? parseFloat(mode.split("@")[1]) || fallback : fallback;
    }

    function formatHz(hz) { return Math.round(hz) + " Hz"; }
    function formatHzPlain(hz) { return String(Math.round(hz * 1000) / 1000); }

    // Changing resolution should keep the rate you were on if the new mode
    // supports it, and otherwise land on its highest — never silently on its
    // lowest, which is what taking the list head would do.
    function nearestRate(rates, want) {
        if (!rates || rates.length === 0) return want;
        let best = rates[0];
        for (let i = 1; i < rates.length; i++) {
            if (Math.abs(rates[i] - want) < Math.abs(best - want)) best = rates[i];
        }
        return best;
    }

    // No portal file chooser is available to a shell process, so the
    // wallpaper picker hands off to whatever image picker is installed and
    // watches ~/Pictures for the chosen file instead of guessing.
    // Settings → Wallpaper. One choice at the top — Gradient, Image or
    // Live — and under it only what that one needs.
    function wallpaperRows() {
        const A = Config.Appearance, L = Services.LiveWallpaper;
        const mode = root.wallpaperShown;
        const rows = [{ n: "Desktop",
            s: mode === "gradient" ? "The shell's tinted gradient"
               : mode === "topo" ? "A contour map of a made-up terrain"
               : mode === "image" ? "A picture of your own"
               : "A video, played by mpvpaper",
            type: "seg",
            options: [{ label: "Gradient", value: "gradient" }, { label: "Topo", value: "topo" },
                      { label: "Image", value: "image" }, { label: "Live", value: "live" }],
            value: mode, set: v => root.setWallpaperMode(v) }];

        if (mode === "gradient") {
            rows.push({ n: "Tint", s: "Its temperature", type: "seg",
                options: ["Warm", "Neutral", "Cool"], value: A.tint, set: v => A.tint = v });
        } else if (mode === "topo") {
            return rows.concat(root.topoRows());
        } else if (mode === "image") {
            rows.push({ n: "Image",
                s: A.wallpaper !== "" ? A.wallpaper.split("/").pop() : "None picked yet",
                type: "buttons",
                buttons: [{ label: A.wallpaper !== "" ? "Change…" : "Choose…",
                            quiet: A.wallpaper !== "", set: () => root.pickWallpaper() }] });
        } else {
            return rows.concat(root.liveWallpaperRows());
        }
        return rows;
    }

    // Settings → Appearance → Pointer: the accent cursor (services/Cursor.qml).
    // Black rounded corners over the screen's own, for a panel whose
    // corners are square. Pure black so they read as bezel, not as shell.
    function cornerRows() {
        const A = Config.Appearance;
        const rows = [
            { type: "header", n: "Screen corners",
              s: "Round off a display whose corners are square, with black corners "
                 + "that read as part of the bezel" },
            { n: "Round the screen's corners",
              s: "Drawn over everything, fullscreen games and video included, and "
                 + "never in the way of a click",
              type: "toggle", value: A.screenCorners, set: v => A.screenCorners = v }
        ];
        if (!A.screenCorners) return rows;
        return rows.concat([
            { n: "Corner radius", s: "How far the black curve reaches into the screen",
              type: "slider", min: 2, max: 64, unit: "px",
              value: A.screenCornerRadius, set: v => A.screenCornerRadius = v },
            { n: "Displays",
              s: "Built-in is the laptop's own panel; All covers external monitors too",
              type: "seg",
              options: [{ label: "Built-in", value: "builtin" }, { label: "All", value: "all" }],
              value: A.screenCornerScreens, set: v => A.screenCornerScreens = v },
            { n: "Top left", type: "toggle", value: A.screenCornerTL, set: v => A.screenCornerTL = v },
            { n: "Top right", type: "toggle", value: A.screenCornerTR, set: v => A.screenCornerTR = v },
            { n: "Bottom left", type: "toggle", value: A.screenCornerBL, set: v => A.screenCornerBL = v },
            { n: "Bottom right", type: "toggle", value: A.screenCornerBR, set: v => A.screenCornerBR = v }
        ]);
    }

    function cursorRows() {
        const A = Config.Appearance, C = Services.Cursor;
        const rows = [
            { type: "header", n: "Pointer", s: "" },
            { n: "Cursor",
              s: A.cursorTheme === "accent"
                 ? (C.toolMissing ? "Not built: hyprshell-cursors is missing — run shell/install.sh again (it needs qt6-svg)"
                    : C.error !== "" ? "Couldn't build it: " + C.error
                    : C.building ? "Drawing it…"
                    : C.status.indexOf("refused") >= 0 ? C.status
                    : "The shell's own, in the accent colour" + (C.status === "in use" ? " — in use" : ""))
                 : "The system theme: " + A.cursorSystemTheme,
              type: "seg",
              options: [{ label: "Accent", value: "accent" }, { label: "System", value: "system" }],
              value: A.cursorTheme, set: v => A.cursorTheme = v },
            { n: "Size", type: "slider", min: 16, max: 64, unit: "px",
              value: A.cursorSize, set: v => A.cursorSize = v }
        ];
        if (A.cursorTheme === "accent")
            rows.push({ n: "Rebuild", s: "Draw it again and put it in use — if the pointer didn't change",
                        type: "action", label: "Rebuild", set: () => C.build() });
        if (A.cursorTheme === "accent") {
            rows.push({ n: "Style", s: "Light lines on a dark body, or the reverse — drawn like the app icons, "
                     + "with one part in the accent",
                type: "seg",
                options: [{ label: "Auto", value: "auto" }, { label: "Dark", value: "dark" },
                          { label: "Light", value: "light" }],
                value: ["dark", "light"].indexOf(A.cursorFill) >= 0 ? A.cursorFill : "auto",
                set: v => A.cursorFill = v });
        } else {
            rows.push({ n: "System theme", s: "Any cursor theme installed in ~/.local/share/icons or /usr/share/icons",
                type: "text", value: A.cursorSystemTheme, placeholder: "Adwaita", label: "Use",
                set: v => { A.cursorSystemTheme = v.trim() || "Adwaita"; Services.Cursor.restoreSystem(); } });
        }
        return rows;
    }

    // The Topographic part: the terrain, its lines, and its colours. Every
    // change is on the desktop behind the window as it is made.
    function topoRows() {
        const A = Config.Appearance;
        const hex = c => String(c).toUpperCase();
        const rows = [];
        rows.push({ n: "Terrain", s: "Map " + A.topoSeed, type: "buttons",
            buttons: [{ label: "Previous", quiet: true, enabled: A.topoSeed > 1,
                        set: () => A.topoSeed = Math.max(1, A.topoSeed - 1) },
                      { label: "Next", quiet: true, set: () => A.topoSeed = A.topoSeed + 1 }] });
        rows.push({ n: "Size", s: "How big the hills are", type: "slider", min: 25, max: 300, unit: "%",
            value: A.topoScale, set: v => A.topoScale = v });
        rows.push({ n: "Roughness", s: "Smooth hills to broken ground", type: "slider", min: 1, max: 6,
            value: A.topoDetail, set: v => A.topoDetail = v });
        rows.push({ n: "Flow", s: "How much the ridges wander", type: "slider", min: 0, max: 100, unit: "%",
            value: A.topoFlow, set: v => A.topoFlow = v });

        rows.push({ type: "header", n: "Lines", s: "" });
        rows.push({ n: "Contours", s: "Lines from the lowest ground to the highest", type: "slider",
            min: 4, max: 60, value: A.topoLevels, set: v => A.topoLevels = v });
        rows.push({ n: "Width", type: "slider", min: 0.5, max: 4, step: 0.1, unit: "px",
            value: A.topoWidth, set: v => A.topoWidth = v });
        rows.push({ n: "Index lines", s: "Every so many drawn heavier, as on a survey map", type: "seg",
            options: [{ label: "Off", value: "0" }, { label: "4th", value: "4" },
                      { label: "5th", value: "5" }, { label: "10th", value: "10" }],
            value: String(A.topoMajor), set: v => A.topoMajor = parseInt(v, 10) || 0 });
        rows.push({ n: "Colour", type: "seg",
            options: [{ label: "Ink", value: "ink" }, { label: "Accent", value: "accent" },
                      { label: "Custom", value: "custom" }],
            value: A.topoLine, set: v => A.topoLine = v });
        if (A.topoLine === "custom")
            rows.push({ n: "Line colour", s: hex(A.topoLineCustom), type: "color",
                value: A.topoLineCustom, set: c => A.topoLineCustom = c.toString() });
        rows.push({ n: "Strength", type: "slider", min: 5, max: 100, unit: "%",
            value: A.topoStrength, set: v => A.topoStrength = v });

        rows.push({ type: "header", n: "Ground", s: "" });
        rows.push({ n: "Shading", s: A.topoShade === "flat" ? "One wash, top to bottom"
                : A.topoShade === "bands" ? "A step of colour between each pair of lines"
                : "Darker low, lighter high",
            type: "seg",
            options: [{ label: "Flat", value: "flat" }, { label: "Smooth", value: "smooth" },
                      { label: "Bands", value: "bands" }],
            value: A.topoShade, set: v => A.topoShade = v });
        rows.push({ n: "Colours", s: A.topoGround === "theme" ? "The theme's, light or dark with it" : "",
            type: "seg",
            options: [{ label: "Theme", value: "theme" }, { label: "Custom", value: "custom" }],
            value: A.topoGround, set: v => A.topoGround = v });
        if (A.topoGround === "custom") {
            rows.push({ n: "Low ground", s: hex(A.topoLow), type: "color",
                value: A.topoLow, set: c => A.topoLow = c.toString() });
            rows.push({ n: "High ground", s: hex(A.topoHigh), type: "color",
                value: A.topoHigh, set: c => A.topoHigh = c.toString() });
        }

        rows.push({ n: "Drift", s: "The terrain slowly moving — held still behind windows and on battery",
            type: "toggle", value: A.topoDrift, set: v => A.topoDrift = v });
        if (A.topoDrift)
            rows.push({ n: "Speed", type: "slider", min: 5, max: 100, unit: "%",
                value: A.topoSpeed, set: v => A.topoSpeed = v });
        return rows;
    }

    // The Live part of it: what is on, the videos, and how they play.
    function liveWallpaperRows() {
        const A = Config.Appearance, L = Services.LiveWallpaper;
        const rows = [];

        if (!L.installed) {
            rows.push({ n: "mpvpaper",
                s: L.scanning ? "Looking…"
                   : "Not installed — on Arch or CachyOS, paru -S mpvpaper. It plays a video "
                     + "as the wallpaper, with the graphics card's own decoder.",
                type: "action", label: "Look again", set: () => L.scan() });
            return rows;
        }

        const screens = L.screenNames;
        const pickFor = L.layout === "each" && screens.indexOf(root.liveScreenPick) >= 0
                        ? root.liveScreenPick : "";
        const others = L.layout === "each"
            ? screens.filter(n => L.wallpaperFor(n) !== L.chosen).length : 0;

        rows.push({ n: L.enabled ? L.currentTitle : "None on",
            s: !L.enabled ? (L.wallpapers.length ? "Pick one below" : "")
               : L.error !== "" ? "Stopped: " + L.error
               : (L.paused ? "Paused — windows cover it" : L.running ? "Playing" : "Starting")
                 + (others > 0 ? ", with " + others + " more" : ""),
            type: "buttons",
            buttons: L.enabled
                ? [{ label: "Next", quiet: true, enabled: L.wallpapers.length > 1, set: () => L.next() },
                   { label: "Turn off", quiet: true, set: () => L.stop() }]
                : [] });

        // More than one screen: the same video on each, or each its own —
        // and then which screen is being picked for, as buttons rather than
        // a menu, since there are only a few.
        if (screens.length > 1) {
            rows.push({ n: "Screens", type: "seg",
                options: [{ label: "Same", value: "same" }, { label: "Each its own", value: "each" }],
                value: L.layout, set: v => A.liveLayout = v });
            if (L.layout === "each")
                rows.push({ n: "Picking for",
                    s: pickFor === "" ? "Every screen without its own"
                       : L.screenMap[pickFor] ? "Click its video again to share the main one" : "",
                    type: "seg",
                    options: [{ label: "All", value: "" }].concat(screens.map(n => ({ label: n, value: n }))),
                    value: pickFor, set: v => root.liveScreenPick = v });
        }

        if (L.wallpapers.length === 0) {
            rows.push({ n: "No videos yet",
                s: L.scanning ? "Looking…"
                   : "Put some in " + L.folders.map(f => f.replace(L.home, "~")).join(", ")
                     + ", or add a folder below. mp4, webm, mkv, mov and gif all play.",
                type: "action", label: "Look again", set: () => L.scan() });
        } else {
            rows.push({ type: "gallery", n: "", s: "", state: liveUi,
                items: L.wallpapers,
                value: pickFor !== "" ? (L.screenMap[pickFor] || "") : L.enabled ? L.chosen : "",
                pick: dir => {
                    if (pickFor === "") L.choose(dir);
                    else L.chooseFor(pickFor, L.screenMap[pickFor] === dir ? "" : dir);
                } });
            if (!L.hasFfmpeg)
                rows.push({ n: "No thumbnails", s: "Install ffmpeg for a still of each video here",
                    type: "info", value: "" });
        }

        rows.push({ n: "Folders",
            s: L.folders.map(f => f.replace(L.home, "~")).join(", ")
               + (L.files.length ? " and " + L.files.length + (L.files.length === 1 ? " file" : " files") : ""),
            type: "buttons",
            buttons: [{ label: "Add folder…", quiet: true,
                        set: () => root.pickPath(true, "Folder of videos", f => L.addFolder(f)) },
                      { label: "Add video…", quiet: true,
                        set: () => root.pickPath(false, "Video", f => L.addFile(f)) },
                      { label: "Reset", quiet: true,
                        enabled: A.liveFolders !== "" || A.liveFiles !== "",
                        set: () => L.resetSources() }] });

        // ── how it plays ──────────────────────────────────────────────────
        rows.push({ type: "header", n: "Playback", s: "" });
        rows.push({ n: "Scaling", s: "How a video meets a screen of another shape",
            type: "seg",
            options: [{ label: "Fill", value: "fill" }, { label: "Fit", value: "fit" },
                      { label: "Stretch", value: "stretch" }],
            value: A.liveScaling, set: v => A.liveScaling = v });
        rows.push({ n: "Sound", s: "The video's own audio, if it has any",
            type: "toggle", value: A.liveSound, set: v => A.liveSound = v });
        if (A.liveSound)
            rows.push({ n: "Volume", type: "slider", min: 0, max: 100, unit: "%",
                value: A.liveVolume, set: v => A.liveVolume = v });
        rows.push({ n: "Pause behind windows",
            s: "Stops playing while windows cover every screen",
            type: "seg",
            options: [{ label: "Covered", value: "covered" }, { label: "Any window", value: "windows" },
                      { label: "Never", value: "never" }],
            value: A.livePauseCovered, set: v => A.livePauseCovered = v });
        rows.push({ n: "Pause on battery", s: "Holds the frame on screen while unplugged",
            type: "toggle", value: A.livePauseOnBattery, set: v => A.livePauseOnBattery = v });

        const delays = [5, 10, 15, 30, 60, 120, 360, 720, 1440];
        const delayLabel = m => m < 60 ? m + " minutes" : m === 60 ? "1 hour"
                              : m < 1440 ? (m / 60) + " hours" : m === 1440 ? "1 day" : (m / 1440) + " days";
        const delayOpts = delays.indexOf(A.liveDelay) >= 0 ? delays : delays.concat([A.liveDelay]).sort((a, b) => a - b);
        rows.push({ n: "Rotate", s: L.wallpapers.length < 2 ? "Needs two or more videos"
                : "Move on to another video every so often",
            type: "toggle", value: A.liveRotate, set: v => A.liveRotate = v });
        if (A.liveRotate) {
            rows.push({ n: "Every", type: "menu", options: delayOpts.map(delayLabel),
                value: delayLabel(A.liveDelay),
                set: l => { const i = delayOpts.map(delayLabel).indexOf(l); if (i >= 0) A.liveDelay = delayOpts[i]; } });
            rows.push({ n: "Order", type: "seg",
                options: [{ label: "In order", value: "sequential" }, { label: "Shuffled", value: "random" }],
                value: A.liveOrder, set: v => A.liveOrder = v });
        }
        return rows;
    }

    // A file or folder, from zenity or kdialog.
    function pickPath(folder, title, then) {
        pathPick.then = then;
        pathPick.command = ["sh", "-c",
            'if command -v zenity >/dev/null 2>&1; then zenity --file-selection $1 --title="$2"; '
            + 'elif command -v kdialog >/dev/null 2>&1; then '
            + 'if [ -n "$1" ]; then kdialog --getexistingdirectory "$HOME"; '
            + 'else kdialog --getopenfilename "$HOME"; fi; fi',
            "sh", folder ? "--directory" : "", title];
        pathPick.running = true;
    }
    Process {
        id: pathPick
        property var then: null
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.trim();
                if (f !== "" && pathPick.then) pathPick.then(f);
                pathPick.then = null;
            }
        }
    }

    function pickWallpaper() {
        Quickshell.execDetached(["sh", "-c",
            "f=$(zenity --file-selection --title='Choose wallpaper' 2>/dev/null"
            + " || kdialog --getopenfilename \"$HOME/Pictures\" 2>/dev/null); "
            + "[ -n \"$f\" ] && qs -c hyprshell ipc call shell setWallpaper \"$f\""]);
    }
}
