import QtQuick
import "../../config" as Config

// The mockup's slider: a rounded trough filled from the left in accent, with
// no visible handle. Drag or click anywhere on it to set the value.
//
// `value` is left alone — callers bind it to live state (PipeWire volume,
// the backlight, a persisted preference) and that binding must survive being
// dragged. So dragging emits `moved` and the fill follows a separate drag
// value until the pointer is released, by which time the caller's write has
// come back around through the binding.
Item {
    id: root

    property real value: 0          // 0..1, bound by the caller
    property real trough: 20        // height of the bar
    property color fillColor: Config.Appearance.accent
    property color trackColor: Config.Appearance.hover
    property bool showRule: false   // inset hairline, used inside Settings rows
    property real radius: Config.Appearance.rSm

    signal moved(real value)
    signal released(real value)

    readonly property bool dragging: area.pressed
    property real dragValue: 0
    readonly property real shownValue: Math.max(0, Math.min(1, dragging ? dragValue : value))

    implicitHeight: trough
    implicitWidth: 200

    Rectangle {
        id: track
        anchors.fill: parent
        radius: root.radius
        color: root.trackColor
        clip: true
        opacity: root.enabled ? 1 : 0.5   // Item.enabled, set by the caller

        Rectangle {
            width: Math.round(parent.width * root.shownValue)
            height: parent.height
            radius: root.radius
            color: root.fillColor

            // A rounded fill at tiny widths collapses into a lozenge, so the
            // right edge is squared off to read as a level rather than a
            // pill. Not at the top of the range though: there the fill and
            // the track end together, and squaring it leaves a flat corner
            // sticking out of the trough's rounded one.
            Rectangle {
                visible: parent.width > root.radius
                         && parent.width < track.width - 0.5
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.min(root.radius, parent.width)
                color: parent.color
            }
        }

        Rectangle {
            visible: root.showRule
            anchors.fill: parent
            radius: root.radius
            color: "transparent"
            border.width: 1
            border.color: Config.Appearance.rule
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        // A few px of vertical slack makes thin troughs far easier to grab.
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        preventStealing: true

        function apply(mouse) {
            const v = Math.max(0, Math.min(1, mouse.x / Math.max(1, width)));
            root.dragValue = v;
            root.moved(v);
        }

        onPressed: mouse => apply(mouse)
        onPositionChanged: mouse => { if (pressed) apply(mouse); }
        onReleased: root.released(root.dragValue)
        onWheel: wheel => {
            const v = Math.max(0, Math.min(1, root.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)));
            root.moved(v);
            root.released(v);
        }
    }
}
