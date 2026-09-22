import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Windows-style task list beside the app menus — the mockup's Settings →
// Bar → "Task buttons" row. Off by default, like the mockup.
//
// One button per app on the focused workspace, with a stack count when an
// app has several windows and a bead showing focus. Clicking focuses the
// app's most recent window; scrolling cycles through that app's windows.
Item {
    id: root

    property real maxWidth: 600

    // Grouped by class, restricted to the focused workspace so the list
    // doesn't turn into every window on the system.
    readonly property var groups: {
        const here = Services.Compositor.clientsOn(Services.Compositor.focusedId);
        const order = [];
        const byClass = ({});
        for (const c of here) {
            const key = c.cls || "unknown";
            if (!byClass[key]) { byClass[key] = []; order.push(key); }
            byClass[key].push(c);
        }
        return order.map(key => ({
            cls: key,
            windows: byClass[key],
            active: byClass[key].some(c => c.address === Services.Compositor.activeAddress)
        }));
    }

    implicitWidth: Math.min(maxWidth, row.implicitWidth + 19)
    implicitHeight: 26
    visible: groups.length > 0
    clip: true

    Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: 18
        color: Config.Appearance.div
    }

    Row {
        id: row
        anchors.left: parent.left
        anchors.leftMargin: 13
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Repeater {
            model: root.groups

            Item {
                id: task
                required property var modelData

                width: content.implicitWidth + 22
                height: 26

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rCap
                    color: task.modelData.active ? Config.Appearance.sel
                         : (taskHover.hovered ? Config.Appearance.hover : "transparent")
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                Row {
                    id: content
                    anchors.centerIn: parent
                    spacing: 8

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: Config.Apps.iconFor(task.modelData.cls)
                        size: 14
                        inkColor: task.modelData.active ? Config.Appearance.ink : Config.Appearance.ink2
                        accentColor: Config.Appearance.accent
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Config.Apps.labelFor(task.modelData.cls)
                        font.pixelSize: 13
                        color: Config.Appearance.ink
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: task.modelData.windows.length > 1
                        width: countLabel.implicitWidth + 10
                        height: 16
                        radius: 5
                        color: Config.Appearance.hover

                        StyledText {
                            id: countLabel
                            anchors.centerIn: parent
                            text: task.modelData.windows.length
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: Config.Appearance.ink3
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 5
                        height: 5
                        radius: 2
                        color: task.modelData.active ? Config.Appearance.accent : Config.Appearance.ink3
                    }
                }

                HoverHandler { id: taskHover; cursorShape: Qt.PointingHandCursor }

                TapHandler {
                    onTapped: {
                        const wins = task.modelData.windows;
                        // Already focused with more than one window: step to
                        // the next, the way a taskbar group behaves.
                        const at = wins.findIndex(c => c.address === Services.Compositor.activeAddress);
                        const next = at >= 0 ? wins[(at + 1) % wins.length] : wins[0];
                        Services.Compositor.focusClient(next.address);
                    }
                }
                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: {
                        const focused = task.modelData.windows.find(
                            c => c.address === Services.Compositor.activeAddress);
                        Services.Compositor.closeClient(
                            (focused || task.modelData.windows[0]).address);
                    }
                }
            }
        }
    }
}
