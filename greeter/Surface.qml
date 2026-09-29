import QtQuick
import Quickshell.Widgets
import "shell/config" as Config
import "shell/modules/common"
import "shell/modules/icons"

// What one screen of the greeter shows. It is the lock screen's design —
// the desktop's own tint, the big clock, the card with the shake on a
// wrong password — so logging in and unlocking look like one system.
//
// Every screen gets the ground and the clock; only the primary one gets the
// card, since there is one keyboard and one person typing into it.
Item {
    id: surface

    required property var greeter
    property bool primary: true

    readonly property var g: greeter
    property bool reveal: false

    // ── ground ────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: Config.Appearance.tintSpec.a }
            GradientStop { position: 1; color: Config.Appearance.tintSpec.b }
        }
    }

    Timer {
        id: tick
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        property date now: new Date()
        onTriggered: now = new Date()
    }

    // ── typing ────────────────────────────────────────────────────────────
    // Keys go straight to the password, as on the lock screen: there is no
    // field to click into first.
    FocusScope {
        id: keys
        anchors.fill: parent
        focus: surface.primary
        Component.onCompleted: if (surface.primary) forceActiveFocus()

        Keys.onPressed: event => {
            const g = surface.g;
            event.accepted = true;
            if (g.busy) return;
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) g.submit();
            else if (event.key === Qt.Key_Backspace) { g.entered = g.entered.slice(0, -1); g.status = ""; }
            else if (event.key === Qt.Key_Escape) {
                // A preview in your own session takes the whole screen and
                // the keyboard, so it needs a way out: Escape on an empty
                // field. Under greetd there is nowhere to go.
                if (g.preview && g.entered === "") Qt.quit();
                g.entered = ""; g.status = "";
            }
            else if (event.key === Qt.Key_Up && g.users.length > 1)
                g.pickUser((g.userIndex - 1 + g.users.length) % g.users.length);
            else if (event.key === Qt.Key_Down && g.users.length > 1)
                g.pickUser((g.userIndex + 1) % g.users.length);
            else if (event.key === Qt.Key_Tab && g.sessions.length > 1)
                g.sessionIndex = (g.sessionIndex + (event.modifiers & Qt.ShiftModifier ? g.sessions.length - 1 : 1)) % g.sessions.length;
            else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32) {
                g.entered += event.text;
                g.failed = false;
                g.status = "";
            } else event.accepted = false;
        }
    }

    Connections {
        target: surface.g
        function onRejected() { if (surface.primary) shake.restart(); }
    }

    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: surface.primary ? 0 : -40
        spacing: 34

        // ── clock ─────────────────────────────────────────────────────────
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDateTime(tick.now, Config.Appearance.clock24 ? "HH:mm" : "h:mm AP")
                font.pixelSize: Config.Appearance.fs(116)
                font.weight: Font.Bold
                font.letterSpacing: -4
                color: Config.Appearance.ink
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDate(tick.now, "dddd d MMMM yyyy")
                font.pixelSize: Config.Appearance.fs(17)
                color: Config.Appearance.ink2
            }
        }

        // ── the card ──────────────────────────────────────────────────────
        PanelSurface {
            id: card
            visible: surface.primary
            anchors.horizontalCenter: parent.horizontalCenter
            showSeam: false
            radius: Math.round(18 * Config.Appearance.rf)
            color: Config.Appearance.panel
            width: 360
            height: cardColumn.implicitHeight + 52

            transform: Translate { id: shakeShift }
            SequentialAnimation {
                id: shake
                NumberAnimation { target: shakeShift; property: "x"; to: 9;  duration: Config.Appearance.anim(45) }
                NumberAnimation { target: shakeShift; property: "x"; to: -9; duration: Config.Appearance.anim(70) }
                NumberAnimation { target: shakeShift; property: "x"; to: 5;  duration: Config.Appearance.anim(60) }
                NumberAnimation { target: shakeShift; property: "x"; to: 0;  duration: Config.Appearance.anim(50) }
            }

            Column {
                id: cardColumn
                anchors.centerIn: parent
                spacing: 16

                // Picture: AccountsService's, or the initial on the accent.
                // A ClippingRectangle, as plain clipping would crop the
                // picture to a square rather than to the circle.
                ClippingRectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 70
                    height: 70
                    radius: 35
                    color: Config.Appearance.accent

                    StyledText {
                        anchors.centerIn: parent
                        visible: avatar.status !== Image.Ready
                        text: surface.g.user ? surface.g.user.display.charAt(0).toUpperCase() : ""
                        font.pixelSize: Config.Appearance.fs(30)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.inkOnAccent
                    }
                    Image {
                        id: avatar
                        anchors.fill: parent
                        source: surface.g.user ? "file://" + surface.g.user.icon : ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize: Qt.size(140, 140)
                        visible: status === Image.Ready
                        asynchronous: true
                    }
                }

                // Name, with a way to the others when there are others.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6

                    Stepper {
                        visible: surface.g.users.length > 1
                        icon: "chevronLeft"
                        onStep: surface.g.pickUser((surface.g.userIndex - 1 + surface.g.users.length) % surface.g.users.length)
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 220)
                        elide: Text.ElideRight
                        text: surface.g.user ? surface.g.user.display
                              : (surface.g.users.length === 0 ? "No users found" : "")
                        font.pixelSize: Config.Appearance.fs(16)
                        font.weight: Font.DemiBold
                    }
                    Stepper {
                        visible: surface.g.users.length > 1
                        icon: "chevronRight"
                        onStep: surface.g.pickUser((surface.g.userIndex + 1) % surface.g.users.length)
                    }
                }

                // The field. Clipped to its own rounded shape, so the
                // accent button at its end takes the same corners.
                ClippingRectangle {
                    id: field
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 300
                    height: 44
                    radius: Config.Appearance.rCard
                    color: Config.Appearance.hover
                    border.width: 1
                    border.color: surface.g.failed ? Config.Appearance.accent : Config.Appearance.edge
                    Behavior on border.color { ColorAnimation { duration: Config.Appearance.anim(160) } }

                    readonly property bool shown: surface.reveal || (surface.g.prompt !== "" && surface.g.promptEcho)

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: eye.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideLeft
                        text: field.shown ? surface.g.entered
                              : "•".repeat(Math.min(surface.g.entered.length, 24))
                        font.pixelSize: Config.Appearance.fs(field.shown ? 14 : 18)
                        font.letterSpacing: field.shown ? 0 : 5
                        color: Config.Appearance.ink2
                    }
                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: eye.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: surface.g.entered.length === 0
                        elide: Text.ElideRight
                        text: surface.g.busy ? "Checking…" : (surface.g.prompt || "Password")
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.Normal
                        color: Config.Appearance.ink3
                    }

                    // Show what was typed — a password typed blind is the
                    // commonest way to be locked out by a stuck Caps Lock.
                    Item {
                        id: eye
                        anchors.right: submit.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 34
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "eye"
                            size: 16
                            monochrome: true
                            inkColor: surface.reveal ? Config.Appearance.accent : Config.Appearance.ink3
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: surface.reveal = !surface.reveal }
                    }

                    Rectangle {
                        id: submit
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 44
                        color: Config.Appearance.accent
                        opacity: surface.g.entered.length > 0 && !surface.g.busy ? 1 : 0.5
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "cornerDownLeft"
                            size: 18
                            inkColor: Config.Appearance.inkOnAccent
                            monochrome: true
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: surface.g.submit() }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 300
                    height: Math.max(14, implicitHeight)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: surface.g.status
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.Normal
                    color: surface.g.failed ? Config.Appearance.accent : Config.Appearance.ink3
                }
            }
        }

        // ── session ───────────────────────────────────────────────────────
        // What you are logging into, under the card. Click, or Tab, for the
        // next one.
        Rectangle {
            visible: surface.primary && surface.g.sessions.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            height: 32
            width: sessionRow.implicitWidth + 28
            radius: height / 2
            color: sessionHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
            border.width: 1
            border.color: Config.Appearance.edge

            Row {
                id: sessionRow
                anchors.centerIn: parent
                spacing: 8
                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "monitor"
                    size: 15
                    monochrome: true
                    inkColor: Config.Appearance.ink2
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: surface.g.session ? surface.g.session.name : ""
                    font.pixelSize: Config.Appearance.fs(12.5)
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink2
                }
                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: surface.g.sessions.length > 1
                    name: "chevronDown"
                    size: 13
                    monochrome: true
                    inkColor: Config.Appearance.ink3
                }
            }
            HoverHandler { id: sessionHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: if (surface.g.sessions.length > 1)
                    surface.g.sessionIndex = (surface.g.sessionIndex + 1) % surface.g.sessions.length
            }
        }
    }

    // ── corners ───────────────────────────────────────────────────────────
    StyledText {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 28
        text: surface.g.hostname + (surface.g.preview ? "  ·  preview" : "")
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    Row {
        visible: surface.primary
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        spacing: 6

        Repeater {
            model: [{ icon: "moon", label: "Sleep", action: "suspend" },
                    { icon: "rotateCw", label: "Restart", action: "reboot" },
                    { icon: "power", label: "Shut down", action: "poweroff" }]

            Rectangle {
                id: powerBtn
                required property var modelData
                width: 40
                height: 40
                radius: Config.Appearance.rCard
                color: hover.hovered ? Config.Appearance.sel : "transparent"
                MonoIcon {
                    anchors.centerIn: parent
                    name: powerBtn.modelData.icon
                    size: 18
                    monochrome: true
                    inkColor: hover.hovered ? Config.Appearance.ink : Config.Appearance.ink2
                }
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 6
                    visible: hover.hovered
                    text: powerBtn.modelData.label
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink2
                }
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: surface.g.power(powerBtn.modelData.action) }
            }
        }
    }

    // ‹ and › beside the name.
    component Stepper: Rectangle {
        id: stepper
        property string icon: ""
        signal step()
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: 26
        height: 26
        radius: 13
        color: stepHover.hovered ? Config.Appearance.sel : "transparent"
        MonoIcon {
            anchors.centerIn: parent
            name: stepper.icon
            size: 14
            monochrome: true
            inkColor: Config.Appearance.ink2
        }
        HoverHandler { id: stepHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: stepper.step() }
    }
}
