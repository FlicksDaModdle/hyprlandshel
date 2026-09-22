import QtQuick
import Quickshell
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

    readonly property var paneMeta: ({
        "Display":       { icon: "monitor",   group: "System", note: "Every connected display, with its own resolution, refresh rate and scale." },
        "Keyboard":      { icon: "keyboard",  group: "System", note: "Layout, key repeat and the modifier behaviour libinput exposes." },
        "Mouse":         { icon: "mouse",     group: "System", note: "Pointer speed, acceleration profile, buttons and wheel." },
        "Touchpad":      { icon: "touchpad",  group: "System", note: "Tapping, scrolling, palm rejection and click behaviour." },
        "Network":       { icon: "wifi",      group: "System", note: "Wireless and connection policy." },
        "Bluetooth":     { icon: "bluetooth", group: "System", note: "Radio state, paired devices and discovery." },
        "Sound":         { icon: "volume",    group: "System", note: "Output and input levels and the active device." },
        "Power":         { icon: "battery",   group: "System", note: "Power profile, idle timing and battery care." },
        "Hyprland":      { icon: "grid",      group: "System", note: "The compositor itself — gaps, borders, blur, animations and layout, applied live." },
        "About":         { icon: "cpu",       group: "System", note: "This machine and the shell running on it." },
        "Appearance":    { icon: "palette",   group: "Shell",  note: "Theme, accent, translucency and geometry. Every change repaints the shell live." },
        "Bar":           { icon: "layout",    group: "Shell",  note: "The top bar: height, clock, tray and the task list." },
        "Dock":          { icon: "dock",      group: "Shell",  note: "The dock: position, size, labels and auto-hide." },
        "Notifications": { icon: "bell",      group: "Shell",  note: "Banner behaviour, badge counts and how the center stacks items." },
        "Launcher":      { icon: "search",    group: "Shell",  note: "Size of the start menu, its grid, and its text." },
        "Fonts":         { icon: "file",      group: "Shell",  note: "Every typeface the shell uses, and one scale over all of them." },
        "Keybinds":      { icon: "keyboard",  group: "Shell",  note: "Hyprland bindings this shell listens for." }
    })

    // System first, then Shell. The device panes are the ones people open
    // Settings *for*; the shell's own appearance is the thing you set once.
    readonly property var paneGroups: [
        { label: "System", items: ["Display", "Keyboard", "Mouse", "Touchpad",
                                   "Network", "Bluetooth", "Sound", "Power",
                                   "Hyprland", "About"] },
        { label: "Shell",  items: ["Appearance", "Bar", "Dock", "Launcher",
                                   "Notifications", "Fonts", "Keybinds"] }
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

        case "Appearance": return [
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
              set: v => A.settingsTiled = (v === "tiled") },

            { n: "Theme", s: "Light, dark, or follow the clock after sunset", type: "seg",
              options: [{ label: "Light", value: "light" }, { label: "Dark", value: "dark" }, { label: "Auto", value: "auto" }],
              value: A.theme, set: v => A.theme = v },
            { n: "Accent", s: A.accentIndex === -1
                ? "Custom · " + String(A.customAccent).toUpperCase()
                : "Pick a preset, or cycle the custom swatch", type: "swatch" },
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
            { n: "Corner rounding", s: "Scales every radius — 0% is fully square", type: "slider",
              min: 0, max: 160, unit: "%", value: A.roundingPct, set: v => A.roundingPct = v },
            { n: "Wallpaper tint", s: "Ground gradient temperature", type: "seg",
              options: ["Warm", "Neutral", "Cool"], value: A.tint, set: v => A.tint = v },
            { n: "Wallpaper image", s: A.wallpaper !== "" ? A.wallpaper : "Using the tinted gradient",
              type: "action", label: A.wallpaper !== "" ? "Clear" : "Choose…",
              set: () => { if (A.wallpaper !== "") A.wallpaper = ""; else root.pickWallpaper(); } }
        ];

        case "Bar": return [
            { n: "Bar height", s: "Top bar thickness", type: "slider",
              min: 32, max: 56, unit: "px", value: A.barHeight, set: v => A.barHeight = v },
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

        case "Dock": return [
            { n: "Position", s: "Bottom slab or left column", type: "seg",
              options: ["Bottom", "Left"], value: A.dockPositionName, set: v => A.dockPositionName = v },
            { n: "Dock size", s: "Tile edge length — sets the dock's thickness", type: "slider",
              min: 34, max: 58, unit: "px", value: A.dockTileSize, set: v => A.dockTileSize = v },
            { n: "Icon size", s: "Glyph scale inside the tile — does not resize the dock", type: "slider",
              min: 30, max: 72, unit: "%", value: A.dockIconPct, set: v => A.dockIconPct = v },
            { n: "Label for active app", s: "Expand the focused app into a labelled pill", type: "toggle",
              value: A.dockLabels, set: v => A.dockLabels = v },
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
            { n: "Wider", s: "Extra width, spent on more columns rather than "
                 + "more space between the same tiles",
              type: "slider", min: 100, max: 200, unit: "%",
              value: A.launcherWide, set: v => A.launcherWide = v },
            { n: "Taller", s: "Extra height. The user row stays at the bottom, "
                 + "so this is room for results, not a gap under them.",
              type: "slider", min: 100, max: 200, unit: "%",
              value: A.launcherTall, set: v => A.launcherTall = v },
            { n: "Icon size", s: "The glyph inside each tile, without "
                 + "changing the tile",
              type: "slider", min: 50, max: 200, unit: "%",
              value: A.launcherIconScale, set: v => A.launcherIconScale = v },
            { n: "Opens at", s: "What all of the above comes out to",
              type: "info",
              value: A.launcherWidth + " × " + A.launcherHeight + " px, "
                     + A.launcherColumns + " columns, "
                     + A.launcherIconSize + " px icons" },

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
                                             root.nearestRate(byRes[v] || [], rate)) });

            // Labels go out, labels come back — the menu hands back the
            // string it displayed. So the label is looked up in the list it
            // came from rather than parsed: a rate is really 164.836 Hz and a
            // scale really 1.333333, and re-reading "165 Hz" or "133%" would
            // send a value the panel does not have.
            const rateLabels = rateList.map(r => root.formatHz(r));
            rows.push({ n: "Refresh rate", s: rateList.length > 1
                    ? "Rates available at " + curRes
                    : "Only one rate at this resolution",
                type: rateList.length > 1 ? "menu" : "info",
                options: rateLabels,
                value: root.formatHz(rate),
                set: v => { const k = rateLabels.indexOf(v);
                            if (k >= 0) root.applyMode(m.name, curRes, rateList[k]); } });

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

            if (mons.length > 1) {
                rows.push({ n: "Position", s: "Top-left corner in the layout, in logical pixels",
                    type: "info", value: m.x + ", " + m.y });
            }

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
                s: "Drops the remembered mode and scale for every output, so they "
                   + "fall back to what hyprland.lua says",
                type: "action", label: "Forget",
                set: () => Services.Devices.forgetDisplays() });
            return rows;
        }

        // ── Network ───────────────────────────────────────────────────────
        case "Network": {
            const net = Services.Network;
            if (!net.available) return [
                { type: "header", n: "Network",
                  s: "NetworkManager is not running, so there is nothing "
                     + "here to set. The shell reads and drives the network "
                     + "through nmcli." },
                { n: "NetworkManager", s: "Expected on the session bus",
                  type: "info", value: "not running" }
            ];

            const rows = [
                { type: "header", n: "Wi-Fi", s: "" },
                { n: "Wireless", s: net.wifiEnabled
                     ? "The radio is on" : "The radio is off — nothing will scan",
                  type: "toggle", value: net.wifiEnabled,
                  set: v => net.setWifiEnabled(v) },
                { n: "Connection", s: net.connected
                     ? (net.security || "open") + " · " + net.signalStrength + "% signal"
                     : "Not connected to anything",
                  type: "info", value: net.connected ? net.ssid : "—" },
                { n: "Address", s: "IPv4 on " + (net.ifname || "this interface"),
                  type: "info", value: net.ipv4 || "—" },
                { n: "Scan", s: net.scanning
                     ? "Looking for networks…"
                     : "Look again for networks in range",
                  type: "action", label: net.scanning ? "Scanning" : "Scan",
                  set: () => net.refresh() }
            ];

            if (net.vpnActive)
                rows.push({ n: "VPN", s: "An active VPN connection",
                            type: "info", value: net.vpnName || "connected" });

            if (net.lastError !== "")
                rows.push({ n: "Last attempt", s: net.lastError,
                            type: "info", value: "failed" });

            rows.push({ type: "header", n: "In range",
                        s: (net.networks || []).length + " network"
                           + ((net.networks || []).length === 1 ? "" : "s")
                           + " found. Click a saved one to join it; a new "
                           + "secured one asks for its password first." });

            const seen = (net.networks || []).slice(0, 12);
            for (let i = 0; i < seen.length; i++) {
                const w = seen[i];
                const joined = net.connected && w.ssid === net.ssid;
                const sec = (w.security || "").trim() || "open";
                const busy = net.busySsid === w.ssid;

                // The row itself says who and how strong; what it *does*
                // depends on whether this network is already known.
                if (joined) {
                    rows.push({ n: w.ssid || "(hidden)",
                                s: sec + " · " + (w.signal || 0) + "% · connected",
                                type: "action", label: "Disconnect",
                                set: () => net.disconnect() });
                } else if (net.needsPassword(w)) {
                    rows.push({ n: w.ssid || "(hidden)",
                                s: sec + " · " + (w.signal || 0) + "%"
                                   + (busy ? " · joining…" : " · needs a password"),
                                type: "text", secret: true,
                                placeholder: "Password",
                                label: busy ? "Joining" : "Join",
                                set: v => net.connect(w.ssid, v) });
                } else {
                    rows.push({ n: w.ssid || "(hidden)",
                                s: sec + " · " + (w.signal || 0) + "%"
                                   + (w.known ? " · saved" : "")
                                   + (busy ? " · joining…" : ""),
                                type: "action",
                                label: busy ? "Joining" : "Join",
                                set: () => net.connect(w.ssid, "") });
                }

                if (w.known && !joined)
                    rows.push({ n: "Forget " + (w.ssid || "this network"),
                                s: "Delete the saved profile, so joining asks "
                                   + "for the password again",
                                type: "action", label: "Forget",
                                set: () => net.forget(w.ssid) });
            }
            if (seen.length === 0)
                rows.push({ n: "Nothing found", s: "Scan again, or the radio is off",
                            type: "info", value: "—" });
            return rows;
        }

        // ── Bluetooth ─────────────────────────────────────────────────────
        case "Bluetooth": {
            const bt = Services.Bluetooth;
            if (!bt.available) return [
                { type: "header", n: "Bluetooth",
                  s: "No adapter is present, or bluetoothd is not running." },
                { n: "Adapter", s: "Expected via bluetoothctl", type: "info",
                  value: "none" }
            ];

            const rows = [
                { type: "header", n: "Adapter",
                  s: bt.controller || "The default controller" },
                { n: "Bluetooth", s: bt.powered
                     ? "The radio is on" : "The radio is off",
                  type: "toggle", value: bt.powered,
                  set: v => bt.setPowered(v) },
                { n: "Discoverable", s: "Let other devices see this machine "
                     + "while the setting is on",
                  type: "toggle", value: bt.discoverable,
                  set: v => bt.setDiscoverable(v) },
                { n: "Scan", s: bt.discovering
                     ? "Looking for devices…" : "Look for devices to pair",
                  type: "action", label: bt.discovering ? "Scanning" : "Scan",
                  set: () => bt.scan() },

                { type: "header", n: "Devices",
                  s: bt.pairedCount + " known, " + bt.connectedDevices.length
                     + " connected. Pairing also trusts and connects, so a "
                     + "device works from then on without asking again." }
            ];

            if (bt.lastError !== "")
                rows.push({ n: "Last attempt", s: bt.lastError,
                            type: "info", value: "failed" });

            const devs = bt.devices || [];
            for (let i = 0; i < devs.length; i++) {
                const d = devs[i];
                const busy = bt.busyMac === d.mac;
                const state = d.connected ? "Connected"
                            : (d.paired ? "Paired" : "Found by the last scan");
                rows.push({ n: d.name || d.mac,
                            s: state + " · " + d.mac
                               + (d.kind ? " · " + d.kind : ""),
                            type: "action",
                            label: busy ? "Working" : bt.actionFor(d),
                            set: () => bt.toggleDevice(d) });
                if (d.paired)
                    rows.push({ n: "Forget " + (d.name || d.mac),
                                s: "Drop the pairing; it has to be paired "
                                   + "again after this",
                                type: "action", label: "Forget",
                                set: () => bt.removeDevice(d.mac) });
            }
            if (devs.length === 0)
                rows.push({ n: "Nothing found", s: "Scan to find devices nearby",
                            type: "info", value: "—" });
            return rows;
        }

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
            { n: "Corner radius", s: "Window corners, not the shell's own",
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
            { n: "Pointer speed", s: "libinput sensitivity, -1 slowest to +1 fastest",
              type: "slider", min: -100, max: 100, unit: "",
              value: Math.round(A.sensitivity * 100),
              set: v => { A.sensitivity = v / 100;
                          Services.Devices.applyInput(); } },
            { n: "Acceleration", s: "Adaptive speeds up with fast movement; flat is 1:1",
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
    function applyMode(name, res, hz) {
        const m = Services.Compositor.monitors.find(x => x.name === name);
        if (!m) return;
        const rate = hz > 0 ? hz : Math.round((m.lastIpcObject || {}).refreshRate || 60);
        const mode = res + "@" + formatHzPlain(rate);
        const scale = m.scale || 1;
        Services.Compositor.setMonitor({ output: name, mode: mode, scale: scale });
        // Remembered, so it comes back after a logout — Hyprland reverts to
        // whatever hyprland.lua says otherwise.
        Services.Devices.rememberDisplay(name, mode, scale);
        // And re-read, or the dropdown keeps showing the mode you just
        // changed away from: these controls are drawn from the compositor's
        // own report of the monitor, and nothing else asks it to refresh.
        Services.Compositor.refreshMonitors();
    }

    function applyScale(name, scale) {
        const m = Services.Compositor.monitors.find(x => x.name === name);
        if (!m) return;
        const ipc = m.lastIpcObject || ({});
        const pxW = ipc.width || m.width, pxH = ipc.height || m.height;
        const mode = pxW + "x" + pxH + "@" + formatHzPlain(ipc.refreshRate || 60);
        Services.Compositor.setMonitor({ output: name, mode: mode, scale: scale });
        Services.Devices.rememberDisplay(name, mode, scale);
        Services.Compositor.refreshMonitors();
    }

    // Panels report fractional rates — 59.997 and 164.836 are real numbers a
    // monitor returns — but nobody wants to read "164.80 Hz" in a menu. Shown
    // as a whole number, and sent back at the precision it arrived with, so
    // Hyprland matches the mode the value actually came from.
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
    function pickWallpaper() {
        Quickshell.execDetached(["sh", "-c",
            "f=$(zenity --file-selection --title='Choose wallpaper' 2>/dev/null"
            + " || kdialog --getopenfilename \"$HOME/Pictures\" 2>/dev/null); "
            + "[ -n \"$f\" ] && qs -c hyprshell ipc call shell setWallpaper \"$f\""]);
    }
}
