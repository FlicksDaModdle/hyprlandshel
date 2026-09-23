import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Volume / microphone / brightness readout. Appears above the dock when a
// level changes — from the media keys, from the control center sliders, or
// from anything else on the system that moves them.
//
// Input-transparent: it never swallows a click even while showing.
PanelWindow {
    id: osd

    visible: Config.UiState.osdVisible && !Config.UiState.locked
    color: "transparent"
    exclusiveZone: 0

    anchors.bottom: true

    implicitWidth: 420
    implicitHeight: 54 + bottomInset

    readonly property real bottomInset: Config.Appearance.dockLeft
        ? 40
        : Config.Appearance.dockPanelBreadth + Config.Appearance.dockEdgeGap + 40

    WlrLayershell.namespace: "quickshell:panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Nothing here should be clickable.
    mask: Region {}

    readonly property string kind: Config.UiState.osdKind
    readonly property bool muted: Config.UiState.osdMuted
    readonly property real value: Config.UiState.osdValue

    readonly property string glyph: {
        if (kind === "brightness") return "sun";
        if (kind === "mic") return muted ? "micOff" : "mic";
        if (muted || value <= 0.001) return "volumeX";
        return value < 0.5 ? "volumeLow" : "volume";
    }

    PanelSurface {
        id: pill
        showSeam: false

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: osd.bottomInset

        width: 340
        height: 54

        // Rise into place, matching the dock's own reveal easing.
        opacity: osd.visible ? 1 : 0
        transform: Translate { y: osd.visible ? 0 : 12 }
        Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(140) } }

        Row {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 16

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: osd.glyph
                size: 20
                inkColor: Config.Appearance.ink
                monochrome: true
            }

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 200
                height: 8

                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: Config.Appearance.sel
                    clip: true

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, osd.muted ? 0 : osd.value))
                        height: parent.height
                        radius: 4
                        color: Config.Appearance.accent
                        Behavior on width { NumberAnimation { duration: Config.Appearance.anim(90) } }
                    }
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: 48
                horizontalAlignment: Text.AlignRight
                text: osd.muted ? "muted" : Math.round(osd.value * 100) + "%"
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.DemiBold
            }
        }
    }
}
