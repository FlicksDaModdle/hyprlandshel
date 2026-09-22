import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
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
        "Appearance":    { icon: "palette",   group: "Shell",  note: "Theme, accent, translucency and geometry. Every change repaints the shell live." },
        "Bar":           { icon: "layout",    group: "Shell",  note: "The top bar: height, clock, tray and the task list." },
        "Dock":          { icon: "dock",      group: "Shell",  note: "The dock: position, size, labels and auto-hide." },
        "Notifications": { icon: "bell",      group: "Shell",  note: "Banner behaviour, badge counts and how the center stacks items." },
        "Keybinds":      { icon: "keyboard",  group: "Shell",  note: "Hyprland bindings this shell listens for." },
        "Display":       { icon: "monitor",   group: "Device", note: "Resolution, refresh rate and scaling, applied through Hyprland." },
        "Network":       { icon: "wifi",      group: "Device", note: "Wireless and connection policy." },
        "Bluetooth":     { icon: "bluetooth", group: "Device", note: "Radio state, paired devices and discovery." },
        "Sound":         { icon: "volume",    group: "Device", note: "Output and input levels and the active device." },
        "Power":         { icon: "battery",   group: "Device", note: "Power profile, idle timing and battery care." },
        "Input":         { icon: "keyboard",  group: "Device", note: "Touchpad behaviour and key repeat." },
        "About":         { icon: "cpu",       group: "Device", note: "This machine and the shell running on it." }
    })

    readonly property var paneGroups: [
        { label: "Shell",  items: ["Appearance", "Bar", "Dock", "Notifications", "Keybinds"] },
        { label: "Device", items: ["Display", "Network", "Bluetooth", "Sound", "Power", "Input", "About"] }
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
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.13
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "quickshell · live"
                    font.pixelSize: 12
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

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 8
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
                            font.pixelSize: 11
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
                                        font.pixelSize: 13
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

        // ── pane ──────────────────────────────────────────────────────────
        Flickable {
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            anchors.bottom: parent.bottom
            contentHeight: paneColumn.implicitHeight + 40
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: paneColumn
                x: 24
                y: 20
                width: parent.width - 48
                spacing: 0

                StyledText {
                    text: settings.pane
                    font.pixelSize: 17
                    font.weight: Font.Bold
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: settings.paneMeta[settings.pane].note
                    font.pixelSize: 13
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
                                font.pixelSize: 13
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
                                    font.pixelSize: 12
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
              value: A.dockAutoHide, set: v => A.dockAutoHide = v }
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
            const m = Services.Compositor.monitors.find(x => x.focused)
                      || Services.Compositor.monitors[0];
            if (!m) return [{ n: "No display", s: "Hyprland reported no monitors", type: "info", value: "—" }];
            const ipc = m.lastIpcObject || ({});
            const modes = (ipc.availableModes || []).slice(0, 12);
            return [
                { n: "Output", s: m.description || "Active monitor", type: "info", value: m.name },
                { n: "Mode", s: "Resolution and refresh rate on " + m.name,
                  type: modes.length > 0 ? "menu" : "info",
                  options: modes,
                  value: m.width + "x" + m.height + "@" + Math.round(ipc.refreshRate || 0) + "Hz",
                  set: v => settings.applyMode(m.name, v) },
                { n: "Scale", s: "Fractional scaling for HiDPI panels", type: "slider",
                  min: 100, max: 200, unit: "%", value: Math.round((m.scale || 1) * 100),
                  set: v => settings.applyScale(m.name, v / 100) },
                { n: "Adaptive sync", s: "VRR while a fullscreen client is focused", type: "toggle",
                  value: (ipc.vrr || 0) !== 0,
                  set: v => Services.Compositor.dispatch("keyword misc:vrr " + (v ? "2" : "0")) },
                { n: "Night shift", s: Services.NightLight.available
                    ? "Warm the panel — " + Services.NightLight.temperature + " K"
                    : "Install hyprsunset or wlsunset to enable", type: "toggle",
                  value: Services.NightLight.active,
                  set: v => Services.NightLight.setActive(v) },
                { n: "Colour temperature", s: "Warmth applied while night shift is on", type: "slider",
                  min: 2500, max: 6000, unit: "K", value: Services.NightLight.temperature,
                  set: v => Services.NightLight.setTemperature(v) },
                { n: "Arrangement", s: Services.Compositor.monitors.map(x => x.name).join(" · "),
                  type: "info",
                  value: Services.Compositor.monitorCount
                         + (Services.Compositor.monitorCount === 1 ? " display" : " displays") }
            ];
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

        case "Input": return [
            { n: "Tap to click", s: "Touchpad tap gestures", type: "toggle",
              value: settings.tapToClick,
              set: v => { settings.tapToClick = v;
                          Services.Compositor.dispatch("keyword input:touchpad:tap-to-click " + (v ? "1" : "0")); } },
            { n: "Natural scrolling", s: "Content follows finger direction", type: "toggle",
              value: settings.naturalScroll,
              set: v => { settings.naturalScroll = v;
                          Services.Compositor.dispatch("keyword input:touchpad:natural_scroll " + (v ? "1" : "0")); } },
            { n: "Key repeat rate", s: "Repeats per second while a key is held", type: "slider",
              min: 10, max: 60, unit: "/s", value: settings.repeatRate,
              set: v => { settings.repeatRate = v;
                          Services.Compositor.dispatch("keyword input:repeat_rate " + v); } },
            { n: "Repeat delay", s: "Milliseconds before a held key starts repeating", type: "slider",
              min: 150, max: 900, unit: "ms", value: settings.repeatDelay,
              set: v => { settings.repeatDelay = v;
                          Services.Compositor.dispatch("keyword input:repeat_delay " + v); } },
            { n: "Keyboard layout", s: "Active xkb keymap", type: "info",
              value: Services.SysInfo.keymap || "—" }
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
            { n: "Uptime", s: "Since last boot", type: "info", value: Services.SysInfo.uptimeLabel },
            { n: "Shell config", s: Config.Appearance.configDir + "/theme.json", type: "info",
              value: "theme.json" },
            { n: "Reload shell", s: "Re-read the QML tree without logging out", type: "action",
              label: "Reload", set: () => Services.Session.reloadShell() }
        ];
        }
        return [];
    }

    // ── input state ───────────────────────────────────────────────────────
    // Hyprland's `keyword` dispatcher is write-only, so these mirror what
    // the shell has set this session. They start from hyprland.lua's values.
    property bool tapToClick: true
    property bool naturalScroll: true
    property int repeatRate: 25
    property int repeatDelay: 600

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

    // Hyprland's monitor keyword takes `<name>,<mode>,<position>,<scale>`;
    // `auto` keeps whatever the compositor already decided for the fields
    // this row isn't changing.
    function applyMode(name, mode) {
        Services.Compositor.dispatch("keyword monitor " + name + "," + mode + ",auto,auto");
        Services.Compositor.refresh();
    }

    function applyScale(name, scale) {
        const m = Services.Compositor.monitors.find(x => x.name === name);
        if (!m) return;
        const ipc = m.lastIpcObject || ({});
        const mode = m.width + "x" + m.height + "@" + Math.round(ipc.refreshRate || 60);
        Services.Compositor.dispatch(
            "keyword monitor " + name + "," + mode + ",auto," + scale.toFixed(6));
        Services.Compositor.refresh();
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
