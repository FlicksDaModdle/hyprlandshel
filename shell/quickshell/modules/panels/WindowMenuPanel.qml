import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The window menu: real Hyprland actions for the focused window, plus the
// mockup's snap-layout grid, inlined at the foot so it's one interaction
// rather than two.
//
// Lives in the panel layer with the other dropdowns, so it dismisses on
// click-away and can't be open at the same time as the control center.
PanelSurface {
    id: root

    // Screen dimensions, for working out where a snapped window should go.
    required property real screenWidth
    required property real screenHeight

    showSeam: false

    readonly property var client: Services.Compositor.activeClient

    implicitWidth: 262
    implicitHeight: column.implicitHeight + 12

    readonly property var actions: [
        { n: "Fullscreen",                 k: "super F",   cmd: "fullscreen 0" },
        { n: "Maximize",                   k: "super ⇧ F", cmd: "fullscreen 1" },
        { n: "Float",                      k: "super V",   cmd: "togglefloating" },
        { n: "Pin",                        k: "super ⇧ P", cmd: "pin" },
        { n: "Center",                     k: "",          cmd: "centerwindow", rule: true },
        { n: "Toggle split",               k: "super J",   cmd: "togglesplit" },
        { n: "Move to next workspace",     k: "",          cmd: "movetoworkspace +1", rule: true },
        { n: "Move to previous workspace", k: "",          cmd: "movetoworkspace -1" },
        { n: "Close window",               k: "super Q",   cmd: "killactive", rule: true }
    ]

    // Snap targets as fractions of the usable area. `cells` drives the
    // mini-diagram so each tile shows the shape it produces.
    readonly property var snaps: [
        { fx: 0,    fy: 0,    fw: 0.5, fh: 1 },
        { fx: 0.5,  fy: 0,    fw: 0.5, fh: 1 },
        { fx: 0,    fy: 0,    fw: 1,   fh: 0.5 },
        { fx: 0,    fy: 0.5,  fw: 1,   fh: 0.5 },
        { fx: 0,    fy: 0,    fw: 1,   fh: 1 },
        { fx: 0.15, fy: 0.12, fw: 0.7, fh: 0.76 }
    ]

    // Usable area: the output minus the bar's exclusive zone and the dock's
    // gutter, with the same 8px gap hyprland.lua gives tiled windows so a
    // snapped window lines up with its neighbours.
    readonly property real gap: 8
    readonly property real usableX: gap
    readonly property real usableY: Config.Appearance.barHeight + gap
    readonly property real usableW: Math.max(160, screenWidth - gap * 2)
    readonly property real usableH: Math.max(160, screenHeight - Config.Appearance.barHeight - gap * 2
        - (Config.Appearance.dockLeft ? 0 : Config.Appearance.dockPanelBreadth + Config.Appearance.dockEdgeGap))

    function run(cmd) {
        Config.UiState.closeAll();
        Services.Compositor.dispatch(cmd);
    }

    function snapTo(s) {
        if (!client) return;
        const addr = "address:" + client.address;
        const x = Math.round(usableX + usableW * s.fx);
        const y = Math.round(usableY + usableH * s.fy);
        const w = Math.round(usableW * s.fw);
        const h = Math.round(usableH * s.fh);
        Config.UiState.closeAll();
        // Snapping only means anything for a floating window, so float it
        // first if it isn't already.
        if (!client.floating) Services.Compositor.dispatch("setfloating " + addr);
        Services.Compositor.dispatch("resizewindowpixel exact " + w + " " + h + "," + addr);
        Services.Compositor.dispatch("movewindowpixel exact " + x + " " + y + "," + addr);
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        spacing: 0

        Repeater {
            model: root.actions

            Item {
                id: row
                required property var modelData
                width: column.width
                height: modelData.rule ? 34 : 29

                Rectangle {
                    visible: row.modelData.rule
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    width: parent.width
                    height: 1
                    color: Config.Appearance.rule
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 29
                    radius: Config.Appearance.rSm
                    color: rowHover.hovered ? Config.Appearance.accent : "transparent"

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.n
                        font.pixelSize: 12
                        color: rowHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink
                    }
                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.k
                        font.pixelSize: 11
                        font.weight: Font.Normal
                        color: rowHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink3
                    }
                }

                HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.run(row.modelData.cmd) }
            }
        }

        Item { width: 1; height: 8 }

        Rectangle { width: column.width; height: 1; color: Config.Appearance.rule }

        StyledText {
            text: "Snap layout"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            color: Config.Appearance.ink3
            topPadding: 10
            bottomPadding: 8
            leftPadding: 5
        }

        Grid {
            columns: 3
            spacing: 6

            Repeater {
                model: root.snaps

                Rectangle {
                    id: snapTile
                    required property var modelData
                    width: 76
                    height: 48
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.hover
                    border.width: 1
                    border.color: snapHover.hovered ? Config.Appearance.accent : "transparent"

                    // The shaded block is the shape this tile produces.
                    Rectangle {
                        x: 4 + (snapTile.width - 8) * snapTile.modelData.fx
                        y: 4 + (snapTile.height - 8) * snapTile.modelData.fy
                        width: (snapTile.width - 8) * snapTile.modelData.fw
                        height: (snapTile.height - 8) * snapTile.modelData.fh
                        radius: 3
                        color: Config.Appearance.accent
                        opacity: 0.5
                    }

                    HoverHandler { id: snapHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.snapTo(snapTile.modelData) }
                }
            }
        }

        Item { width: 1; height: 4 }
    }
}
