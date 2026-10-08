import QtQuick
import "../../config" as Config
import "../common"

// The top of Settings → Appearance: the shell in miniature, drawn from the
// settings below it, so every change shows here as it is made — the theme,
// the accent, how much of the desktop comes through the surfaces, and how
// round everything is.
//
// A desktop with colour in it, so translucency has something to show; a
// bar along the top, a window, a panel with the accent seam and a switch
// in it, and the dock.
Rectangle {
    id: root

    readonly property var ap: Config.Appearance
    // Everything is drawn at this fraction of its real size.
    readonly property real k: 0.42

    implicitHeight: 200
    radius: ap.r
    clip: true
    color: ap.ground

    // ── the desktop ───────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.tint(root.ap.ground, Qt.rgba(root.ap.accent.r, root.ap.accent.g, root.ap.accent.b, 0.30)) }
            GradientStop { position: 1; color: Qt.tint(root.ap.ground, Qt.rgba(0.30, 0.45, 0.95, root.ap.dark ? 0.22 : 0.16)) }
        }
    }
    Rectangle {
        x: parent.width * 0.52; y: parent.height * 0.18
        width: parent.width * 0.42; height: width
        radius: width / 2
        color: Qt.rgba(root.ap.accent.r, root.ap.accent.g, root.ap.accent.b, 0.55)
    }
    Rectangle {
        x: parent.width * 0.04; y: parent.height * 0.52
        width: parent.width * 0.30; height: width
        radius: width / 2
        color: Qt.rgba(0.35, 0.55, 1.0, root.ap.dark ? 0.35 : 0.28)
    }

    // ── the bar ───────────────────────────────────────────────────────────
    Rectangle {
        id: bar
        x: 0; y: 0
        width: parent.width
        height: Math.round(root.ap.barHeight * root.k)
        color: root.ap.panel
        Row {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Rectangle { width: 9; height: 9; radius: 4.5; color: root.ap.accent }
            Repeater { model: 3; Rectangle { width: 5; height: 5; radius: 2.5; anchors.verticalCenter: parent.verticalCenter; color: root.ap.ink3 } }
            Item { width: 8; height: 1 }
            Rectangle { width: 40; height: 5; radius: 2.5; anchors.verticalCenter: parent.verticalCenter; color: root.ap.ink }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater { model: 3; Rectangle { width: 12; height: 5; radius: 2.5; color: root.ap.ink2 } }
            Rectangle { width: 22; height: 5; radius: 2.5; color: root.ap.ink }
        }
    }

    // ── a window ──────────────────────────────────────────────────────────
    Rectangle {
        id: win
        x: parent.width * 0.06
        y: bar.height + 12
        width: parent.width * 0.50
        height: parent.height - bar.height - 52
        radius: Math.max(0, root.ap.rWin * root.k * 1.4)
        color: root.ap.sheet
        border.width: 1
        border.color: root.ap.edge
        clip: true
        Rectangle {
            width: parent.width; height: 18
            color: "transparent"
            Rectangle { x: 8; anchors.verticalCenter: parent.verticalCenter; width: 3; height: 8; radius: 1.5; color: root.ap.accent }
            Rectangle { x: 16; anchors.verticalCenter: parent.verticalCenter; width: 34; height: 4; radius: 2; color: root.ap.ink }
            Row {
                anchors.right: parent.right; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                Repeater { model: 3; Rectangle { width: 5; height: 5; radius: 1; color: root.ap.ink3 } }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.ap.rule }
        }
        Column {
            x: 10; y: 26
            spacing: 6
            Repeater {
                model: [0.8, 0.55, 0.7, 0.4, 0.62]
                Rectangle {
                    required property var modelData
                    required property int index
                    width: (win.width - 20) * modelData; height: 4; radius: 2
                    color: index === 0 ? root.ap.ink : root.ap.ink3
                    opacity: index === 0 ? 1 : 0.7
                }
            }
        }
        // A selected row, in the accent.
        Rectangle {
            x: 8; y: win.height - 26
            width: win.width - 16; height: 16
            radius: Math.max(0, root.ap.rSm * root.k * 1.2)
            color: Qt.rgba(root.ap.accent.r, root.ap.accent.g, root.ap.accent.b, 0.18)
            Rectangle { x: 6; anchors.verticalCenter: parent.verticalCenter; width: 40; height: 4; radius: 2; color: root.ap.accent }
        }
    }

    // ── a panel, as the control center drops one ──────────────────────────
    Rectangle {
        id: panel
        anchors.right: parent.right
        anchors.rightMargin: parent.width * 0.05
        y: bar.height + 8
        width: parent.width * 0.30
        height: 96
        radius: Math.max(0, root.ap.rPanel * root.k * 1.3)
        color: root.ap.panel
        border.width: 1
        border.color: root.ap.edge
        clip: true
        // The seam every panel carries.
        Row {
            width: parent.width
            Rectangle { width: 18; height: 2; color: root.ap.accent }
            Rectangle { width: parent.width - 18; height: 2; color: root.ap.seam }
        }
        Grid {
            x: 8; y: 12
            columns: 2
            spacing: 6
            Repeater {
                model: 4
                Rectangle {
                    required property int index
                    width: (panel.width - 22) / 2; height: 22
                    radius: Math.max(0, root.ap.rSm * root.k * 1.2)
                    color: index === 0 ? root.ap.accent : root.ap.hover
                    Rectangle { x: 6; anchors.verticalCenter: parent.verticalCenter; width: 14; height: 4; radius: 2
                                color: parent.index === 0 ? root.ap.inkOnAccent : root.ap.ink2 }
                }
            }
        }
        // A slider.
        Rectangle {
            x: 8; y: panel.height - 18
            width: panel.width - 16; height: 7
            radius: 3.5
            color: root.ap.hover
            Rectangle { width: parent.width * 0.62; height: parent.height; radius: 3.5; color: root.ap.accent }
        }
    }

    // ── the dock ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        width: dockRow.implicitWidth + 14
        height: 28
        radius: Math.max(0, root.ap.r * root.k * 1.2)
        color: root.ap.panel
        border.width: 1
        border.color: root.ap.edge
        Row {
            id: dockRow
            anchors.centerIn: parent
            spacing: 5
            Repeater {
                model: 7
                Rectangle {
                    required property int index
                    width: 18; height: 18
                    radius: Math.max(0, root.ap.rSm * root.k)
                    color: index === 2 ? root.ap.sel : root.ap.hover
                    Rectangle {
                        anchors.centerIn: parent
                        width: 8; height: 8; radius: 2
                        color: parent.index === 2 ? root.ap.accent : root.ap.ink2
                        opacity: parent.index === 2 ? 1 : 0.8
                    }
                }
            }
        }
    }

    // The edge, over everything.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: 1
        border.color: root.ap.rule
    }
}
