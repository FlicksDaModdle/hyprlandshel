import QtQuick
import "../../config" as Config

// Accent colour picker, drawn in the shell's own vocabulary rather than
// borrowing the desktop's: a layer-shell process can't host a system colour
// dialog, and one would look nothing like the rest of this anyway.
//
// Hue runs along a strip; saturation and lightness are a square above it,
// which is the arrangement people already know. The hex field accepts typing
// or pasting a value, so an exact brand colour doesn't have to be hunted for
// with the pointer.
Rectangle {
    id: root

    property color value: "#3b6ef5"
    property bool open: false

    signal picked(color value)

    visible: open
    width: 208
    height: column.implicitHeight + 20
    radius: Config.Appearance.r
    // Opaque: this floats over the settings rows and has nothing blurred
    // behind it to justify a translucent fill.
    color: Config.Appearance.menuSurface
    border.width: 1
    border.color: Config.Appearance.edge

    // Working state, so dragging the square doesn't fight the binding that
    // feeds `value` back in from the preference it writes.
    property real hue: 0.6
    property real sat: 0.7
    property real lig: 0.55

    onOpenChanged: if (open) syncFromValue()

    function syncFromValue() {
        const c = Qt.color(root.value);
        hue = c.hslHue >= 0 ? c.hslHue : 0;
        sat = c.hslSaturation;
        lig = c.hslLightness;
    }

    readonly property color current: Qt.hsla(hue, sat, lig, 1)

    function commit() { root.picked(current); }

    // Qt gives no colour→hex helper, so this is done by hand.
    function hex(c) {
        const f = x => {
            const v = Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16);
            return v.length < 2 ? "0" + v : v;
        };
        return "#" + f(c.r) + f(c.g) + f(c.b);
    }

    Column {
        id: column
        anchors.centerIn: parent
        width: parent.width - 20
        spacing: 10

        // ── saturation / lightness ────────────────────────────────────────
        Item {
            width: parent.width
            height: 108

            Rectangle {
                id: plane
                anchors.fill: parent
                radius: Config.Appearance.rSm
                clip: true
                // Full-saturation hue, washed to white across and to black
                // down — the standard SL square.
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.hsla(root.hue, 0, 0.5, 1) }
                    GradientStop { position: 1; color: Qt.hsla(root.hue, 1, 0.5, 1) }
                }

                Rectangle {
                    anchors.fill: parent
                    // Same radius as the plane it covers. Without it this
                    // wash painted square corners straight over the rounded
                    // ones underneath, which is what made the square look
                    // un-rounded however much the corner setting was raised.
                    radius: parent.radius
                    gradient: Gradient {
                        GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.92) }
                        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0) }
                        GradientStop { position: 0.5001; color: Qt.rgba(0, 0, 0, 0) }
                        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.92) }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rSm
                    color: "transparent"
                    border.width: 1
                    border.color: Config.Appearance.rule
                }
            }

            // Crosshair
            Rectangle {
                x: Math.round(root.sat * plane.width) - 7
                y: Math.round((1 - root.lig) * plane.height) - 7
                width: 14
                height: 14
                radius: 7
                color: "transparent"
                border.width: 2
                border.color: "#ffffff"
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: 5
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(0, 0, 0, 0.5)
                }
            }

            MouseArea {
                anchors.fill: parent
                preventStealing: true
                cursorShape: Qt.CrossCursor
                function apply(mouse) {
                    root.sat = Math.max(0, Math.min(1, mouse.x / Math.max(1, width)));
                    root.lig = Math.max(0, Math.min(1, 1 - mouse.y / Math.max(1, height)));
                }
                onPressed: mouse => apply(mouse)
                onPositionChanged: mouse => { if (pressed) apply(mouse); }
                onReleased: root.commit()
            }
        }

        // ── hue ───────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 16

            Rectangle {
                id: hueBar
                anchors.fill: parent
                radius: Config.Appearance.rSm
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.000; color: "#ff0000" }
                    GradientStop { position: 0.167; color: "#ffff00" }
                    GradientStop { position: 0.333; color: "#00ff00" }
                    GradientStop { position: 0.500; color: "#00ffff" }
                    GradientStop { position: 0.667; color: "#0000ff" }
                    GradientStop { position: 0.833; color: "#ff00ff" }
                    GradientStop { position: 1.000; color: "#ff0000" }
                }
                border.width: 1
                border.color: Config.Appearance.rule
            }

            Rectangle {
                x: Math.round(root.hue * hueBar.width) - 3
                y: -2
                width: 6
                height: parent.height + 4
                radius: 3
                color: "transparent"
                border.width: 2
                border.color: "#ffffff"
            }

            MouseArea {
                anchors.fill: parent
                anchors.topMargin: -5
                anchors.bottomMargin: -5
                preventStealing: true
                cursorShape: Qt.PointingHandCursor
                function apply(mouse) {
                    root.hue = Math.max(0, Math.min(1, mouse.x / Math.max(1, width)));
                }
                onPressed: mouse => apply(mouse)
                onPositionChanged: mouse => { if (pressed) apply(mouse); }
                onReleased: root.commit()
            }
        }

        // ── hex ───────────────────────────────────────────────────────────
        Row {
            width: parent.width
            spacing: 8

            Rectangle {
                width: 30
                height: 28
                radius: Config.Appearance.rSm
                color: root.current
                border.width: 1
                border.color: Config.Appearance.rule
            }

            Rectangle {
                width: parent.width - 38
                height: 28
                radius: Config.Appearance.rSm
                color: Config.Appearance.hover
                border.width: 1
                border.color: hexField.activeFocus ? Config.Appearance.accent
                                                   : Config.Appearance.rule

                TextInput {
                    id: hexField
                    anchors.fill: parent
                    anchors.leftMargin: 9
                    verticalAlignment: Text.AlignVCenter
                    text: root.hex(root.current).toUpperCase()
                    color: Config.Appearance.ink
                    font.family: Config.Appearance.monoFamily
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                    selectByMouse: true
                    selectionColor: Config.Appearance.accent
                    selectedTextColor: Config.Appearance.onAccent
                    maximumLength: 7

                    function commit() {
                        // Accepts #rrggbb with or without the hash; anything
                        // else snaps back rather than writing a colour the
                        // rest of the shell can't parse.
                        const t = text.trim().replace(/^#/, "");
                        if (!/^[0-9a-fA-F]{6}$/.test(t)) {
                            text = root.hex(root.current).toUpperCase();
                            return;
                        }
                        const c = Qt.color("#" + t);
                        root.hue = c.hslHue >= 0 ? c.hslHue : root.hue;
                        root.sat = c.hslSaturation;
                        root.lig = c.hslLightness;
                        root.commit();
                    }

                    onEditingFinished: commit()
                    Keys.onReturnPressed: commit()
                    Keys.onEnterPressed: commit()
                }
            }
        }
    }
}
