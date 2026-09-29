import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../icons"

// The login screen, as the lock screen and the greeter both draw it: the
// desktop's tint, the big clock, the card with your picture and the
// password field, sleep / restart / shut down in the corner. One file for
// both, so unlocking and logging in cannot drift apart.
//
// It draws and takes keys; what a password is checked against is the
// caller's. `auth` is any object with
//
//   entered   string   what has been typed          (read and written here)
//   status    string   the line under the field     (cleared here on typing)
//   failed    bool     the last attempt was refused (cleared here on typing)
//   busy      bool     checking; keys are ignored meanwhile
//   submit()           Enter
//   prompt, promptEcho  optional: a further question from PAM, asked in
//                       the field, shown in clear when promptEcho is set
//
// — the lock screen's surface and the greeter's GreeterState both are.
Item {
    id: view

    required property var auth
    // The screen the card and the keyboard are on. The others show the
    // ground and the clock.
    property bool primary: true

    // Who.
    property string userName: ""
    // Pictures to try, in order, as paths: the first that loads is shown;
    // with none, the name's initial on the accent.
    property var pictures: []
    property bool canStepUser: false
    signal stepUser(int delta)

    // What into — the greeter's session; empty hides it.
    property string sessionName: ""
    property bool canStepSession: false
    signal stepSession(int delta)

    // The line under the field; the caller may add to auth.status.
    property string statusText: auth.status || ""

    // Bottom left: a line of text, or a component in its place.
    property string cornerText: ""
    property Component corner: null

    property bool showPower: true
    signal power(string action)     // "suspend" | "reboot" | "poweroff"

    // Escape on an empty field — the greeter's preview uses it to leave.
    signal escapeOnEmpty()

    function shake() { shakeAnim.restart(); }

    property bool reveal: false

    // ── ground ────────────────────────────────────────────────────────────
    // The desktop's own tint, so locking and logging in read as the same
    // system rather than a different program taking over.
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
    // Keys go straight to the password: there is no field to click first.
    FocusScope {
        id: keys
        anchors.fill: parent
        focus: view.primary
        Component.onCompleted: if (view.primary) forceActiveFocus()

        Keys.onPressed: event => {
            const a = view.auth;
            event.accepted = true;
            if (a.busy) return;
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) a.submit();
            else if (event.key === Qt.Key_Backspace) { a.entered = a.entered.slice(0, -1); a.status = ""; }
            else if (event.key === Qt.Key_Escape) {
                if (a.entered === "") view.escapeOnEmpty();
                a.entered = ""; a.status = "";
            }
            else if (event.key === Qt.Key_Up && view.canStepUser) view.stepUser(-1);
            else if (event.key === Qt.Key_Down && view.canStepUser) view.stepUser(1);
            else if (event.key === Qt.Key_Tab && view.canStepSession)
                view.stepSession(event.modifiers & Qt.ShiftModifier ? -1 : 1);
            else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32) {
                a.entered += event.text;
                a.failed = false;
                a.status = "";
            } else event.accepted = false;
        }
    }

    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: view.primary ? 0 : -40
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
            visible: view.primary
            anchors.horizontalCenter: parent.horizontalCenter
            showSeam: false
            radius: Math.round(18 * Config.Appearance.rf)
            color: Config.Appearance.panel
            width: 360
            height: cardColumn.implicitHeight + 52

            // A refused password nudges the card, the standard cue.
            transform: Translate { id: shakeShift }
            SequentialAnimation {
                id: shakeAnim
                NumberAnimation { target: shakeShift; property: "x"; to: 9;  duration: Config.Appearance.anim(45) }
                NumberAnimation { target: shakeShift; property: "x"; to: -9; duration: Config.Appearance.anim(70) }
                NumberAnimation { target: shakeShift; property: "x"; to: 5;  duration: Config.Appearance.anim(60) }
                NumberAnimation { target: shakeShift; property: "x"; to: 0;  duration: Config.Appearance.anim(50) }
            }

            Column {
                id: cardColumn
                anchors.centerIn: parent
                spacing: 16

                // Picture, cut to a circle — a ClippingRectangle, as plain
                // clipping would crop it to a square.
                ClippingRectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 70
                    height: 70
                    radius: 35
                    color: Config.Appearance.accent

                    StyledText {
                        anchors.centerIn: parent
                        visible: picture.status !== Image.Ready
                        text: view.userName.charAt(0).toUpperCase()
                        font.pixelSize: Config.Appearance.fs(30)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.inkOnAccent
                    }
                    Image {
                        id: picture
                        property int attempt: 0
                        anchors.fill: parent
                        source: attempt < view.pictures.length ? "file://" + view.pictures[attempt] : ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize: Qt.size(140, 140)
                        visible: status === Image.Ready
                        asynchronous: true
                        // The next candidate when one is not there.
                        onStatusChanged: if (status === Image.Error) attempt++
                        Connections {
                            target: view
                            function onPicturesChanged() { picture.attempt = 0; }
                        }
                    }
                }

                // Name, with a way to the others when there are others.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6

                    Stepper {
                        visible: view.canStepUser
                        icon: "chevronLeft"
                        onStep: view.stepUser(-1)
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 220)
                        elide: Text.ElideRight
                        text: view.userName
                        font.pixelSize: Config.Appearance.fs(16)
                        font.weight: Font.DemiBold
                    }
                    Stepper {
                        visible: view.canStepUser
                        icon: "chevronRight"
                        onStep: view.stepUser(1)
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
                    border.color: view.auth.failed ? Config.Appearance.accent : Config.Appearance.edge
                    Behavior on border.color { ColorAnimation { duration: Config.Appearance.anim(160) } }

                    readonly property bool shown: view.reveal || (!!view.auth.prompt && !!view.auth.promptEcho)

                    StyledText {
                        id: typed
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: eye.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideLeft
                        text: field.shown ? view.auth.entered
                              : "•".repeat(Math.min(view.auth.entered.length, 24))
                        font.pixelSize: Config.Appearance.fs(field.shown ? 14 : 18)
                        font.letterSpacing: field.shown ? 0 : 5
                        color: Config.Appearance.ink2
                    }
                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 21
                        anchors.right: eye.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: view.auth.entered.length === 0
                        elide: Text.ElideRight
                        text: view.auth.busy ? "Checking…" : (view.auth.prompt || "Password")
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.Normal
                        color: Config.Appearance.ink3
                    }

                    // The text cursor: after what has been typed, blinking,
                    // and solid again at every key — while the field has the
                    // keyboard and is not busy checking.
                    Rectangle {
                        id: caret
                        readonly property real after: typed.text.length === 0 ? 0
                            : typed.contentWidth - (field.shown ? 0 : typed.font.letterSpacing) + 2
                        x: Math.min(typed.x + after, eye.x - 6)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 18
                        radius: 1
                        color: Config.Appearance.accent
                        visible: keys.activeFocus && !view.auth.busy

                        SequentialAnimation on opacity {
                            id: blink
                            running: caret.visible
                            loops: Animation.Infinite
                            PropertyAction { value: 1 }
                            PauseAnimation { duration: 530 }
                            PropertyAction { value: 0 }
                            PauseAnimation { duration: 530 }
                        }
                        Connections {
                            target: typed
                            function onTextChanged() { if (caret.visible) blink.restart(); }
                        }
                    }

                    // Show what was typed — a password typed blind is the
                    // commonest way to be locked out by Caps Lock.
                    Item {
                        id: eye
                        anchors.right: submitBtn.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 34
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "eye"
                            size: 16
                            monochrome: true
                            inkColor: view.reveal ? Config.Appearance.accent : Config.Appearance.ink3
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: view.reveal = !view.reveal }
                    }

                    Rectangle {
                        id: submitBtn
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 44
                        color: Config.Appearance.accent
                        opacity: view.auth.entered.length > 0 && !view.auth.busy ? 1 : 0.5
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "cornerDownLeft"
                            size: 18
                            inkColor: Config.Appearance.inkOnAccent
                            monochrome: true
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: view.auth.submit() }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 300
                    height: Math.max(14, implicitHeight)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: view.statusText
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.Normal
                    color: view.auth.failed ? Config.Appearance.accent : Config.Appearance.ink3
                }
            }
        }

        // ── session ───────────────────────────────────────────────────────
        // What you are logging into, under the card — the greeter's. Click,
        // or Tab, for the next one.
        Rectangle {
            visible: view.primary && view.sessionName !== ""
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
                    text: view.sessionName
                    font.pixelSize: Config.Appearance.fs(12.5)
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink2
                }
                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: view.canStepSession
                    name: "chevronDown"
                    size: 13
                    monochrome: true
                    inkColor: Config.Appearance.ink3
                }
            }
            HoverHandler { id: sessionHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: if (view.canStepSession) view.stepSession(1) }
        }
    }

    // ── corners ───────────────────────────────────────────────────────────
    Loader {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 28
        sourceComponent: view.corner ? view.corner : cornerLine
    }
    Component {
        id: cornerLine
        StyledText {
            text: view.cornerText
            font.pixelSize: Config.Appearance.fs(12)
            color: Config.Appearance.ink3
        }
    }

    Row {
        visible: view.primary && view.showPower
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
                TapHandler { onTapped: view.power(powerBtn.modelData.action) }
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
