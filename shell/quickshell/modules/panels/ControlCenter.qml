import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Control center: the account header with the theme cycler, a 3x2 grid of
// quick-toggle tiles, and the level sliders.
//
// Wi-Fi and Bluetooth tiles drill down into a real device list (the mockup's
// `ccExpand` state) — pick a network or a paired device straight from here.
// Everything on this panel acts on the system: no tile is decorative.
PanelSurface {
    id: root

    readonly property bool expanded: Config.UiState.ccExpanded !== ""
    readonly property bool wifiPane: Config.UiState.ccExpanded === "Wi-Fi"

    implicitWidth: 384
    implicitHeight: expanded ? expandedView.implicitHeight : mainView.implicitHeight

    Behavior on implicitHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    // ── main ──────────────────────────────────────────────────────────────
    Column {
        id: mainView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        visible: !root.expanded

        // Header
        Item {
            width: parent.width
            height: 62

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    height: 34
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.accent

                    MonoIcon {
                        anchors.centerIn: parent
                        name: "user"
                        size: 18
                        inkColor: Config.Appearance.onAccent
                        monochrome: true
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        text: Services.SysInfo.user
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        text: Services.SysInfo.sessionLabel(Services.Compositor.monitorCount)
                        font.pixelSize: 11
                        font.weight: Font.Normal
                        color: Config.Appearance.ink3
                    }
                }
            }

            // Theme cycler: light → dark → auto
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: themeRow.implicitWidth + 24
                height: 30
                radius: 9
                color: themeHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                Behavior on color { ColorAnimation { duration: 120 } }

                Row {
                    id: themeRow
                    anchors.centerIn: parent
                    spacing: 8

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: Config.Appearance.theme === "auto" ? "sunMoon"
                            : (Config.Appearance.dark ? "moon" : "sun")
                        size: 13
                        inkColor: Config.Appearance.ink
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Config.Appearance.theme === "auto" ? "Auto"
                            : (Config.Appearance.dark ? "Dark" : "Light")
                        font.pixelSize: 11.5
                        font.weight: Font.DemiBold
                    }
                }

                HoverHandler { id: themeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Config.Appearance.cycleTheme() }
            }
        }

        // ── tiles ─────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: tileGrid.height + 12

            Grid {
                id: tileGrid
                x: 12
                width: parent.width - 24
                columns: 3
                spacing: 6

                Repeater {
                    model: root.tiles

                    Item {
                        id: tile
                        required property var modelData
                        width: (tileGrid.width - tileGrid.spacing * 2) / 3
                        height: 88

                        Rectangle {
                            id: tileBg
                            anchors.fill: parent
                            radius: Config.Appearance.rCard
                            clip: true
                            color: tile.modelData.on ? Config.Appearance.accent
                                 : (tileHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
                            Behavior on color { ColorAnimation { duration: 140 } }

                            // Bottom rail, brighter when the tile is on.
                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - 24
                                height: 2
                                radius: 1
                                color: tile.modelData.on ? Config.Appearance.onAccent : Config.Appearance.div
                                opacity: tile.modelData.on ? 0.55 : 1
                            }
                        }

                        MonoIcon {
                            x: 12
                            y: 12
                            name: tile.modelData.icon
                            size: 18
                            inkColor: tile.modelData.on ? Config.Appearance.onAccent : Config.Appearance.ink
                            monochrome: true
                        }

                        // Drill-down affordance (Wi-Fi / Bluetooth only)
                        Rectangle {
                            visible: tile.modelData.more === true
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 8
                            width: 22
                            height: 22
                            radius: Config.Appearance.rSm
                            color: moreHover.hovered
                                   ? (tile.modelData.on ? Qt.rgba(0, 0, 0, 0.16) : Config.Appearance.sel)
                                   : "transparent"

                            MonoIcon {
                                anchors.centerIn: parent
                                name: "chevronRight"
                                size: 13
                                inkColor: tile.modelData.on ? Config.Appearance.onAccent : Config.Appearance.ink2
                                monochrome: true
                            }

                            HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    Config.UiState.ccExpanded = tile.modelData.n;
                                    if (tile.modelData.n === "Wi-Fi") Services.Network.scan();
                                }
                            }
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.bottomMargin: 11
                            spacing: 2

                            StyledText {
                                text: tile.modelData.n
                                font.pixelSize: 11.5
                                font.weight: Font.DemiBold
                                color: tile.modelData.on ? Config.Appearance.onAccent : Config.Appearance.ink
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: tile.modelData.s
                                font.pixelSize: 10.5
                                font.weight: Font.Normal
                                opacity: tile.modelData.on ? 0.75 : 1
                                color: tile.modelData.on ? Config.Appearance.onAccent : Config.Appearance.ink3
                            }
                        }

                        HoverHandler { id: tileHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: tile.modelData.go() }
                    }
                }
            }
        }

        // ── sliders ───────────────────────────────────────────────────────
        Column {
            x: 16
            width: parent.width - 32
            spacing: 14
            bottomPadding: 16
            topPadding: 4

            Repeater {
                model: root.sliders

                Column {
                    id: sliderRow
                    required property var modelData
                    width: parent.width
                    spacing: 7

                    Item {
                        width: parent.width
                        height: 15

                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: sliderRow.modelData.icon
                                size: 15
                                inkColor: Config.Appearance.ink2
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: sliderRow.modelData.n
                                font.pixelSize: 11.5
                                color: Config.Appearance.ink2
                            }
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: sliderRow.modelData.label
                            font.pixelSize: 11.5
                            font.weight: Font.DemiBold
                        }
                    }

                    FillSlider {
                        width: parent.width
                        trough: 20
                        radius: 10
                        value: sliderRow.modelData.value
                        onMoved: v => sliderRow.modelData.set(v)
                    }
                }
            }
        }
    }

    // ── drill-down ────────────────────────────────────────────────────────
    Column {
        id: expandedView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        visible: root.expanded

        Item {
            width: parent.width
            height: 50

            Rectangle {
                id: backBtn
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                height: 30
                radius: Config.Appearance.rSm
                color: backHover.hovered ? Config.Appearance.hover : "transparent"

                MonoIcon {
                    anchors.centerIn: parent
                    name: "chevronLeft"
                    size: 15
                    inkColor: Config.Appearance.ink2
                    monochrome: true
                }

                HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Config.UiState.ccExpanded = "" }
            }

            Column {
                anchors.left: backBtn.right
                anchors.leftMargin: 10
                anchors.right: radioToggle.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    text: Config.UiState.ccExpanded
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.wifiPane
                          ? (Services.Network.wifiEnabled
                             ? (Services.Network.connected
                                ? "Connected to " + Services.Network.ssid : "Not connected")
                             : "Wi-Fi is off")
                          : (Services.Bluetooth.powered
                             ? Services.Bluetooth.pairedCount + " paired" : "Bluetooth is off")
                    font.pixelSize: 10.5
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }
            }

            Toggle {
                id: radioToggle
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                checked: root.wifiPane ? Services.Network.wifiEnabled : Services.Bluetooth.powered
                onToggled: on => {
                    if (root.wifiPane) Services.Network.setWifiEnabled(on);
                    else Services.Bluetooth.setPowered(on);
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

        // Entry list
        Item {
            width: parent.width
            height: Math.min(268, Math.max(56, entryColumn.implicitHeight + 10))

            Flickable {
                anchors.fill: parent
                anchors.topMargin: 6
                anchors.bottomMargin: 4
                contentHeight: entryColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: entryColumn
                    x: 8
                    width: parent.width - 16
                    spacing: 1

                    Repeater {
                        model: root.expandedEntries

                        Item {
                            id: entry
                            required property var modelData
                            width: entryColumn.width
                            height: 44

                            Rectangle {
                                anchors.fill: parent
                                radius: Config.Appearance.rSm
                                color: entry.modelData.current ? Config.Appearance.sel
                                     : (entryHover.hovered ? Config.Appearance.hover : "transparent")
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: metaLabel.left
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 28
                                    height: 28
                                    radius: Config.Appearance.rSm
                                    color: Config.Appearance.hover
                                    border.width: 1
                                    border.color: Config.Appearance.rule

                                    MonoIcon {
                                        anchors.centerIn: parent
                                        name: entry.modelData.icon
                                        size: 14
                                        inkColor: entry.modelData.current
                                                  ? Config.Appearance.accent : Config.Appearance.ink2
                                        monochrome: true
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 38
                                    spacing: 2

                                    StyledText {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: entry.modelData.n
                                        font.pixelSize: 12
                                    }
                                    StyledText {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: entry.modelData.s
                                        font.pixelSize: 10
                                        font.weight: Font.Normal
                                        color: Config.Appearance.ink3
                                    }
                                }
                            }

                            StyledText {
                                id: metaLabel
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: entry.modelData.meta
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                color: entry.modelData.current
                                       ? Config.Appearance.accent : Config.Appearance.ink3
                            }

                            HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: entry.modelData.go() }
                        }
                    }

                    StyledText {
                        visible: root.expandedEntries.length === 0
                        width: entryColumn.width
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 18
                        bottomPadding: 18
                        text: root.wifiPane
                              ? (Services.Network.wifiEnabled ? "Looking for networks…" : "Wi-Fi is off")
                              : (Services.Bluetooth.powered ? "No paired devices" : "Bluetooth is off")
                        font.pixelSize: 12
                        color: Config.Appearance.ink3
                    }
                }
            }
        }

        // Footer
        Rectangle {
            width: parent.width
            height: 42
            color: Config.Appearance.hover

            Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

            Rectangle {
                id: rescan
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: rescanRow.implicitWidth + 20
                height: 26
                radius: Config.Appearance.rSm
                color: rescanHover.hovered ? Config.Appearance.sel : "transparent"

                Row {
                    id: rescanRow
                    anchors.centerIn: parent
                    spacing: 7
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "refresh"
                        size: 12
                        inkColor: Config.Appearance.ink2
                        monochrome: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.wifiPane ? "Rescan" : "Scan"
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink2
                    }
                }

                HoverHandler { id: rescanHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: root.wifiPane ? Services.Network.scan() : Services.Bluetooth.scan()
                }
            }

            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: moreLabel.implicitWidth + 20
                height: 26
                radius: Config.Appearance.rSm
                color: moreSettingsHover.hovered ? Config.Appearance.sel : "transparent"

                StyledText {
                    id: moreLabel
                    anchors.centerIn: parent
                    text: "More settings"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: moreSettingsHover.hovered ? Config.Appearance.ink : Config.Appearance.ink3
                }

                HoverHandler { id: moreSettingsHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: Config.UiState.openSettings(root.wifiPane ? "Network" : "Bluetooth")
                }
            }
        }
    }

    // ── tile model ────────────────────────────────────────────────────────
    // Airplane mode is derived rather than read from rfkill: "all radios
    // off" is exactly what the shell can both observe and set through the
    // two radio services it already talks to.
    readonly property bool airplane: !Services.Network.wifiEnabled
                                     && (!Services.Bluetooth.available || !Services.Bluetooth.powered)

    readonly property bool gameMode: PowerProfiles.profile === PowerProfile.Performance

    readonly property var tiles: [
        {
            n: "Wi-Fi", icon: Services.Network.icon, more: true,
            on: Services.Network.wifiEnabled,
            s: Services.Network.label,
            go: () => Services.Network.toggleWifi()
        },
        {
            n: "Bluetooth", icon: "bluetooth", more: true,
            on: Services.Bluetooth.powered,
            s: Services.Bluetooth.label,
            go: () => Services.Bluetooth.togglePowered()
        },
        {
            n: "Night light", icon: "moon",
            on: Services.NightLight.active,
            s: Services.NightLight.available ? Services.NightLight.label : "not installed",
            go: () => Services.NightLight.toggle()
        },
        {
            n: "Airplane", icon: "plane",
            on: airplane,
            s: airplane ? "radios off" : "radios on",
            go: () => {
                const goingOn = !airplane;
                Services.Network.setWifiEnabled(!goingOn);
                if (Services.Bluetooth.available) Services.Bluetooth.setPowered(!goingOn);
            }
        },
        {
            n: "Capture", icon: "camera",
            on: false,
            s: "region",
            go: () => root.capture()
        },
        {
            n: "Game mode", icon: "gamepad",
            on: gameMode,
            s: gameMode ? "performance · vrr" : "balanced",
            go: () => root.setGameMode(!gameMode)
        }
    ]

    readonly property var sliders: {
        const out = [{
            n: "Volume", icon: Services.Audio.icon,
            value: Services.Audio.volume,
            label: Services.Audio.muted ? "muted" : Services.Audio.volumePercent + "%",
            set: v => Services.Audio.setVolume(v)
        }];
        if (Services.Brightness.available) out.push({
            n: "Brightness", icon: "sun",
            value: Services.Brightness.value,
            label: Services.Brightness.percent + "%",
            set: v => Services.Brightness.set(v)
        });
        if (Services.Audio.sourceReady) out.push({
            n: "Microphone", icon: Services.Audio.inputMuted ? "micOff" : "mic",
            value: Services.Audio.inputVolume,
            label: Services.Audio.inputMuted ? "muted" : Services.Audio.inputPercent + "%",
            set: v => Services.Audio.setInputVolume(v)
        });
        return out;
    }

    readonly property var expandedEntries: {
        if (wifiPane) {
            return Services.Network.networks.map(ap => ({
                n: ap.ssid,
                s: (ap.security && ap.security !== "" ? ap.security : "Open")
                   + (ap.inUse ? " · connected" : ""),
                icon: "wifi",
                meta: ap.signal + "%",
                current: ap.inUse,
                go: () => { if (!ap.inUse) Services.Network.connect(ap.ssid); }
            }));
        }
        return Services.Bluetooth.devices.map(dev => ({
            n: dev.name,
            s: dev.connected ? "Connected" : "Paired",
            icon: "bluetooth",
            meta: dev.connected ? "on" : "",
            current: dev.connected,
            go: () => Services.Bluetooth.toggleDevice(dev)
        }));
    }

    // ── tile actions ──────────────────────────────────────────────────────
    function capture() {
        Config.UiState.closeAll();
        // grim + slurp is the standard wlroots pair; the file lands where
        // the mockup's screenshot notification says it does.
        Quickshell.execDetached(["sh", "-c",
            "sleep 0.15; f=\"$HOME/Pictures/$(date +%Y-%m-%d-%H%M%S).png\"; "
            + "mkdir -p \"$HOME/Pictures\"; "
            + "grim -g \"$(slurp)\" \"$f\" && (wl-copy < \"$f\" 2>/dev/null; "
            + "notify-send -a Screenshot 'Region saved' \"$f\")"]);
    }

    function setGameMode(on) {
        PowerProfiles.profile = on ? PowerProfile.Performance : PowerProfile.Balanced;
        // Adaptive sync while a fullscreen client is focused — the mockup's
        // "vrr on" subtitle.
        Services.Compositor.dispatch("keyword misc:vrr " + (on ? "2" : "0"));
    }
}
