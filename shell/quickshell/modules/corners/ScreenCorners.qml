import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config

// Black, rounded corners over the screen's own (Settings → Appearance →
// Screen corners), for a panel with square corners in a rounded bezel.
//
// Four small surfaces per screen, one in each corner, rather than one over
// the whole output: they cover only what they draw. On the overlay layer
// so they stay over fullscreen windows, ignoring every exclusive zone so a
// bar or dock cannot push them in from the edge, and taking no input, so
// whatever is under a corner can still be clicked.
Variants {
    model: Quickshell.screens

    Scope {
        id: screenScope
        required property var modelData

        readonly property bool builtIn: /^(eDP|LVDS|DSI)/.test(String(modelData ? modelData.name : ""))
        readonly property bool wanted: !!modelData && Config.Appearance.screenCorners
                                       && Config.Appearance.screenCornerRadius > 0
                                       && (Config.Appearance.screenCornerScreens === "all" || screenScope.builtIn)

        Variants {
            model: [
                { key: "TL", turn: 0,   top: true,  left: true },
                { key: "TR", turn: 90,  top: true,  left: false },
                { key: "BR", turn: 180, top: false, left: false },
                { key: "BL", turn: 270, top: false, left: true }
            ]

            PanelWindow {
                id: corner
                required property var modelData

                screen: screenScope.modelData ?? null
                readonly property bool on: {
                    const A = Config.Appearance;
                    switch (corner.modelData.key) {
                    case "TL": return A.screenCornerTL;
                    case "TR": return A.screenCornerTR;
                    case "BR": return A.screenCornerBR;
                    default:   return A.screenCornerBL;
                    }
                }
                visible: screenScope.wanted && corner.on

                anchors.top: corner.modelData.top
                anchors.bottom: !corner.modelData.top
                anchors.left: corner.modelData.left
                anchors.right: !corner.modelData.left

                implicitWidth: Config.Appearance.screenCornerRadius
                implicitHeight: Config.Appearance.screenCornerRadius
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                exclusiveZone: 0

                WlrLayershell.namespace: "quickshell:corners"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                mask: Region {}

                CornerPiece {
                    radius: Config.Appearance.screenCornerRadius
                    turn: corner.modelData.turn
                }
            }
        }
    }
}
