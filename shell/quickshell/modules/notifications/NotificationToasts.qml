import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../panels"

// Banner stack under the top bar's right edge. Each banner is the same card
// the notification center uses, so an action pressed here is the sender's
// real action.
//
// The surface is click-through except where a banner actually is — the mask
// is the banner column, so an empty strip of desktop under the bar stays
// clickable.
PanelWindow {
    id: toasts

    visible: Services.Notifications.popups.length > 0 && !Config.UiState.locked
    color: "transparent"
    exclusiveZone: 0

    anchors.top: true
    anchors.right: true

    implicitWidth: 400
    implicitHeight: Math.max(1, column.implicitHeight + 16)

    WlrLayershell.namespace: "quickshell:panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region { item: column }

    Column {
        id: column
        anchors.top: parent.top
        anchors.topMargin: Config.Appearance.panelGap
        anchors.right: parent.right
        anchors.rightMargin: Config.Appearance.panelEdgeGap
        width: 376
        spacing: 8

        Repeater {
            model: Services.Notifications.popups

            Item {
                id: slot
                required property var modelData

                width: column.width
                height: card.implicitHeight

                // Slide in from the right, fade out on the way back.
                property bool shown: false
                Component.onCompleted: shown = true

                opacity: shown ? 1 : 0
                x: shown ? 0 : 56
                scale: shown ? 1 : 0.96
                Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(180) } }
                Behavior on x { Spring { ms: 460; bounce: slot.shown ? 0.9 : 0 } }
                Behavior on scale { Spring { ms: 420 } }

                NotificationRow {
                    id: card
                    width: parent.width
                    notification: slot.modelData
                    // Banners sit on the desktop rather than inside a panel,
                    // so they need their own opaque sheet behind them.
                    color: cardHover.hovered ? Config.Appearance.surface : Config.Appearance.sheet

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: 1
                        border.color: Config.Appearance.edge
                    }
                }

                HoverHandler { id: cardHover }

                // Critical notifications stay until acted on, as the spec
                // intends; everything else times out. Hovering holds it.
                Timer {
                    running: slot.modelData
                             && slot.modelData.urgency !== NotificationUrgency.Critical
                             && !cardHover.hovered
                    interval: Math.max(1, Config.Appearance.popupTimeout) * 1000
                    onTriggered: Services.Notifications.dismissPopup(slot.modelData)
                }
            }
        }
    }
}
