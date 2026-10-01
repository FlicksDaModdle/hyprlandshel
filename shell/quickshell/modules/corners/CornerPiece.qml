import QtQuick
import "../../services" as Services

// One black screen corner: a square `radius` across with a quarter circle
// taken out of it, the inside of the screen. `turn` is which corner — 0 top
// left, 90 top right, 180 bottom right, 270 bottom left.
//
// Drawn as the border of a rounded rectangle whose inner edge is the
// quarter circle, rather than painted on a Canvas: the scene graph
// antialiases it on the GPU and it stays sharp at any output scale.
//
// With `guard` on it is bezel to the pointer too: the cursor cannot rest
// in the black. Wayland gives a client no way to fence the pointer in, so
// when it comes into the black it is moved back to the curve's edge
// (Hyprland's own cursor.move) — a wall, felt the way the screen's real
// edge is. `origin` is where this square's top-left is in the compositor's
// layout, which is what the move is given.
Item {
    id: piece

    property real radius: 14
    property real turn: 0
    property bool guard: false
    property point origin: Qt.point(0, 0)

    width: radius
    height: radius
    clip: true

    // The circle's centre, in this square: the corner diagonally opposite
    // the screen's own.
    readonly property point centre: piece.turn === 0   ? Qt.point(piece.radius, piece.radius)
                                  : piece.turn === 90  ? Qt.point(0, piece.radius)
                                  : piece.turn === 180 ? Qt.point(0, 0)
                                  :                      Qt.point(piece.radius, 0)

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

    // ── keeping the pointer out ───────────────────────────────────────────
    // Where it should go instead: straight back towards the centre, to just
    // inside the curve.
    function pushOut(x, y) {
        const dx = x - piece.centre.x, dy = y - piece.centre.y;
        const d = Math.sqrt(dx * dx + dy * dy);
        if (d <= piece.radius - 1 || d === 0) return;
        const k = (piece.radius - 1.5) / d;
        piece.want = Qt.point(piece.origin.x + piece.centre.x + dx * k,
                              piece.origin.y + piece.centre.y + dy * k);
        // One move a frame at most: the pointer reports far more often
        // than that, and only the last place matters.
        if (!pace.running) { piece.send(); pace.start(); }
        else piece.waiting = true;
    }
    property point want: Qt.point(0, 0)
    property bool waiting: false
    function send() {
        piece.waiting = false;
        Services.Compositor.dispatch("hl.dsp.cursor.move({ x = " + piece.want.x.toFixed(1)
                                     + ", y = " + piece.want.y.toFixed(1) + " })");
    }
    Timer {
        id: pace
        interval: 16
        onTriggered: if (piece.waiting) { piece.send(); pace.start(); }
    }

    MouseArea {
        anchors.fill: parent
        enabled: piece.guard
        hoverEnabled: true
        // The black is not something to click either.
        acceptedButtons: Qt.AllButtons
        onEntered: piece.pushOut(mouseX, mouseY)
        onPositionChanged: mouse => piece.pushOut(mouse.x, mouse.y)
    }
}
