import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The bar's window menu.
//
// The mockup shows a per-app File/Edit/View menu bar. That needs a global
// menu protocol, and Wayland has none — no client on Hyprland exports its
// menus, so rendering File/Edit/View here would be drawing buttons that
// can't do anything. What *is* real at this level is the compositor's own
// window management, so this keeps the mockup's affordance (a menu button
// beside the app name, same type, same dropdown) and fills it with actions
// that actually run: the mockup's own "Window" menu, plus its snap-layout
// popover.
Item {
    id: root

    required property var barWindow

    readonly property var client: Services.Compositor.activeClient
    readonly property bool hasClient: client !== null
    property bool open: false

    implicitWidth: label.implicitWidth + 20
    implicitHeight: 26
    opacity: hasClient ? 1 : 0.45

    // Close when a panel takes over, or when the window goes away.
    Connections {
        target: Config.UiState
        function onAnyPanelOpenChanged() { if (Config.UiState.anyPanelOpen) root.open = false; }
    }
    onHasClientChanged: if (!hasClient) open = false;

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rSm
        color: root.open ? Config.Appearance.sel
             : (hover.hovered && root.hasClient ? Config.Appearance.hover : "transparent")
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    StyledText {
        id: label
        anchors.centerIn: parent
        text: "Window"
        font.pixelSize: 12.5
        color: Config.Appearance.ink
    }

    HoverHandler { id: hover; enabled: root.hasClient; cursorShape: Qt.PointingHandCursor }
    TapHandler {
        enabled: root.hasClient
        onTapped: {
            Config.UiState.closeAll();
            root.open = !root.open;
        }
    }

    // ── actions ───────────────────────────────────────────────────────────
    readonly property var actions: [
        { n: "Fullscreen",        k: "super F",   cmd: "fullscreen 0" },
        { n: "Maximize",          k: "super ⇧ F", cmd: "fullscreen 1" },
        { n: "Float",             k: "super V",   cmd: "togglefloating" },
        { n: "Pin",               k: "super ⇧ P", cmd: "pin" },
        { n: "Center",            k: "",          cmd: "centerwindow", rule: true },
        { n: "Toggle split",      k: "super J",   cmd: "togglesplit" },
        { n: "Move to next workspace",     k: "", cmd: "movetoworkspace +1", rule: true },
        { n: "Move to previous workspace", k: "", cmd: "movetoworkspace -1" },
        { n: "Close window",      k: "super Q",   cmd: "killactive", rule: true }
    ]

    function run(cmd) {
        Services.Compositor.dispatch(cmd);
        open = false;
    }

    // Snap targets, as fractions of the usable area. `cells` drives the
    // mini-diagram so each tile shows the shape it produces.
    readonly property var snaps: [
        { fx: 0,    fy: 0,   fw: 0.5, fh: 1,   cells: [{ x: 0, y: 0, w: 0.5, h: 1 }] },
        { fx: 0.5,  fy: 0,   fw: 0.5, fh: 1,   cells: [{ x: 0.5, y: 0, w: 0.5, h: 1 }] },
        { fx: 0,    fy: 0,   fw: 1,   fh: 0.5, cells: [{ x: 0, y: 0, w: 1, h: 0.5 }] },
        { fx: 0,    fy: 0.5, fw: 1,   fh: 0.5, cells: [{ x: 0, y: 0.5, w: 1, h: 0.5 }] },
        { fx: 0,    fy: 0,   fw: 1,   fh: 1,   cells: [{ x: 0, y: 0, w: 1, h: 1 }] },
        { fx: 0.15, fy: 0.12, fw: 0.7, fh: 0.76, cells: [{ x: 0.15, y: 0.12, w: 0.7, h: 0.76 }] }
    ]

    // Usable area on this monitor: the full output minus the bar's exclusive
    // zone and the dock's gutter, with the same 8px gap hyprland.lua uses
    // for tiled windows so a snapped window lines up with its neighbours.
    readonly property real gap: 8
    readonly property real usableX: gap
    readonly property real usableY: Config.Appearance.barHeight + gap
    readonly property real usableW: Math.max(120, barWindow.width - gap * 2)
    readonly property real usableH: Math.max(120, barWindow.screen.height - Config.Appearance.barHeight
        - gap * 2 - (Config.Appearance.dockLeft ? 0 : Config.Appearance.dockPanelBreadth + Config.Appearance.dockEdgeGap))

    function snapTo(s) {
        if (!hasClient) return;
        const addr = "address:" + client.address;
        const x = Math.round(usableX + usableW * s.fx);
        const y = Math.round(usableY + usableH * s.fy);
        const w = Math.round(usableW * s.fw);
        const h = Math.round(usableH * s.fh);
        // Snapping only means anything for a floating window, so float it
        // first if it isn't already.
        if (!client.floating) Services.Compositor.dispatch("setfloating " + addr);
        Services.Compositor.dispatch("resizewindowpixel exact " + w + " " + h + "," + addr);
        Services.Compositor.dispatch("movewindowpixel exact " + x + " " + y + "," + addr);
        open = false;
    }

    // ── dropdown ──────────────────────────────────────────────────────────
    PopupWindow {
        id: popup
        visible: root.open
        color: "transparent"

        anchor.window: root.barWindow
        anchor.item: root
        anchor.edges: Edges.Bottom | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.margins.top: 6

        implicitWidth: 262
        implicitHeight: menuColumn.implicitHeight + 12

        PanelSurface {
            anchors.fill: parent
            showSeam: false
            color: Config.Appearance.panel

            Column {
                id: menuColumn
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
                        width: menuColumn.width
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
                                font.pixelSize: 10.5
                                color: rowHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink3
                            }
                        }

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.run(row.modelData.cmd) }
                    }
                }

                // Snap layouts — the mockup's popover, inlined at the foot of
                // the menu so it's one interaction instead of two.
                Item { width: 1; height: 8 }

                Rectangle { width: menuColumn.width; height: 1; color: Config.Appearance.rule }

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

                            Repeater {
                                model: snapTile.modelData.cells
                                Rectangle {
                                    required property var modelData
                                    x: 4 + (snapTile.width - 8) * modelData.x
                                    y: 4 + (snapTile.height - 8) * modelData.y
                                    width: (snapTile.width - 8) * modelData.w
                                    height: (snapTile.height - 8) * modelData.h
                                    radius: 3
                                    color: Config.Appearance.accent
                                    opacity: 0.5
                                }
                            }

                            HoverHandler { id: snapHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.snapTo(snapTile.modelData) }
                        }
                    }
                }

                Item { width: 1; height: 4 }
            }
        }
    }
}
