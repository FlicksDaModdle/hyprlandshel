import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../icons"

// The login screen, as the lock screen and the greeter both draw it. One
// file for both, so unlocking and logging in cannot drift apart.
//
// Over your desktop's own wallpaper — the live video, the picture, the
// animation or the theme's gradient (Ground.qml) — a light clock high up,
// a frosted card with your picture, name and the password field, and along
// the bottom the corner line and sleep / restart / shut down. It comes in
// with a short rise and fade.
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
    // The screen this is drawn on, for the wallpaper.
    property var screen: null
    // Whether the wallpaper moves, and where its animation starts (the
    // desktop's point in it, for the lock screen).
    property bool animate: true
    property var wallPhase: null

    // Who.
    property string userName: ""
    // A line under the name: "Locked", say. Empty hides it.
    property string subtitle: ""
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

    // Bottom left: a line of text, or a component in its place. A
    // component should colour itself with view.fg3, which reads on any
    // wallpaper.
    property string cornerText: ""
    property Component corner: null

    property bool showPower: true
    signal power(string action)     // "suspend" | "reboot" | "poweroff"

    // Escape on an empty field — the greeter's preview uses it to leave.
    signal escapeOnEmpty()

    function shake() { shakeAnim.restart(); }

    property bool reveal: false

    readonly property var ap: Config.Appearance

    // ── ground ────────────────────────────────────────────────────────────
    Ground {
        id: ground
        anchors.fill: parent
        screen: view.screen
        running: view.animate
        phase: view.wallPhase
    }

    // Ink for what sits straight on the wallpaper. Over a picture, a video
    // or an animation it is white over a scrim, whatever the theme — the
    // theme's dark ink on someone's bright photo would vanish. Over the
    // theme's own gradient it is the theme's.
    readonly property bool vivid: ground.vivid
    readonly property color fg: vivid ? "#ffffff" : ap.ink
    readonly property color fg2: vivid ? Qt.rgba(1, 1, 1, 0.84) : ap.ink2
    readonly property color fg3: vivid ? Qt.rgba(1, 1, 1, 0.66) : ap.ink3
    // The small pills along the bottom and under the card: dark glass over a
    // picture, the theme's own panel over its gradient.
    readonly property color pill: vivid ? Qt.rgba(0, 0, 0, 0.30) : ap.panel
    readonly property color pillHover: vivid ? Qt.rgba(1, 1, 1, 0.16) : ap.sel
    readonly property color pillEdge: vivid ? Qt.rgba(1, 1, 1, 0.13) : ap.edge
    readonly property color pillInk: vivid ? "#ffffff" : ap.ink
    readonly property color pillInk2: vivid ? Qt.rgba(1, 1, 1, 0.82) : ap.ink2

    // The scrim: a little darker at the top behind the clock, more at the
    // bottom behind the corner line, clear between.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0;  color: Qt.rgba(0, 0, 0, view.vivid ? 0.34 : 0.04) }
            GradientStop { position: 0.38; color: Qt.rgba(0, 0, 0, view.vivid ? 0.10 : 0) }
            GradientStop { position: 0.72; color: Qt.rgba(0, 0, 0, view.vivid ? 0.16 : 0) }
            GradientStop { position: 1.0;  color: Qt.rgba(0, 0, 0, view.vivid ? 0.52 : 0.07) }
        }
    }

    // ── coming in ─────────────────────────────────────────────────────────
    property real shown: 0
    NumberAnimation on shown {
        from: 0; to: 1
        duration: Config.Appearance.anim(620)
        easing.type: Easing.OutCubic
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

    // ── clock ─────────────────────────────────────────────────────────────
    // High on the screen with the card, centred on the others: a light
    // weight at this size reads as a clock face rather than a heading.
    Column {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        y: (view.primary ? view.height * 0.13 : (view.height - height) / 2) + (1 - view.shown) * -14
        opacity: view.shown
        spacing: 0

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(tick.now, "dddd, d MMMM")
            font.pixelSize: view.ap.fs(15)
            font.weight: Font.DemiBold
            font.letterSpacing: 2.2
            font.capitalization: Font.AllUppercase
            color: view.fg2
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(tick.now, view.ap.clock24 ? "HH:mm" : "h:mm")
            font.pixelSize: view.ap.fs(132)
            font.weight: Font.Light
            font.letterSpacing: -3
            color: view.fg
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !view.ap.clock24
            text: Qt.formatDateTime(tick.now, "AP")
            font.pixelSize: view.ap.fs(13)
            font.weight: Font.DemiBold
            font.letterSpacing: 2
            color: view.fg3
        }
    }

    // ── the card ──────────────────────────────────────────────────────────
    Item {
        id: card
        visible: view.primary
        width: 392
        height: cardColumn.implicitHeight + 52
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: view.height * 0.1 + (1 - view.shown) * 26
        opacity: view.shown

        // The shell's panel radius, as the card is one of its panels.
        readonly property real radius: view.ap.rPanel

        // A refused password nudges the card, the standard cue.
        transform: Translate { id: shakeShift }
        SequentialAnimation {
            id: shakeAnim
            NumberAnimation { target: shakeShift; property: "x"; to: 10;  duration: Config.Appearance.anim(45) }
            NumberAnimation { target: shakeShift; property: "x"; to: -10; duration: Config.Appearance.anim(70) }
            NumberAnimation { target: shakeShift; property: "x"; to: 6;   duration: Config.Appearance.anim(60) }
            NumberAnimation { target: shakeShift; property: "x"; to: 0;   duration: Config.Appearance.anim(50) }
        }

        // Frosted the way the shell's panels are: the wallpaper behind it
        // blurred about as strongly as Hyprland blurs behind them
        // (Settings → Hyprland → blur size and passes, and none with blur
        // off), under the same panel colour the Translucency slider sets,
        // with the same hairline edge and accent seam (PanelSurface). The
        // blur goes through a Loader, so a Qt without QtQuick.Effects
        // shows the panel colour alone.
        //
        // Hyprland's blur is passes of a kernel `size` wide, each pass
        // reaching twice as far as the last; about size × (2^passes − 1)
        // pixels in all, which is what MultiEffect is asked for.
        readonly property real blurRadius: !view.ap.hyprBlur ? 0
            : Math.max(1, view.ap.hyprBlurSize) * (Math.pow(2, Math.max(1, view.ap.hyprBlurPasses)) - 1) * 1.6
        Loader {
            anchors.fill: parent
            active: card.blurRadius > 0
            source: "BlurBackdrop.qml"
            onLoaded: {
                item.sourceItem = ground;
                item.radius = Qt.binding(() => card.radius);
                item.blurMax = 64;
                item.amount = Qt.binding(() => Math.min(1, card.blurRadius / 64));
                item.sampleRect = Qt.binding(() => Qt.rect(card.x + shakeShift.x, card.y, card.width, card.height));
            }
        }
        PanelSurface {
            anchors.fill: parent
            radius: card.radius
        }

        Column {
            id: cardColumn
            anchors.centerIn: parent
            spacing: 14

            // Picture, in a ring of the accent, cut to a circle — a
            // ClippingRectangle, as plain clipping would crop it square.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 92
                height: 92

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2.5
                    border.color: view.ap.accent
                }
                ClippingRectangle {
                    anchors.centerIn: parent
                    width: 80
                    height: 80
                    radius: 40
                    color: view.ap.accent

                    StyledText {
                        anchors.centerIn: parent
                        visible: picture.status !== Image.Ready
                        text: view.userName.charAt(0).toUpperCase()
                        font.pixelSize: view.ap.fs(34)
                        font.weight: Font.DemiBold
                        color: view.ap.inkOnAccent
                    }
                    Image {
                        id: picture
                        property int attempt: 0
                        anchors.fill: parent
                        source: attempt < view.pictures.length ? "file://" + view.pictures[attempt] : ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize: Qt.size(160, 160)
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
            }

            // Name, with a way to the others when there are others.
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 3

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
                        width: Math.min(implicitWidth, 240)
                        elide: Text.ElideRight
                        text: view.userName
                        font.pixelSize: view.ap.fs(20)
                        font.weight: Font.DemiBold
                        color: view.ap.ink
                    }
                    Stepper {
                        visible: view.canStepUser
                        icon: "chevronRight"
                        onStep: view.stepUser(1)
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: view.subtitle !== ""
                    spacing: 6
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "lock"
                        size: 12
                        monochrome: true
                        inkColor: view.ap.ink3
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: view.subtitle
                        font.pixelSize: view.ap.fs(12.5)
                        color: view.ap.ink3
                    }
                }
            }

            Item { width: 1; height: 2 }

            // The field: a pill, with the accent's round button at its end.
            Rectangle {
                id: field
                anchors.horizontalCenter: parent.horizontalCenter
                width: 320
                height: 50
                radius: height / 2
                color: view.ap.hover
                border.width: 1.5
                border.color: view.auth.failed ? view.ap.accent
                    : (keys.activeFocus && view.auth.entered.length > 0)
                      ? Qt.rgba(view.ap.accent.r, view.ap.accent.g, view.ap.accent.b, 0.55)
                      : view.ap.edge
                Behavior on border.color { ColorAnimation { duration: Config.Appearance.anim(160) } }

                readonly property bool shown: view.reveal || (!!view.auth.prompt && !!view.auth.promptEcho)

                StyledText {
                    id: typed
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.right: eye.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideLeft
                    text: field.shown ? view.auth.entered
                          : "•".repeat(Math.min(view.auth.entered.length, 22))
                    font.pixelSize: view.ap.fs(field.shown ? 14 : 18)
                    font.letterSpacing: field.shown ? 0 : 5
                    color: view.ap.ink
                }
                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: eye.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: view.auth.entered.length === 0
                    elide: Text.ElideRight
                    text: view.auth.busy ? "Checking…" : (view.auth.prompt || "Password")
                    font.pixelSize: view.ap.fs(13.5)
                    color: view.ap.ink3
                }

                // The text cursor: after what has been typed, blinking, and
                // solid again at every key — while the field has the
                // keyboard and is not busy checking.
                Rectangle {
                    id: caret
                    readonly property real after: typed.text.length === 0 ? 0
                        : typed.contentWidth - (field.shown ? 0 : typed.font.letterSpacing) + 2
                    x: Math.min(typed.x + after, eye.x - 6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: 20
                    radius: 1
                    color: view.ap.accent
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
                    anchors.rightMargin: 2
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 36
                    MonoIcon {
                        anchors.centerIn: parent
                        name: "eye"
                        size: 17
                        monochrome: true
                        inkColor: view.reveal ? view.ap.accent : view.ap.ink3
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: view.reveal = !view.reveal }
                }

                Rectangle {
                    id: submitBtn
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 38
                    height: 38
                    radius: 19
                    color: view.ap.accent
                    opacity: view.auth.entered.length > 0 && !view.auth.busy ? 1 : 0.45
                    scale: submitHover.hovered && opacity === 1 ? 1.06 : 1
                    Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(140) } }
                    Behavior on scale { NumberAnimation { duration: Config.Appearance.anim(120) } }

                    MonoIcon {
                        anchors.centerIn: parent
                        visible: !view.auth.busy
                        name: "chevronRight"
                        size: 18
                        inkColor: view.ap.inkOnAccent
                        monochrome: true
                    }
                    // Checking: a ring going round where the arrow was.
                    Rectangle {
                        anchors.centerIn: parent
                        visible: view.auth.busy
                        width: 16
                        height: 16
                        radius: 8
                        color: "transparent"
                        border.width: 2
                        border.color: view.ap.inkOnAccent
                        opacity: 0.9
                        Rectangle {
                            width: 6; height: 6; radius: 3
                            color: view.ap.accent
                            x: -1; y: -1
                        }
                        RotationAnimation on rotation {
                            running: view.auth.busy
                            from: 0; to: 360
                            duration: 900
                            loops: Animation.Infinite
                        }
                    }
                    HoverHandler { id: submitHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: view.auth.submit() }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 320
                height: Math.max(16, implicitHeight)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: view.statusText
                font.pixelSize: view.ap.fs(12)
                color: view.auth.failed ? view.ap.accent : view.ap.ink3
            }
        }
    }

    // ── session ───────────────────────────────────────────────────────────
    // What you are logging into, under the card — the greeter's. Click, or
    // Tab, for the next one.
    Rectangle {
        visible: view.primary && view.sessionName !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: card.bottom
        anchors.topMargin: 16
        opacity: view.shown
        height: 34
        width: sessionRow.implicitWidth + 30
        radius: height / 2
        color: sessionHover.hovered ? Qt.tint(view.pill, view.pillHover) : view.pill
        border.width: 1
        border.color: view.pillEdge

        Row {
            id: sessionRow
            anchors.centerIn: parent
            spacing: 8
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "monitor"
                size: 15
                monochrome: true
                inkColor: view.pillInk
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: view.sessionName
                font.pixelSize: view.ap.fs(12.5)
                font.weight: Font.DemiBold
                color: view.pillInk
            }
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: view.canStepSession
                name: "chevronDown"
                size: 13
                monochrome: true
                inkColor: view.pillInk2
            }
        }
        HoverHandler { id: sessionHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: if (view.canStepSession) view.stepSession(1) }
    }

    // ── along the bottom ──────────────────────────────────────────────────
    Loader {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 32
        anchors.bottomMargin: 30
        opacity: view.shown
        sourceComponent: view.corner ? view.corner : cornerLine
    }
    Component {
        id: cornerLine
        StyledText {
            text: view.cornerText
            font.pixelSize: view.ap.fs(12.5)
            font.weight: Font.Medium
            color: view.fg3
        }
    }

    // Sleep, restart, shut down: round buttons on a dark pill, so they
    // read on any wallpaper.
    Rectangle {
        visible: view.primary && view.showPower
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 26
        anchors.bottomMargin: 22
        opacity: view.shown
        width: powerRow.implicitWidth + 12
        height: 52
        radius: height / 2
        color: view.pill
        border.width: 1
        border.color: view.pillEdge

        Row {
            id: powerRow
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: [{ icon: "moon", label: "Sleep", action: "suspend" },
                        { icon: "rotateCw", label: "Restart", action: "reboot" },
                        { icon: "power", label: "Shut down", action: "poweroff" }]

                Rectangle {
                    id: powerBtn
                    required property var modelData
                    width: 40
                    height: 40
                    radius: 20
                    color: hover.hovered ? view.pillHover : "transparent"
                    Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }
                    MonoIcon {
                        anchors.centerIn: parent
                        name: powerBtn.modelData.icon
                        size: 18
                        monochrome: true
                        inkColor: hover.hovered ? view.pillInk : view.pillInk2
                    }
                    // Its name, in a small pill above, while pointed at.
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 14
                        visible: hover.hovered
                        width: tip.implicitWidth + 18
                        height: 26
                        radius: 13
                        color: Qt.rgba(0, 0, 0, 0.55)
                        StyledText {
                            id: tip
                            anchors.centerIn: parent
                            text: powerBtn.modelData.label
                            font.pixelSize: view.ap.fs(11.5)
                            font.weight: Font.Medium
                            color: "#ffffff"
                        }
                    }
                    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: view.power(powerBtn.modelData.action) }
                }
            }
        }
    }

    // ‹ and › beside the name.
    component Stepper: Rectangle {
        id: stepper
        property string icon: ""
        signal step()
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: 28
        height: 28
        radius: 14
        color: stepHover.hovered ? view.ap.sel : "transparent"
        MonoIcon {
            anchors.centerIn: parent
            name: stepper.icon
            size: 15
            monochrome: true
            inkColor: view.ap.ink2
        }
        HoverHandler { id: stepHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: stepper.step() }
    }
}
