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
    readonly property bool mixerPane: Config.UiState.ccExpanded === "Mixer"

    implicitWidth: 384
    implicitHeight: mixerPane ? mixerView.implicitHeight
                  : expanded ? expandedView.implicitHeight : mainView.implicitHeight

    Behavior on implicitHeight { NumberAnimation { duration: Config.Appearance.anim(180); easing.type: Easing.OutCubic } }

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
                        inkColor: Config.Appearance.inkOnAccent
                        monochrome: true
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        text: Services.SysInfo.user
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        text: Services.SysInfo.sessionLabel(Services.Compositor.monitorCount)
                        font.pixelSize: Config.Appearance.fs(11)
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
                Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }

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
                        font.pixelSize: Config.Appearance.fs(12)
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

                        MouseArea {
                            id: tileArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tile.modelData.go()
                        }

                        Rectangle {
                            id: tileBg
                            anchors.fill: parent
                            radius: Config.Appearance.rCard
                            clip: true
                            color: tile.modelData.on ? Config.Appearance.accent
                                 : (tileArea.containsMouse ? Config.Appearance.sel : Config.Appearance.hover)
                            Behavior on color { ColorAnimation { duration: Config.Appearance.anim(140) } }

                            // Bottom rail, brighter when the tile is on.
                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - 24
                                height: 2
                                radius: 1
                                color: tile.modelData.on ? Config.Appearance.inkOnAccent : Config.Appearance.div
                                opacity: tile.modelData.on ? 0.55 : 1
                            }
                        }

                        MonoIcon {
                            x: 12
                            y: 12
                            name: tile.modelData.icon
                            size: 18
                            inkColor: tile.modelData.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink
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
                            color: moreArea.containsMouse
                                   ? (tile.modelData.on ? Qt.rgba(0, 0, 0, 0.16) : Config.Appearance.sel)
                                   : "transparent"

                            MonoIcon {
                                anchors.centerIn: parent
                                name: "chevronRight"
                                size: 13
                                inkColor: tile.modelData.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                                monochrome: true
                            }

                            MouseArea {
                                id: moreArea
                                anchors.fill: parent
                                // A 22px chevron is a small target for the one
                                // control on the tile that is not destructive,
                                // so the hit area is grown past its edges.
                                anchors.margins: -6
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Config.UiState.ccExpanded = tile.modelData.n;
                                    if (tile.modelData.n === "Wi-Fi") Services.Network.scan();
                                    else Services.Bluetooth.refresh();
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
                                font.pixelSize: Config.Appearance.fs(12)
                                font.weight: Font.DemiBold
                                color: tile.modelData.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: tile.modelData.s
                                font.pixelSize: Config.Appearance.fs(11)
                                font.weight: Font.Normal
                                opacity: tile.modelData.on ? 0.75 : 1
                                color: tile.modelData.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink3
                            }
                        }

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
                                name: root.sliderIcon(sliderRow.modelData)
                                size: 15
                                inkColor: Config.Appearance.ink2
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sliderName(sliderRow.modelData)
                                font.pixelSize: Config.Appearance.fs(12)
                                color: Config.Appearance.ink2
                            }
                            // Volume opens the mixer: each app's own level.
                            Rectangle {
                                visible: sliderRow.modelData === "volume"
                                anchors.verticalCenter: parent.verticalCenter
                                width: mixRow.implicitWidth + 14
                                height: 20
                                radius: 10
                                color: mixHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                                Row {
                                    id: mixRow
                                    anchors.centerIn: parent
                                    spacing: 3
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: Services.Audio.streams.length > 0 ? "Apps · " + Services.Audio.streams.length : "Apps"
                                        font.pixelSize: Config.Appearance.fs(10.5)
                                        font.weight: Font.DemiBold
                                        color: mixHover.hovered ? Config.Appearance.ink : Config.Appearance.ink3
                                    }
                                    MonoIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "chevronRight"; size: 11; monochrome: true
                                        inkColor: Config.Appearance.ink3
                                    }
                                }
                                HoverHandler { id: mixHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: Config.UiState.ccExpanded = "Mixer" }
                            }
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.sliderLabel(sliderRow.modelData)
                            font.pixelSize: Config.Appearance.fs(12)
                            font.weight: Font.DemiBold
                        }
                    }

                    FillSlider {
                        width: parent.width
                        trough: 20
                        radius: 10
                        value: root.sliderValue(sliderRow.modelData)
                        onMoved: v => root.sliderSet(sliderRow.modelData, v)
                    }
                }
            }
        }
    }

    // ── the volume mixer ──────────────────────────────────────────────────
    Loader {
        id: mixerView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        active: root.mixerPane
        visible: active
        implicitHeight: item ? item.implicitHeight : 0
        sourceComponent: AppMixer {}
    }

    // ── drill-down ────────────────────────────────────────────────────────
    Column {
        id: expandedView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        visible: root.expanded && !root.mixerPane

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
                    font.pixelSize: Config.Appearance.fs(13)
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
                    font.pixelSize: Config.Appearance.fs(11)
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

                            // Grows to hold the password field when this is
                            // the row being asked about.
                            readonly property bool asking:
                                entry.modelData.asks
                                && root.askingSsid === entry.modelData.key
                            // A network that authenticates the person wants
                            // a username above the password, so the sheet
                            // below the row is a field taller.
                            readonly property bool wantsUser:
                                entry.modelData.wantsUser === true
                            height: asking ? 44 + (wantsUser ? 78 : 40) : 44
                            Behavior on height {
                                NumberAnimation { duration: Config.Appearance.anim(140); easing.type: Easing.OutCubic }
                            }
                            clip: true

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 44
                                radius: Config.Appearance.rSm
                                color: entry.modelData.current ? Config.Appearance.sel
                                     : (entryHover.hovered ? Config.Appearance.hover : "transparent")
                                Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: metaLabel.left
                                anchors.rightMargin: 10
                                anchors.top: parent.top
                                anchors.topMargin: 8
                                height: 28
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
                                        font.pixelSize: Config.Appearance.fs(12)
                                    }
                                    StyledText {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: entry.modelData.s
                                        font.pixelSize: Config.Appearance.fs(10)
                                        font.weight: Font.Normal
                                        color: Config.Appearance.ink3
                                    }
                                }
                            }

                            StyledText {
                                id: metaLabel
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.top: parent.top
                                anchors.topMargin: 16
                                text: entry.modelData.meta
                                font.pixelSize: Config.Appearance.fs(10)
                                font.weight: Font.DemiBold
                                color: entry.modelData.current
                                       ? Config.Appearance.accent : Config.Appearance.ink3
                            }

                            // Only the row proper reacts; the password field
                            // below it would otherwise re-trigger the tap.
                            Item {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 44
                                HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: entry.modelData.go() }
                            }

                            // Asked for in place, so joining a new network
                            // never means opening Settings.
                            Column {
                                id: askSheet
                                visible: entry.asking
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.top: parent.top
                                anchors.topMargin: 46
                                spacing: 8

                                // Only for the networks that ask who you
                                // are — a home network has one secret and
                                // no use for a name.
                                Rectangle {
                                    visible: entry.wantsUser
                                    width: parent.width
                                    height: 30
                                    radius: Config.Appearance.rSm
                                    color: Config.Appearance.ground
                                    border.width: user.activeFocus ? 2 : 1
                                    border.color: user.activeFocus
                                                  ? Config.Appearance.accent
                                                  : Config.Appearance.rule

                                    TextInput {
                                        id: user
                                        anchors.fill: parent
                                        anchors.leftMargin: 9
                                        anchors.rightMargin: 9
                                        verticalAlignment: Text.AlignVCenter
                                        clip: true
                                        color: Config.Appearance.ink
                                        font.family: Config.Appearance.fontFamily
                                        font.pixelSize: Config.Appearance.fs(12)
                                        selectByMouse: true
                                        // The username field takes the focus
                                        // when there is one, since it is the
                                        // first thing to fill in.
                                        focus: entry.asking && entry.wantsUser
                                        onAccepted: pass.forceActiveFocus()

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: user.text === "" && !user.activeFocus
                                            text: "Username"
                                            font.pixelSize: Config.Appearance.fs(12)
                                            color: Config.Appearance.ink3
                                        }
                                    }
                                }

                            Row {
                                width: parent.width
                                spacing: 8

                                Rectangle {
                                    width: parent.width - joinButton.width - 8
                                    height: 30
                                    radius: Config.Appearance.rSm
                                    color: Config.Appearance.ground
                                    border.width: pass.activeFocus ? 2 : 1
                                    border.color: pass.activeFocus
                                                  ? Config.Appearance.accent
                                                  : Config.Appearance.rule

                                    TextInput {
                                        id: pass
                                        anchors.fill: parent
                                        anchors.leftMargin: 9
                                        anchors.rightMargin: 9
                                        verticalAlignment: Text.AlignVCenter
                                        clip: true
                                        color: Config.Appearance.ink
                                        font.family: Config.Appearance.fontFamily
                                        font.pixelSize: Config.Appearance.fs(12)
                                        echoMode: TextInput.Password
                                        selectByMouse: true
                                        focus: entry.asking && !entry.wantsUser
                                        onAccepted: {
                                            Services.Network.connect(entry.modelData.key,
                                                                     text, user.text);
                                            root.askingSsid = "";
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: pass.text === "" && !pass.activeFocus
                                            text: "Password"
                                            font.pixelSize: Config.Appearance.fs(12)
                                            color: Config.Appearance.ink3
                                        }
                                    }
                                }

                                Rectangle {
                                    id: joinButton
                                    width: joinLabel.implicitWidth + 22
                                    height: 30
                                    radius: Config.Appearance.rSm
                                    color: Config.Appearance.accent
                                    opacity: joinHover.hovered ? 0.9 : 1

                                    StyledText {
                                        id: joinLabel
                                        anchors.centerIn: parent
                                        text: "Join"
                                        font.pixelSize: Config.Appearance.fs(12)
                                        font.weight: Font.DemiBold
                                        color: Config.Appearance.inkOnAccent
                                    }

                                    HoverHandler { id: joinHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            Services.Network.connect(entry.modelData.key,
                                                                     pass.text, user.text);
                                            root.askingSsid = "";
                                        }
                                    }
                                }
                            }
                            }
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
                              : (Services.Bluetooth.powered
                                 ? "No devices — scan to find one" : "Bluetooth is off")
                        font.pixelSize: Config.Appearance.fs(12)
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
                        font.pixelSize: Config.Appearance.fs(11)
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
                    font.pixelSize: Config.Appearance.fs(11)
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
    // The network the list is currently asking a password for. One at a
    // time: the row grows a field in place rather than opening anything.
    property string askingSsid: ""

    // Ask for the keyboard only while the field is up, and give it back when
    // the panel closes with the field still open.
    onAskingSsidChanged: Config.UiState.panelWantsKeyboard = askingSsid !== ""

    Connections {
        target: Config.UiState
        function onControlCenterOpenChanged() {
            if (!Config.UiState.controlCenterOpen) root.askingSsid = "";
        }
    }

    readonly property bool airplane: !Services.Network.wifiEnabled
                                     && (!Services.Bluetooth.available || !Services.Bluetooth.powered)

    // Whether the shell has game mode on. Deliberately shell state rather than
    // a reading of PowerProfiles.profile: power-profiles-daemon is absent or
    // masked on plenty of systems, and a tile that never lights up because the
    // daemon silently refused the write is worse than one that tells you what
    // it managed to do.
    readonly property bool gameMode: Config.Appearance.gameMode
    readonly property bool canSetProfile: PowerProfiles.hasPerformanceProfile

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
            s: gameMode ? (canSetProfile ? "performance · vrr" : "vrr")
                        : (canSetProfile ? "balanced" : "vrr off"),
            go: () => root.setGameMode(!gameMode)
        }
    ].concat(Services.Idle.builtin ? [{
            // No lock, screen off or sleep until switched off again.
            n: "Keep awake", icon: "sun",
            on: Services.Idle.keepAwake,
            s: Services.Idle.keepAwake ? "on" : "off",
            go: () => Services.Idle.keepAwake = !Services.Idle.keepAwake
        }] : []).concat(Services.Rog.hasProfiles ? [{
            // asusd's profile (ROG laptops): each press moves one along.
            n: "Performance", icon: "zap",
            on: Services.Rog.profile === 1,
            s: Services.Rog.profileName(Services.Rog.profile).toLowerCase(),
            go: () => Services.Rog.cycleProfile()
        }] : []).concat(Services.Rog.hasKbd ? [{
            n: "Keyboard light", icon: "keyboard",
            on: Services.Rog.kbdBrightness > 0,
            s: (Services.Rog.kbdLevels[Services.Rog.kbdBrightness] || "").toLowerCase(),
            go: () => Services.Rog.cycleKbd()
        }] : [])

    // The slider list is deliberately just keys, not built objects.
    //
    // A model that carries the live value rebuilds whenever that value
    // changes — and setting the volume changes it. The Repeater then
    // destroys and recreates every delegate, including the one being
    // dragged, which takes its mouse grab with it. That is why these felt
    // different from the ones in Settings.
    //
    // Keys only change when a device appears or disappears. The delegates
    // read the live values through the functions below, and a property read
    // inside a called function still registers as a binding dependency, so
    // they stay live.
    readonly property var sliders: {
        const out = ["volume"];
        if (Services.Brightness.available) out.push("brightness");
        if (Services.Audio.sourceReady) out.push("mic");
        return out;
    }

    function sliderName(k) {
        return k === "volume" ? "Volume" : (k === "brightness" ? "Brightness" : "Microphone");
    }

    function sliderIcon(k) {
        if (k === "volume") return Services.Audio.icon;
        if (k === "brightness") return "sun";
        return Services.Audio.inputMuted ? "micOff" : "mic";
    }

    function sliderValue(k) {
        if (k === "volume") return Services.Audio.volume;
        if (k === "brightness") return Services.Brightness.value;
        return Services.Audio.inputVolume;
    }

    function sliderLabel(k) {
        if (k === "volume")
            return Services.Audio.muted ? "muted" : Services.Audio.volumePercent + "%";
        if (k === "brightness") return Services.Brightness.percent + "%";
        return Services.Audio.inputMuted ? "muted" : Services.Audio.inputPercent + "%";
    }

    function sliderSet(k, v) {
        if (k === "volume") Services.Audio.setVolume(v);
        else if (k === "brightness") Services.Brightness.set(v);
        else Services.Audio.setInputVolume(v);
    }

    readonly property var expandedEntries: {
        if (wifiPane) {
            return Services.Network.networks.map(ap => ({
                n: ap.ssid,
                s: Services.Network.securityLabel(ap)
                   + (ap.inUse ? " · connected"
                      : (Services.Network.busySsid === ap.ssid ? " · joining…"
                         : (Services.Network.errors[ap.ssid] ? " · didn't connect"
                            : (ap.known ? " · saved"
                               : (ap.enterprise ? " · sign in" : ""))))),
                icon: "wifi",
                meta: ap.signal + "%",
                current: ap.inUse,
                // A saved or open network joins on a tap, and a new home
                // network asks for its password here. A university network
                // has a form's worth of options, so it opens Settings on it.
                asks: Services.Network.needsPassword(ap) && !ap.enterprise,
                wantsUser: false,
                key: ap.ssid,
                go: () => {
                    if (ap.inUse) { Services.Network.disconnect(); return; }
                    if (Services.Network.needsIdentity(ap)) {
                        Services.Network.focusSsid = ap.ssid;
                        Config.UiState.openSettings("Network");
                        return;
                    }
                    if (Services.Network.needsPassword(ap)) {
                        root.askingSsid = root.askingSsid === ap.ssid ? "" : ap.ssid;
                        return;
                    }
                    root.askingSsid = "";
                    Services.Network.join(ap.ssid, "");
                }
            }));
        }
        // Paired devices, then what a scan found that has a name.
        const bt = Services.Bluetooth;
        return bt.pairedDevices.concat(bt.nearbyDevices).map(dev => ({
            n: dev.name,
            s: bt.busy[dev.mac] ? "Working…"
               : bt.errors[dev.mac] ? "Didn't work · open Settings for why"
               : (dev.connected ? "Connected" + (dev.battery >= 0 ? " · " + dev.battery + "%" : "")
                  : (dev.paired ? "Paired · tap to connect"
                     : "Not paired · tap to pair")),
            icon: "bluetooth",
            meta: dev.connected ? "on" : (dev.paired ? "" : "new"),
            current: dev.connected,
            asks: false,
            key: dev.mac,
            go: () => bt.toggleDevice(dev)
        }));
    }

    // ── tile actions ──────────────────────────────────────────────────────
    // The capture toolbar: region, window or screen, picture or video.
    function capture() { Config.UiState.toggleCapture(); }

    function setGameMode(on) {
        Config.Appearance.gameMode = on;
        // Adaptive sync while a fullscreen client is focused — the mockup's
        // "vrr on" subtitle. Via hl.config, not the keyword dispatcher: a
        // Lua-config Hyprland rejects keyword outright and still exits 0, so
        // that spelling looked like it worked and never did.
        Services.Compositor.setConfig({ misc: { vrr: on ? 2 : 0 } });
        // The power profile is best-effort: without power-profiles-daemon the
        // write goes nowhere, which is why the tile does not read back from it.
        if (canSetProfile) {
            PowerProfiles.profile = on ? PowerProfile.Performance : PowerProfile.Balanced;
        }
    }
}
