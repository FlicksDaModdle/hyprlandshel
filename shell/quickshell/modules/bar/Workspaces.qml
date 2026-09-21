import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"

// The bar's workspace group: a recessed capsule of pills that expand to show
// their number when focused or hovered and collapse to a bead otherwise,
// exactly as in the mockup. Beads are real state — filled for a workspace
// with windows on it, hollow for an empty one, accent for urgent.
//
// Click to switch, scroll across the group to step through.
Item {
    id: root

    readonly property var slots: Services.Compositor.workspaceSlots
    property int hoveredId: -1

    implicitWidth: group.implicitWidth + 6
    implicitHeight: 28

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rCap
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
    }

    Row {
        id: group
        anchors.centerIn: parent
        spacing: 3

        Repeater {
            model: root.slots

            Item {
                id: pill
                required property var modelData

                readonly property bool focused: modelData.focused
                readonly property bool hovered: root.hoveredId === modelData.id
                readonly property bool occupied: modelData.windows > 0
                readonly property bool urgent: modelData.urgent
                readonly property bool expanded: focused || hovered || urgent

                width: expanded ? 26 : 16
                height: 22
                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rCap
                    color: pill.focused ? Config.Appearance.accent
                         : (pill.hovered ? Config.Appearance.sel : "transparent")
                    Behavior on color { ColorAnimation { duration: 160 } }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: pill.expanded
                    opacity: pill.expanded ? 1 : 0
                    text: pill.modelData.id
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    font.letterSpacing: 0.2
                    color: pill.focused ? Config.Appearance.onAccent
                         : (pill.urgent ? Config.Appearance.accent : Config.Appearance.ink2)
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }

                // Bead for the collapsed state: solid when the workspace has
                // windows, hollow when it's empty.
                Rectangle {
                    anchors.centerIn: parent
                    visible: !pill.expanded
                    width: pill.occupied ? 7 : 5
                    height: width
                    radius: 2.5
                    color: pill.occupied ? Config.Appearance.ink2 : "transparent"
                    border.width: pill.occupied ? 0 : 1.5
                    border.color: Config.Appearance.div
                    Behavior on width { NumberAnimation { duration: 160 } }
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: root.hoveredId = hovered ? pill.modelData.id : -1
                }
                TapHandler {
                    onTapped: Services.Compositor.focusWorkspace(pill.modelData.id)
                }
            }
        }
    }

    WheelHandler {
        // Step across existing workspaces rather than blindly ±1, so a
        // scroll can't strand you on an empty workspace 7.
        onWheel: event => {
            const ids = root.slots.filter(s => s.exists || s.focused).map(s => s.id);
            if (ids.length === 0) return;
            const at = ids.indexOf(Services.Compositor.focusedId);
            const next = event.angleDelta.y > 0 ? at - 1 : at + 1;
            if (next >= 0 && next < ids.length) Services.Compositor.focusWorkspace(ids[next]);
        }
    }
}
