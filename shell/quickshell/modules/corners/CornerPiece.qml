import QtQuick

// One black screen corner: a square `radius` across with a quarter circle
// taken out of it, the inside of the screen. `turn` is which corner — 0 top
// left, 90 top right, 180 bottom right, 270 bottom left.
//
// Drawn as the border of a rounded rectangle whose inner edge is the
// quarter circle, rather than painted on a Canvas: the scene graph
// antialiases it on the GPU and it stays sharp at any output scale.
Item {
    id: piece

    property real radius: 14
    property real turn: 0

    width: radius
    height: radius
    clip: true

    Item {
        anchors.fill: parent
        rotation: piece.turn

        Rectangle {
            // The border's inner corner has radius (radius - border), so a
            // border as wide as the corner leaves exactly `piece.radius` for
            // it — and covers this square right up to its outer corner.
            readonly property real band: piece.radius
            x: -band
            y: -band
            width: piece.radius * 2 + band * 2
            height: width
            radius: piece.radius + band
            color: "transparent"
            border.width: band
            border.color: "#000000"
            antialiasing: true
        }
    }
}
