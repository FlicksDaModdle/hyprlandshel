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
// whatever is under a corner can still be clicked — but not the pointer
// itself: it is kept out of the black, as it is out of the real bezel (see
// CornerPiece).
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
                readonly property int r: Config.Appearance.screenCornerRadius

                // Input only where it is black: the square less the circle,
                // so hovering and clicking just inside the curve still
                // reaches whatever is there.
                mask: Region {
                    width: corner.r
                    height: corner.r
                    Region {
                        shape: RegionShape.Ellipse
                        intersection: Intersection.Subtract
                        x: Math.round(piece.centre.x) - corner.r
                        y: Math.round(piece.centre.y) - corner.r
                        width: corner.r * 2
                        height: corner.r * 2
                    }
                }

                CornerPiece {
                    id: piece
                    radius: corner.r
                    turn: corner.modelData.turn
                    // The pointer is kept out of the black.
                    guard: true
                    origin: {
                        const sc = screenScope.modelData;
                        if (!sc) return Qt.point(0, 0);
                        return Qt.point(sc.x + (corner.modelData.left ? 0 : sc.width - corner.r),
                                        sc.y + (corner.modelData.top ? 0 : sc.height - corner.r));
                    }
                }
            }
        }
    }
}
