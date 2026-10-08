import QtQuick
import "../../config" as Config
import "../common"

// A number you set the way a mixing desk's is set: drag up or down on it,
// scroll on it, or double-click and type. Shift makes either finer. Used for
// a band's frequency, gain and Q in the equalizer.
//
// `log` steps multiply rather than add, which is how frequency and Q are
// heard: 100 → 110 is as far as 1000 → 1100.
Rectangle {
    id: root

    property string label: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property real step: 1          // per scroll notch: added, or multiplied by 1+step when log
    property bool log: false
    property int decimals: 1
    property string unit: ""
    // How the value reads; the default is the number to `decimals`.
    property var format: v => v.toFixed(root.decimals)
    signal moved(real value)

    implicitWidth: 112
    implicitHeight: 46
    radius: Config.Appearance.rSm
    color: area.containsMouse || field.activeFocus ? Config.Appearance.sel : Config.Appearance.ground
    border.width: field.activeFocus ? 2 : 1
    border.color: field.activeFocus ? Config.Appearance.accent : Config.Appearance.rule
    opacity: enabled ? 1 : 0.45

    function clampv(v) { return Math.max(root.from, Math.min(root.to, v)); }
    function nudge(n, fine) {
        const s = fine ? root.step / 5 : root.step;
        root.moved(clampv(root.log ? root.value * Math.pow(1 + s, n) : root.value + s * n));
    }

    StyledText {
        x: 10; y: 6
        text: root.label
        font.pixelSize: Config.Appearance.fs(10)
        font.weight: Font.DemiBold
        color: Config.Appearance.ink3
    }
    StyledText {
        visible: !field.visible
        x: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        text: root.format(root.value) + (root.unit ? " " + root.unit : "")
        font.pixelSize: Config.Appearance.fs(14)
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
    }
    TextInput {
        id: field
        visible: activeFocus
        x: 10
        width: parent.width - 20
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        font.family: Config.Appearance.fontFamily
        font.pixelSize: Config.Appearance.fs(14)
        font.weight: Font.DemiBold
        color: Config.Appearance.ink
        selectionColor: Config.Appearance.accent
        selectedTextColor: Config.Appearance.inkOnAccent
        // "1.2k" is a frequency as people write one.
        onAccepted: {
            const t = text.trim().toLowerCase().replace(",", ".").replace("−", "-");
            let v = parseFloat(t);
            if (!isNaN(v)) {
                if (/k/.test(t)) v *= 1000;
                root.moved(root.clampv(v));
            }
            focus = false;
        }
        Keys.onEscapePressed: focus = false
    }

    MouseArea {
        id: area
        anchors.fill: parent
        enabled: !field.activeFocus
        hoverEnabled: true
        cursorShape: Qt.SizeVerCursor
        preventStealing: true
        property real lastY: 0
        property real acc: 0
        onPressed: mouse => { lastY = mouse.y; acc = 0; }
        onPositionChanged: mouse => {
            if (!pressed) return;
            acc += (lastY - mouse.y) / 6;
            lastY = mouse.y;
            const n = acc > 0 ? Math.floor(acc) : Math.ceil(acc);
            if (n !== 0) { acc -= n; root.nudge(n, mouse.modifiers & Qt.ShiftModifier); }
        }
        onDoubleClicked: {
            field.text = root.format(root.value);
            field.forceActiveFocus();
            field.selectAll();
        }
        onWheel: wheel => root.nudge(wheel.angleDelta.y > 0 ? 1 : -1, wheel.modifiers & Qt.ShiftModifier)
    }
}
