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
PanelWindow {
    id: settings

    visible: Config.UiState.settingsOpen
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
        "About":         { icon: "cpu",       group: "System", note: "This machine and the shell running on it." },
        "Appearance":    { icon: "palette",   group: "Shell",  note: "Theme, accent, translucency and geometry. Every change repaints the shell live." },
        "Bar":           { icon: "layout",    group: "Shell",  note: "The top bar: height, clock, tray and the task list." },
        "Dock":          { icon: "dock",      group: "Shell",  note: "The dock: position, size, labels and auto-hide." },
        "Notifications": { icon: "bell",      group: "Shell",  note: "Banner behaviour, badge counts and how the center stacks items." },
        "Fonts":         { icon: "file",      group: "Shell",  note: "Every typeface the shell uses, and one scale over all of them." },
        "Keybinds":      { icon: "keyboard",  group: "Shell",  note: "Hyprland bindings this shell listens for." }
    })

    // System first, then Shell. The device panes are the ones people open
    // Settings *for*; the shell's own appearance is the thing you set once.
    readonly property var paneGroups: [
        { label: "System", items: ["Display", "Keyboard", "Mouse", "Touchpad",
                                   "Network", "Bluetooth", "Sound", "Power", "About"] },
        { label: "Shell",  items: ["Appearance", "Bar", "Dock", "Notifications",
                                   "Fonts", "Keybinds"] }
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
                    Config.UiState.settingsX = Math.round(p.x - pressX);
                    Config.UiState.settingsY = Math.round(p.y - pressY);
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

                // Keybinds is a reference table rather than a list of controls.
                Column {
                    visible: settings.pane === "Keybinds"
                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: settings.keybinds

                        Item {
                            id: bind
                            required property var modelData
                            width: paneColumn.width
                            height: 42

                            Rectangle {
                                anchors.top: parent.top
                                width: parent.width
                                height: 1
                                color: Config.Appearance.rule
                            }

                            StyledText {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: bind.modelData.n
                                font.pixelSize: Config.Appearance.fs(13)
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: keyLabel.implicitWidth + 20
                                height: 26
                                radius: Config.Appearance.rSm
                                color: Config.Appearance.hover
                                border.width: 1
                                border.color: Config.Appearance.rule

                                StyledText {
                                    id: keyLabel
                                    anchors.centerIn: parent
                                    text: bind.modelData.k
                                    font.pixelSize: Config.Appearance.fs(12)
                                    font.weight: Font.DemiBold
                                    color: Config.Appearance.ink2
                                }
                            }
                        }
                    }
                }

                Repeater {
                    model: settings.pane === "Keybinds" ? [] : settings.rows
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
            { n: "Text size", s: "Sets every label in the bar at once — the focused "
                 + "app's name, the window title, the clock and the status capsule "
                 + "all move together, keeping the design's proportions",
              type: "slider",
              min: 10, max: 18, unit: "px", value: A.barFontSize,
              set: v => A.barFontSize = v },
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
                return [{ n: "No display", s: "Hyprland reported no monitors", type: "info", value: "—" }];

            const rows = [];

            // One block per output rather than only the focused one. Hyprland
            // configures monitors by name, so everything here is addressed to
            // a specific output and a second screen is a first-class thing
            // rather than something you have to focus first to touch.
            for (let i = 0; i < mons.length; i++) {
                const m = mons[i];
                const ipc = m.lastIpcObject || ({});
                const pxW = ipc.width || m.width || 0;
                const pxH = ipc.height || m.height || 0;
                const rate = ipc.refreshRate || 0;
                const curRes = pxW + "x" + pxH;
                const scale = m.scale || ipc.scale || 1;

                // availableModes comes through as "2560x1440@165.00Hz"
                // strings. Splitting resolution from refresh rate lets each
                // be its own control, as every other settings panel does it —
                // picking a resolution shouldn't mean hunting for the row
                // that also has the rate you wanted.
                const byRes = ({});
                for (let k = 0; k < (ipc.availableModes || []).length; k++) {
                    const parsed = /^(\d+)x(\d+)@([\d.]+)/.exec(ipc.availableModes[k]);
                    if (!parsed) continue;
                    const res = parsed[1] + "x" + parsed[2];
                    if (!byRes[res]) byRes[res] = [];
                    const hz = parseFloat(parsed[3]);
                    // Deduped on the rounded value: 59.997 and 60.000 are one
                    // rate to a person, and two rows both labelled "60 Hz"
                    // would make the menu's lookup ambiguous.
                    let seen = false;
                    for (let q = 0; q < byRes[res].length; q++) {
                        if (Math.round(byRes[res][q]) === Math.round(hz)) { seen = true; break; }
                    }
                    if (!seen) byRes[res].push(hz);
                }
                const resList = Object.keys(byRes).sort((a, b) => {
                    const A = a.split("x"), B = b.split("x");
                    return (B[0] * B[1]) - (A[0] * A[1]);
                });
                const rateList = (byRes[curRes] || []).slice().sort((a, b) => b - a);

                rows.push({ type: "header", n: m.name,
                    s: (m.description || "Display") + (m.focused ? "  ·  focused" : "") });

                rows.push({ n: "Resolution", s: resList.length > 1
                        ? resList.length + " modes reported by this output"
                        : "Only one mode reported",
                    type: resList.length > 1 ? "menu" : "info",
                    options: resList,
                    value: curRes,
                    // Keep the closest refresh rate the new resolution can
                    // actually do, instead of silently dropping to its lowest.
                    set: v => settings.applyMode(m.name, v, settings.nearestRate(byRes[v] || [], rate)) });

                // Labels go out, labels come back — the menu hands back the
                // string it displayed. So the label is looked up in the list
                // it came from rather than parsed: a rate is really 164.836 Hz
                // and a scale really 1.333333, and re-reading "165 Hz" or
                // "133%" would send a value the panel does not have and
                // Hyprland quietly refuses.
                const rateLabels = rateList.map(r => settings.formatHz(r));
                rows.push({ n: "Refresh rate", s: rateList.length > 1
                        ? "Rates available at " + curRes
                        : "Only one rate at this resolution",
                    type: rateList.length > 1 ? "menu" : "info",
                    options: rateLabels,
                    value: settings.formatHz(rate),
                    set: v => { const k = rateLabels.indexOf(v);
                                if (k >= 0) settings.applyMode(m.name, curRes, rateList[k]); } });

                // A menu, not a slider. Hyprland rejects any scale that
                // doesn't divide the mode into whole logical pixels, and says
                // so only in its log — so a slider spends most of its travel
                // on values that quietly don't apply. This offers the ones
                // that work on this panel and nothing else.
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
                    set: v => Services.Compositor.setConfig(
                        { misc: { vrr: v ? 2 : 0 } }) });

                if (mons.length > 1) {
                    rows.push({ n: "Position", s: "Top-left corner in the layout, in logical pixels",
                        type: "info", value: m.x + ", " + m.y });
                }
            }

            rows.push({ type: "header", n: "All displays",
                s: Services.Compositor.monitorCount
                   + (Services.Compositor.monitorCount === 1 ? " output" : " outputs")
                   + " · " + mons.map(x => x.name).join(" · ") });

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
            return rows;
        }

        case "Network": return [
            { n: "Wi-Fi", s: Services.Network.connected
                ? Services.Network.ssid + " · " + Services.Network.security
                  + " · " + Services.Network.signalStrength + "%"
                : "Not connected", type: "toggle",
              value: Services.Network.wifiEnabled, set: v => Services.Network.setWifiEnabled(v) },
            { n: "VPN", s: Services.Network.vpnName || "No VPN profile configured", type: "toggle",
              value: Services.Network.vpnActive, set: v => Services.Network.setVpn(v) },
            { n: "Interface", s: "Active wireless device", type: "info",
              value: Services.Network.ifname || "—" },
            { n: "IPv4", s: "Address leased on this connection", type: "info",
              value: Services.Network.ipv4 || "—" },
            { n: "Networks in range", s: "Rescan and pick one from the control center", type: "info",
              value: Services.Network.networks.length },
            { n: "Connection editor", s: "Add a network, or edit a saved profile", type: "action",
              label: "Open", set: () => Services.Network.openEditor() }
        ];

        case "Bluetooth": {
            const rows = [
                { n: "Bluetooth", s: Services.Bluetooth.available
                    ? "Controller " + Services.Bluetooth.controller : "No adapter found",
                  type: "toggle", value: Services.Bluetooth.powered,
                  set: v => Services.Bluetooth.setPowered(v) },
                { n: "Discoverable", s: "Let nearby devices find this machine", type: "toggle",
                  value: Services.Bluetooth.discoverable,
                  set: v => Services.Bluetooth.setDiscoverable(v) }
            ];
            for (const d of Services.Bluetooth.devices) {
                rows.push({ n: d.name, s: d.connected ? "Connected" : "Paired · not connected",
                    type: "toggle", value: d.connected,
                    set: () => Services.Bluetooth.toggleDevice(d) });
            }
            rows.push({ n: "Pair a device", s: "Scan for nearby devices for 15 seconds",
                type: "action", label: Services.Bluetooth.discovering ? "Scanning…" : "Scan",
                set: () => Services.Bluetooth.scan() });
            return rows;
        }

        case "Sound": {
            const rows = [];
            const sinks = Services.Audio.sinks;
            if (sinks.length > 0) rows.push({
                n: "Output device", s: "Route system audio", type: "menu",
                options: sinks.map(s => Services.Audio.displayName(s)),
                value: Services.Audio.sinkName,
                set: v => {
                    const node = sinks.find(s => Services.Audio.displayName(s) === v);
                    if (node) Services.Audio.setDefaultSink(node);
                }
            });
            rows.push({ n: "Output volume", s: Services.Audio.muted ? "Muted" : "Master level",
                type: "slider", min: 0, max: 100, unit: "%",
                value: Services.Audio.volumePercent, set: v => Services.Audio.setVolume(v / 100) });
            rows.push({ n: "Mute output", s: "Silence the default sink", type: "toggle",
                value: Services.Audio.muted, set: v => Services.Audio.setMuted(v) });
            if (Services.Audio.sourceReady) {
                rows.push({ n: "Input volume", s: Services.Audio.sourceName || "Microphone",
                    type: "slider", min: 0, max: 100, unit: "%",
                    value: Services.Audio.inputPercent,
                    set: v => Services.Audio.setInputVolume(v / 100) });
            }
            rows.push({ n: "Graph", s: "PipeWire session", type: "info",
                value: Pipewire.ready ? "ready" : "starting" });
            return rows;
        }

        case "Power": {
            const bat = UPower.displayDevice;
            const hasBat = !!bat && bat.isLaptopBattery && bat.isPresent;
            const rows = [];
            const ppd = PowerProfiles.hasPerformanceProfile;
            rows.push({
                n: "Power profile",
                s: ppd ? "Platform profile via power-profiles-daemon"
                       : "power-profiles-daemon is not running — this has no effect",
                type: "seg",
                options: [{ label: "Saver", value: "saver" },
                          { label: "Balanced", value: "balanced" },
                          { label: "Performance", value: "performance" }],
                value: PowerProfiles.profile === PowerProfile.PowerSaver ? "saver"
                     : (PowerProfiles.profile === PowerProfile.Performance ? "performance" : "balanced"),
                set: v => PowerProfiles.profile = v === "saver" ? PowerProfile.PowerSaver
                        : (v === "performance" ? PowerProfile.Performance : PowerProfile.Balanced)
            });
            rows.push({ n: "Lock before sleep", s: "Lock the screen when suspending", type: "toggle",
                value: Services.Session.lockBeforeSleep,
                set: v => Services.Session.lockBeforeSleep = v });
            if (hasBat) {
                rows.push({ n: "Battery", s: settings.batteryDetail(bat), type: "meter",
                    value: bat.percentage, label: Math.round(bat.percentage * 100) + "%",
                    color: bat.percentage < 0.15 ? Config.Appearance.accent : Config.Appearance.ink2 });
                if (bat.healthSupported) rows.push({
                    n: "Battery health", s: "Capacity against when it was new", type: "info",
                    value: Math.round(bat.healthPercentage) + "%" });
            } else {
                rows.push({ n: "Battery", s: "No battery on this machine", type: "info", value: "AC" });
            }
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
