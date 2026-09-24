import QtQuick
import Hyprterm

// The chrome, from the concept: a 40px title bar carrying the accent
// bead, the app's own icon, the name and the directory, then the three
// window buttons — and the terminal itself under it, inset by the
// padding the design asks for.
Rectangle {
    id: frame

    required property var host
    required property var term

    radius: frame.host.maximised ? 0 : Appearance.rPanel
    color: Appearance.bg
    border.width: 1
    border.color: Appearance.edge
    antialiasing: true
    clip: true

    // ── title bar ─────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 40

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0
            property bool moving: false
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moving = false; }
            onReleased: moving = false
            // Handed to the compositor once the pointer has travelled, so
            // the double click that maximises still gets through.
            onPositionChanged: mouse => {
                if (!pressed || moving) return;
                if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4) return;
                moving = true;
                frame.host.moveTo();
            }
            onDoubleClicked: frame.host.toggleMaximised()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 16
                radius: 2
                color: Appearance.accent
            }

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "terminal"
                size: 15
                inkColor: Appearance.ink2
                monochrome: true
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Terminal"
                font.pixelSize: Appearance.fs(12.5)
                font.weight: Font.DemiBold
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: frame.term.cwd !== "" ? Appearance.pretty(frame.term.cwd) : ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth, frame.width - 320)
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Repeater {
                model: [
                    { glyph: "minus",  danger: false },
                    { glyph: "square", danger: false },
                    { glyph: "x",      danger: true }
                ]

                Rectangle {
                    required property var modelData
                    required property int index
                    width: 28
                    height: 28
                    radius: Appearance.rSm
                    color: !hover.hovered ? "transparent"
                         : (modelData.danger ? Appearance.accent : Appearance.hover)

                    MonoIcon {
                        anchors.centerIn: parent
                        name: parent.modelData.glyph
                        size: 13
                        inkColor: hover.hovered && parent.modelData.danger
                                  ? Appearance.inkOnAccent : Appearance.ink2
                        monochrome: true
                    }

                    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            if (parent.index === 0) frame.host.minimise();
                            else if (parent.index === 1) frame.host.toggleMaximised();
                            else frame.host.close();
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Appearance.rule
        }
    }

    // ── the terminal ──────────────────────────────────────────────────────
    TermView {
        id: view
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        anchors.topMargin: 16
        anchors.bottomMargin: 20

        term: frame.term
        fontFamily: Appearance.monoFamily
        fontSize: Appearance.monoSize
        lineHeight: Appearance.monoLineHeight
        selectionColor: Qt.rgba(Appearance.accent.r, Appearance.accent.g,
                                Appearance.accent.b, 0.30)
        cursorColor: Appearance.accent
        focused: frame.host.active

        Component.onCompleted: forceActiveFocus()
    }

    // Clicking anywhere in the body puts the keyboard back in the grid,
    // which is what a terminal window is for.
    MouseArea {
        anchors.fill: view
        acceptedButtons: Qt.NoButton
        onPressed: view.forceActiveFocus()
    }
}
