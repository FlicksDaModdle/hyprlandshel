import QtQuick
import Quickshell.Widgets
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
    // A mouse wheel over it nudges it. Off inside a scrolling page, where
    // the wheel is for the page.
    property bool takesWheel: true

    signal moved(real value)
    signal released(real value)

    readonly property bool dragging: area.pressed
    property real dragValue: 0
    readonly property real shownValue: Math.max(0, Math.min(1, dragging ? dragValue : value))

    implicitHeight: trough
    implicitWidth: 200

    // The track clips the fill to its own rounded shape, and the fill is a
    // plain bar: its edge is the level, straight at any value, and it can
    // never show outside the track. A rounded fill clipped to a square box
    // used to shrink, near zero, into a little lozenge of its own whose
    // corners stood out past the track's rounded end.
    ClippingRectangle {
        id: track
        anchors.fill: parent
        radius: root.radius
        color: root.trackColor
        opacity: root.enabled ? 1 : 0.5   // Item.enabled, set by the caller

        Rectangle {
            width: parent.width * root.shownValue
            height: parent.height
            color: root.fillColor
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
            // A trackpad swipe is someone scrolling the page past it.
            if (!root.takesWheel || wheel.phase !== Qt.NoScrollPhase) {
                wheel.accepted = false;
                return;
            }
            const v = Math.max(0, Math.min(1, root.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)));
            root.moved(v);
            root.released(v);
        }
    }
}
