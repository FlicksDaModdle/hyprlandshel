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
// One surface per monitor, of which exactly one is mapped.
//
// This was a single PanelWindow with no `screen`, so the compositor put it
// on one output and there it stayed — there was no second surface for it to
// move onto, which is why it could not be dragged to another display.
// Now every screen has one, `settingsScreen` decides which is live, and
// dragging past an edge hands the window to the neighbour.
Variants {
    model: Quickshell.screens

PanelWindow {
    id: settings
    required property var modelData

    screen: modelData ?? null

    // "" means follow the focused monitor, which is what a freshly opened
    // window should do; once dragged across, it stays where it was put.
    readonly property bool isMine: Config.UiState.settingsScreen === ""
        ? Services.Compositor.isFocusedScreen(modelData)
        : (modelData && modelData.name === Config.UiState.settingsScreen)

    visible: Config.UiState.settingsOpen && isMine
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

            if (x + frame.width > settings.width + 8 && at >= 0 && at < ordered.length - 1) {
                Config.UiState.settingsScreen = ordered[at + 1].name;
                // Re-enter just inside the left edge of the new screen.
                Config.UiState.settingsX = 8;
                Config.UiState.settingsY = y;
                return;
            }
            if (x < -8 && at > 0) {
                Config.UiState.settingsScreen = ordered[at - 1].name;
                Config.UiState.settingsX = Math.max(
                    8, (ordered[at - 1].width || settings.width) - frame.width - 8);
                Config.UiState.settingsY = y;
                return;
            }
        }

        Config.UiState.settingsX = x;
        Config.UiState.settingsY = y;
    }

    readonly property string pane: Config.UiState.settingsPane
    readonly property bool maximised: Config.UiState.settingsMaximized

    readonly property real normalWidth: 900
    readonly property real normalHeight: 596
    // Maximised fills the work area, leaving the bar and dock reachable.
    readonly property real workTop: Config.Appearance.barHeight + 8
    readonly property real workBottom: settings.height - 8
        - (Config.Appearance.dockLeft ? 0 : Config.Appearance.dockPanelBreadth + Config.Appearance.dockEdgeGap)

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

    // ══ the window ═══════════════════════════════════════════════════════
    PanelSurface {
        id: frame
        showSeam: false
        color: Config.Appearance.sheet
        radius: Config.Appearance.rWin

        width: settings.maximised ? settings.width - 16 : settings.normalWidth
        height: settings.maximised
                ? Math.max(320, settings.workBottom - settings.workTop)
                : settings.normalHeight

        // -1 means "not placed yet", so it opens centred.
        x: settings.maximised ? 8
           : (Config.UiState.settingsX >= 0
              ? Math.max(0, Math.min(settings.width - width, Config.UiState.settingsX))
              : Math.round((settings.width - width) / 2))
        y: settings.maximised ? settings.workTop
           : (Config.UiState.settingsY >= 0
              ? Math.max(Config.Appearance.barHeight,
                         Math.min(settings.height - height, Config.UiState.settingsY))
              : Math.round((settings.height - height) / 2))

        Behavior on width  { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        // ── title bar ─────────────────────────────────────────────────────
        Item {
            id: titleBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 40

            // Drag to move, double click to maximise — the mockup's own
            // `cursor: grab` title bar.
            MouseArea {
                anchors.fill: parent
                cursorShape: settings.maximised ? Qt.ArrowCursor : Qt.OpenHandCursor
                property real pressX: 0
                property real pressY: 0

                onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; }
                onPositionChanged: mouse => {
                    if (!pressed || settings.maximised) return;
                    const p = mapToItem(null, mouse.x, mouse.y);
                    settings.moveTo(Math.round(p.x - pressX),
                                    Math.round(p.y - pressY));
                }
                onDoubleClicked: Config.UiState.settingsMaximized = !settings.maximised
            }

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 11

                // Focus bead, accent because this window is the focused one
                // whenever it is up.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 16
                    radius: 2
                    color: Config.Appearance.accent
                }

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "settings"
                    size: 15
                    inkColor: Config.Appearance.ink2
                    accentColor: Config.Appearance.accent
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Settings"
                    font.pixelSize: Config.Appearance.fs(13)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.13
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "quickshell · live"
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Repeater {
                    model: [
                        { glyph: "minus",  danger: false, act: () => Config.UiState.minimiseSettings() },
                        { glyph: "square", danger: false, act: () => Config.UiState.settingsMaximized = !settings.maximised },
                        { glyph: "x",      danger: true,  act: () => Config.UiState.closeSettings() }
                    ]

                    Rectangle {
                        id: winBtn
                        required property var modelData
                        width: 28
                        height: 28
                        radius: Config.Appearance.rSm
                        color: !btnArea.containsMouse ? "transparent"
                             : (modelData.danger ? Config.Appearance.accent : Config.Appearance.hover)

                        MonoIcon {
                            anchors.centerIn: parent
                            name: winBtn.modelData.glyph
                            size: 13
                            inkColor: btnArea.containsMouse && winBtn.modelData.danger
                                      ? Config.Appearance.onAccent : Config.Appearance.ink2
                            monochrome: true
                        }

                        MouseArea {
                            id: btnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: winBtn.modelData.act()
                        }
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Config.Appearance.rule
            }
        }

        // Anything that has to float above the rows lives here: dropdown
        // menus and the colour picker. Inside the window so it moves with it,
        // but outside the pane's Flickable, which clips — a menu opened on a
        // row near the bottom was being cut in half by it, and later rows
        // painted straight over the top of it.
        Item {
            id: popupLayer
            anchors.fill: parent
            z: 900
            // Click-through except where a popup actually is; the popups add
            // their own input handling.
            enabled: children.length > 0

            // A popup positions itself with mapToItem, which is a function
            // call — QML cannot know when its answer changes, so a binding
            // using it evaluates once, before layout has happened, and then
            // never again. That is how they ended up drawn nowhere near
            // their control. Reading these makes those bindings re-evaluate
            // whenever anything that moves a row has moved.
            readonly property real scrollY: paneFlick.contentY
            readonly property string pane: settings.pane

            // What a popup frosts: the pane behind it. It is a sibling of
            // this overlay, not an ancestor, so sampling it is safe.
            readonly property Item backdrop: paneFlick
        }

        // ── sidebar ───────────────────────────────────────────────────────
        Rectangle {
            id: sidebar
            anchors.left: parent.left
            anchors.top: titleBar.bottom
            anchors.bottom: parent.bottom
            width: 212
            color: "transparent"

            Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                color: Config.Appearance.rule
            }

            // Scrollable. With fourteen panes the list is taller than the
            // window at its default height, and a fixed Column would simply
            // clip the last entry with nothing to say so.
            Flickable {
                id: sidebarFlick
                anchors.fill: parent
                anchors.rightMargin: 1
                contentHeight: sidebarColumn.implicitHeight + 16
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                Column {
                    id: sidebarColumn
                    x: 8
                    y: 8
                    width: sidebarFlick.width - 16
                    spacing: 0

                    Repeater {
                        model: settings.paneGroups

                        Column {
                            id: group
                            required property var modelData
                            width: parent.width
                            spacing: 1
                            bottomPadding: 6

                            StyledText {
                                text: group.modelData.label
                                font.pixelSize: Config.Appearance.fs(11)
                                font.weight: Font.DemiBold
                                font.capitalization: Font.AllUppercase
                                font.letterSpacing: 1.2
                                color: Config.Appearance.ink3
                                leftPadding: 10
                                topPadding: 8
                                bottomPadding: 8
                            }

                            Repeater {
                                model: group.modelData.items

                                Item {
                                    id: entry
                                    required property var modelData
                                    readonly property bool active: settings.pane === modelData

                                    width: group.width
                                    height: 34

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Config.Appearance.rSm
                                        color: entry.active ? Config.Appearance.sel
                                             : (entryArea.containsMouse ? Config.Appearance.hover : "transparent")
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                    }

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        anchors.bottomMargin: 3
                                        height: 2
                                        radius: 1
                                        color: Config.Appearance.accent
                                        opacity: entry.active ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 180 } }
                                    }

                                    Row {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: -1
                                        spacing: 10

                                        MonoIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: settings.paneMeta[entry.modelData].icon
                                            size: 15
                                            inkColor: entry.active ? Config.Appearance.accent : Config.Appearance.ink2
                                            monochrome: true
                                        }
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: entry.modelData
                                            font.pixelSize: Config.Appearance.fs(13)
                                        }
                                    }

                                    MouseArea {
                                        id: entryArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Config.UiState.settingsPane = entry.modelData
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── pane ──────────────────────────────────────────────────────────
        Flickable {
            id: paneFlick
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            anchors.bottom: parent.bottom
            contentHeight: paneColumn.implicitHeight + 40
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Vertical only. Otherwise a sideways drag on a slider is read
            // as a flick and the pane takes the grab off the control.
            flickableDirection: Flickable.VerticalFlick

            Column {
                id: paneColumn
                x: 24
                y: 20
                width: parent.width - 48
                spacing: 0

                StyledText {
                    text: settings.pane
                    font.pixelSize: Config.Appearance.fs(17)
                    font.weight: Font.Bold
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: settings.paneMeta[settings.pane].note
                    font.pixelSize: Config.Appearance.fs(13)
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                    topPadding: 4
                    bottomPadding: 12
                }

                Repeater {
                    model: settings.rows
                    SettingsRow {
                        required property var modelData
                        width: paneColumn.width
                        spec: modelData
                        // Popups reparent themselves here so they are neither
                        // clipped by the scrolling pane nor painted over by
                        // the rows that come after them.
                        overlay: popupLayer
                    }
                }
            }
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
              set: () => { if (A.wallpaper !== "") A.wallpaper = ""; else settings.pickWallpaper(); } }
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
                value: settings.modProbe,
                set: v => settings.modProbe = v || "—" });

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
            const m = mons.find(x => x.name === settings.displayPick) || mons[0];
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
                    set: v => settings.displayPickRaw = v });
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
                set: v => settings.applyMode(m.name, v,
                                             settings.nearestRate(byRes[v] || [], rate)) });

            // Labels go out, labels come back — the menu hands back the
            // string it displayed. So the label is looked up in the list it
            // came from rather than parsed: a rate is really 164.836 Hz and a
            // scale really 1.333333, and re-reading "165 Hz" or "133%" would
            // send a value the panel does not have.
            const rateLabels = rateList.map(r => settings.formatHz(r));
            rows.push({ n: "Refresh rate", s: rateList.length > 1
                    ? "Rates available at " + curRes
                    : "Only one rate at this resolution",
                type: rateList.length > 1 ? "menu" : "info",
                options: rateLabels,
                value: settings.formatHz(rate),
                set: v => { const k = rateLabels.indexOf(v);
                            if (k >= 0) settings.applyMode(m.name, curRes, rateList[k]); } });

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
                            if (k >= 0) settings.applyScale(m.name, scales[k]); } });

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
}
