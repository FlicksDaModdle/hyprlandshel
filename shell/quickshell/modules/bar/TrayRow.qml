import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import "../../config" as Config
import "../common"
import "../icons"

// StatusNotifierItem tray, collapsible behind a chevron like the mockup's
// "System tray" / "Tray expanded" pair in Settings → Bar.
//
// Icons come from the apps themselves, so these are real app icons rather
// than pack glyphs — left click activates, middle click is the secondary
// action, right click opens the app's own menu through Quickshell's
// DBusMenu bridge.
Item {
    id: root

    required property var barWindow

    readonly property var items: SystemTray.items.values
    readonly property bool expanded: Config.Appearance.trayOpen

    implicitWidth: layout.implicitWidth
    implicitHeight: 26
    visible: Config.Appearance.showTray && items.length > 0

    Row {
        id: layout
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        // Collapse / expand chevron
        Item {
            width: 22
            height: 26

            Rectangle {
                anchors.fill: parent
                radius: Config.Appearance.rCap
                color: arrowHover.hovered ? Config.Appearance.hover : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }
            }

            MonoIcon {
                anchors.centerIn: parent
                name: root.expanded ? "chevronRight" : "chevronLeft"
                size: Config.Appearance.barTrayIconSize
                inkColor: root.expanded ? Config.Appearance.ink2 : Config.Appearance.ink
                monochrome: true
            }

            HoverHandler { id: arrowHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Config.Appearance.trayOpen = !Config.Appearance.trayOpen }
        }

        Repeater {
            model: root.expanded ? root.items : []

            Item {
                id: entry
                required property var modelData

                width: 26
                height: 26

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rCap
                    color: entryHover.hovered ? Config.Appearance.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                IconImage {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    source: Config.Apps.themeIcon(entry.modelData.icon)
                    // Items that go passive shouldn't read as active.
                    opacity: entry.modelData.status === Status.Passive ? 0.55 : 1
                }

                HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: {
                        // Items that only offer a menu have no activate
                        // action — opening the menu is the sane fallback.
                        if (entry.modelData.onlyMenu) entry.openMenu();
                        else entry.modelData.activate();
                    }
                }
                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: entry.modelData.secondaryActivate()
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: entry.openMenu()
                }
                WheelHandler {
                    onWheel: event => entry.modelData.scroll(event.angleDelta.y, false)
                }

                function openMenu() {
                    if (!modelData.hasMenu) return;
                    // Anchor the app's own menu just below the bar, under
                    // this icon.
                    const pos = root.barWindow.itemRect(entry);
                    modelData.display(root.barWindow, Math.round(pos.x), Math.round(pos.y + pos.height));
                }
            }
        }

        // Divider before the rest of the status area.
        Item {
            width: 13
            height: 26
            Rectangle {
                anchors.centerIn: parent
                width: 1
                height: 18
                color: Config.Appearance.div
            }
        }
    }
}
