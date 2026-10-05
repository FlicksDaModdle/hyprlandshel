import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Bluetooth.
//
// The switch at the top; then your devices, each with the one thing to do
// to it; then "Add a device", which looks for devices for as long as this
// pane is open and lists what it finds. Pairing questions — "does this code
// match?", "type this code on the keyboard" — come up above everything, as
// KDE's and Windows' do, rather than failing silently for want of anyone
// to answer them.
Column {
    id: panel

    width: parent ? parent.width : 560
    spacing: 16

    readonly property var bt: Services.Bluetooth
    readonly property color danger: "#d93a2b"
    property string menuMac: ""     // the paired device whose extra actions are open
    property string pin: ""         // typed into a PIN or passkey question

    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Config.Appearance.ink3
    }
    component Card: Rectangle {
        width: panel.width
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
    }
    component Line: StyledText {
        width: parent ? parent.width : 0
        wrapMode: Text.WordWrap
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
    // A round badge with the device's glyph.
    component Badge: Rectangle {
        property string kind: ""
        property bool lit: false
        width: 36; height: 36; radius: 18
        color: lit ? Config.Appearance.accent : Config.Appearance.div
        MonoIcon {
            anchors.centerIn: parent
            name: panel.bt.glyph(parent.kind)
            size: 18
            monochrome: true
            inkColor: parent.lit ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
        }
    }

    // ══ no adapter ════════════════════════════════════════════════════════
    Card {
        visible: !panel.bt.available
        height: none.implicitHeight + 32
        Column {
            id: none
            x: 16; y: 16; width: parent.width - 32; spacing: 4
            StyledText { text: "No Bluetooth adapter"; font.pixelSize: Config.Appearance.fs(14); font.weight: Font.DemiBold }
            Line { text: "Either there isn't one, or the Bluetooth service isn't running: sudo systemctl enable --now bluetooth" }
        }
    }

    // ══ a pairing question ════════════════════════════════════════════════
    Card {
        id: ask
        readonly property var req: panel.bt.request
        readonly property var show: panel.bt.display
        visible: !!req || !!show
        border.width: 2
        border.color: Config.Appearance.accent
        height: askCol.implicitHeight + 32
        onReqChanged: panel.pin = ""

        Column {
            id: askCol
            x: 16; y: 16; width: parent.width - 32; spacing: 12

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: Config.Appearance.fs(15)
                font.weight: Font.DemiBold
                text: {
                    const r = ask.req, d = ask.show;
                    if (r) {
                        if (r.kind === "confirm") return "Pair with " + r.name + "?";
                        if (r.kind === "pin") return "Enter the PIN for " + r.name;
                        if (r.kind === "passkey") return "Enter the code shown on " + r.name;
                        if (r.kind === "authorize") return r.name + " wants to pair with this computer";
                        if (r.kind === "service") return r.name + " wants to connect";
                    }
                    if (d) return "Type this code on " + d.name;
                    return "";
                }
            }
            Line {
                text: {
                    const r = ask.req, d = ask.show;
                    if (r && r.kind === "confirm") return "Make sure the device shows the same code, then pair.";
                    if (r && r.kind === "pin") return "Often 0000 or 1234 — or the one in its manual or on its screen.";
                    if (r && r.kind === "passkey") return "Six digits, shown on the device's screen.";
                    if (r && (r.kind === "authorize" || r.kind === "service")) return "Allow it only if you started this from the device.";
                    if (d) return "Then press Enter on " + (d.kind === "pin" ? "it" : "the keyboard") + ".";
                    return "";
                }
            }

            // The code, large: confirmed, or to be typed on the device.
            StyledText {
                visible: (!!ask.req && ask.req.kind === "confirm") || !!ask.show
                text: (ask.req && ask.req.passkey) || (ask.show && ask.show.code) || ""
                font.family: Config.Appearance.monoFamily
                font.pixelSize: Config.Appearance.fs(30)
                font.weight: Font.Bold
                font.letterSpacing: 6
                color: Config.Appearance.ink
            }
            // Keys typed so far, when the keyboard reports them.
            Row {
                visible: !!ask.show && ask.show.entered !== undefined
                spacing: 6
                Repeater {
                    model: ask.show ? (ask.show.code || "").length : 0
                    Rectangle {
                        required property int index
                        width: 10; height: 10; radius: 5
                        color: ask.show && index < (ask.show.entered || 0) ? Config.Appearance.accent : Config.Appearance.div
                    }
                }
            }

            NetField {
                visible: !!ask.req && (ask.req.kind === "pin" || ask.req.kind === "passkey")
                width: Math.min(parent.width, 240)
                digits: !!ask.req && ask.req.kind === "passkey"
                placeholder: ask.req && ask.req.kind === "pin" ? "PIN" : "123456"
                text: panel.pin
                onEdited: t => panel.pin = t
                onAccepted: if (panel.pin !== "") panel.bt.answer(true, panel.pin)
            }

            Row {
                spacing: 8
                NetButton {
                    visible: !!ask.req
                    primary: true
                    label: ask.req && (ask.req.kind === "authorize" || ask.req.kind === "service") ? "Allow" : "Pair"
                    active: !ask.req || (ask.req.kind !== "pin" && ask.req.kind !== "passkey") || panel.pin !== ""
                    onClicked: panel.bt.answer(true, panel.pin)
                }
                NetButton {
                    label: ask.req && (ask.req.kind === "authorize" || ask.req.kind === "service") ? "Deny" : "Cancel"
                    onClicked: {
                        if (ask.req) panel.bt.answer(false);
                        else if (ask.show) panel.bt.cancelPairing(ask.show.mac);
                    }
                }
            }
        }
    }

    // ══ the switch ════════════════════════════════════════════════════════
    Card {
        visible: panel.bt.available
        height: top.implicitHeight + 32

        Column {
            id: top
            x: 16; y: 16; width: parent.width - 32; spacing: 14

            Item {
                width: parent.width
                height: 40
                Rectangle {
                    id: badge
                    width: 40; height: 40; radius: 20
                    color: panel.bt.powered ? Config.Appearance.accent : Config.Appearance.div
                    MonoIcon {
                        anchors.centerIn: parent
                        name: "bluetooth"; size: 20; monochrome: true
                        inkColor: panel.bt.powered ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                    }
                }
                Column {
                    anchors.left: badge.right
                    anchors.leftMargin: 12
                    anchors.right: power.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        text: panel.bt.powered ? "Bluetooth is on" : "Bluetooth is off"
                        font.pixelSize: Config.Appearance.fs(15)
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: !panel.bt.powered ? "Turn it on to use or add devices"
                            : panel.bt.connectedDevices.length > 0
                              ? "Connected to " + panel.bt.connectedDevices.map(d => d.name).join(", ")
                              : (panel.bt.controller !== "" ? "Shows up as “" + panel.bt.controller + "”" : "")
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink3
                    }
                }
                Toggle {
                    id: power
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.bt.powered
                    onToggled: on => panel.bt.setPowered(on)
                }
            }

            Row {
                visible: panel.bt.powered
                spacing: 10
                Toggle {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.bt.discoverable
                    onToggled: on => panel.bt.setDiscoverable(on)
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Let other devices find this computer"
                    font.pixelSize: Config.Appearance.fs(12)
                }
            }

            Line {
                visible: !panel.bt.live
                color: panel.danger
                text: Services.Agent.missing
                    ? "The pairing helper isn't built, so devices that ask for a code — phones, "
                      + "most keyboards — can't pair. Run install.sh again; it needs Rust (cargo), "
                      + "or cmake and a C++ compiler."
                    : "Starting the pairing helper…"
            }
        }
    }

    // ══ your devices ══════════════════════════════════════════════════════
    Caption {
        visible: panel.bt.available && panel.bt.pairedDevices.length > 0
        text: "Your devices"
    }
    Column {
        visible: panel.bt.available && panel.bt.pairedDevices.length > 0
        width: panel.width
        spacing: 2

        Repeater {
            model: panel.bt.pairedDevices
            Rectangle {
                id: dev
                required property var modelData
                readonly property var d: modelData
                readonly property string op: panel.bt.busy[d.mac] || ""
                readonly property string err: panel.bt.errors[d.mac] || ""
                readonly property bool menu: panel.menuMac === d.mac
                width: panel.width
                height: devCol.implicitHeight
                radius: Config.Appearance.rSm
                color: devHover.hovered || dev.menu ? Config.Appearance.hover : "transparent"

                Column {
                    id: devCol
                    width: parent.width
                    Item {
                        width: parent.width
                        height: 58
                        Badge {
                            id: dBadge
                            x: 12
                            anchors.verticalCenter: parent.verticalCenter
                            kind: dev.d.kind
                            lit: dev.d.connected
                        }
                        Column {
                            anchors.left: dBadge.right
                            anchors.leftMargin: 12
                            anchors.right: dActions.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: dev.d.name
                                font.pixelSize: Config.Appearance.fs(13)
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: dev.op === "connect" ? "Connecting…"
                                    : dev.op === "disconnect" ? "Disconnecting…"
                                    : dev.op === "pair" ? "Pairing…"
                                    : dev.err !== "" ? "Didn't connect — see below"
                                    : [dev.d.connected ? "Connected" : "Not connected",
                                       dev.d.battery >= 0 ? "Battery " + dev.d.battery + "%" : "",
                                       panel.bt.kindLabel(dev.d.kind)].filter(s => s).join(" · ")
                                font.pixelSize: Config.Appearance.fs(12)
                                color: dev.err !== "" && dev.op === "" ? panel.danger : Config.Appearance.ink3
                            }
                        }
                        Row {
                            id: dActions
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            NetButton {
                                label: dev.d.connected ? "Disconnect" : "Connect"
                                primary: !dev.d.connected
                                active: dev.op === "" && panel.bt.powered
                                onClicked: dev.d.connected ? panel.bt.disconnectDevice(dev.d.mac)
                                                           : panel.bt.connectDevice(dev.d.mac)
                            }
                            NetButton {
                                label: "•••"
                                onClicked: panel.menuMac = dev.menu ? "" : dev.d.mac
                            }
                        }
                        HoverHandler { id: devHover }
                    }
                    Line {
                        visible: dev.err !== "" && dev.op === ""
                        leftPadding: 60
                        rightPadding: 12
                        bottomPadding: 10
                        text: dev.err
                        color: panel.danger
                    }
                    Row {
                        visible: dev.menu
                        leftPadding: 60
                        bottomPadding: 12
                        spacing: 8
                        NetButton {
                            label: "Remove device"; danger: true
                            onClicked: { panel.bt.removeDevice(dev.d.mac); panel.menuMac = ""; }
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: dev.d.mac
                            font.family: Config.Appearance.monoFamily
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }
                }
            }
        }
    }

    // ══ add a device ══════════════════════════════════════════════════════
    Item {
        visible: panel.bt.available && panel.bt.powered
        width: panel.width
        height: 26
        Caption { anchors.verticalCenter: parent.verticalCenter; text: "Add a device" }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            // A pulsing dot while it looks.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: Config.Appearance.accent
                visible: panel.bt.discovering
                SequentialAnimation on opacity {
                    running: panel.bt.discovering
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.25; duration: 700 }
                    NumberAnimation { from: 0.25; to: 1; duration: 700 }
                }
            }
            StyledText {
                text: panel.bt.discovering ? "Looking for devices…" : "Look again"
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: panel.bt.discovering ? Config.Appearance.ink3 : Config.Appearance.accent
                HoverHandler { cursorShape: panel.bt.discovering ? Qt.ArrowCursor : Qt.PointingHandCursor }
                TapHandler { onTapped: panel.bt.scan() }
            }
        }
    }
    Line {
        visible: panel.bt.available && panel.bt.powered
        text: "Put the device in pairing mode — usually by holding its power or Bluetooth button until a light flashes. It shows up here when it's ready."
    }
    Column {
        visible: panel.bt.available && panel.bt.powered
        width: panel.width
        spacing: 2

        Repeater {
            model: panel.bt.nearbyDevices
            Rectangle {
                id: near
                required property var modelData
                readonly property var d: modelData
                readonly property string op: panel.bt.busy[d.mac] || ""
                readonly property string err: panel.bt.errors[d.mac] || ""
                width: panel.width
                height: nearCol.implicitHeight
                radius: Config.Appearance.rSm
                color: nearHover.hovered ? Config.Appearance.hover : "transparent"

                Column {
                    id: nearCol
                    width: parent.width
                    Item {
                        width: parent.width
                        height: 54
                        Badge {
                            id: nBadge
                            x: 12
                            anchors.verticalCenter: parent.verticalCenter
                            kind: near.d.kind
                        }
                        Column {
                            anchors.left: nBadge.right
                            anchors.leftMargin: 12
                            anchors.right: pairBtn.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: near.d.name
                                font.pixelSize: Config.Appearance.fs(13)
                                font.weight: Font.Medium
                            }
                            StyledText {
                                visible: text !== ""
                                width: parent.width
                                elide: Text.ElideRight
                                text: near.op !== "" ? "Pairing…"
                                    : near.err !== "" ? "Didn't pair — see below"
                                    : panel.bt.kindLabel(near.d.kind)
                                font.pixelSize: Config.Appearance.fs(12)
                                color: near.err !== "" && near.op === "" ? panel.danger : Config.Appearance.ink3
                            }
                        }
                        NetButton {
                            id: pairBtn
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            label: near.op !== "" ? "Cancel" : near.err !== "" ? "Try again" : "Pair"
                            primary: near.op === ""
                            onClicked: near.op !== "" ? panel.bt.cancelPairing(near.d.mac)
                                                      : panel.bt.pairDevice(near.d.mac)
                        }
                        HoverHandler { id: nearHover }
                    }
                    Line {
                        visible: near.err !== "" && near.op === ""
                        leftPadding: 60
                        rightPadding: 12
                        bottomPadding: 10
                        text: near.err
                        color: panel.danger
                    }
                }
            }
        }

        Line {
            visible: panel.bt.nearbyDevices.length === 0
            topPadding: 4
            text: panel.bt.discovering ? "Nothing ready to pair yet." : "Nothing found. Look again once the device is in pairing mode."
        }
        Line {
            visible: panel.bt.unnamedCount > 0
            topPadding: 4
            text: panel.bt.unnamedCount === 1
                  ? "1 device nearby without a name isn't shown — usually someone else's, or not in pairing mode."
                  : panel.bt.unnamedCount + " devices nearby without names aren't shown — usually other people's, or not in pairing mode."
        }
    }
}
