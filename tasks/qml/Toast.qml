import QtQuick
import Hyprshell

// What an action came to: a line at the bottom of the window, and a
// button when there is something to do about it ("Try as administrator").
PanelSurface {
    id: toast
    property string message: ""
    property bool failed: false
    property string actionText: ""
    property var action: null
    function show(text, bad, actText, act) {
        toast.message = text;
        toast.failed = !!bad;
        toast.actionText = actText || "";
        toast.action = act || null;
        toast.up = true;
        hide.restart();
    }
    showSeam: false
    color: Appearance.dialog
    width: Math.min(parent ? parent.width - 40 : 500, row.implicitWidth + 30)
    height: 42
    // Rises into place with a little give and sinks away without any.
    property bool up: false
    opacity: Math.max(0, Math.min(1, fade.value))
    visible: opacity > 0.004
    scale: grow.value
    transform: Translate { y: rise.value }
    z: 2500
    Spring { id: fade; to: toast.up ? 1 : 0; response: toast.up ? 180 : 220; bounce: 0 }
    Spring { id: grow; to: toast.up ? 1 : 0.94; response: 340; bounce: toast.up ? 1 : 0 }
    Spring { id: rise; to: toast.up ? 0 : 14; response: 360; bounce: toast.up ? 0.8 : 0 }
    Timer { id: hide; interval: toast.actionText !== "" ? 9000 : 3500; onTriggered: toast.up = false }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 14
        MonoIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: toast.failed ? "info" : "check"
            size: 16
            inkColor: toast.failed ? Appearance.accent : Appearance.ink
            accentColor: Appearance.accent
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: toast.message
            font.pixelSize: Appearance.fs(12)
            width: Math.min(implicitWidth, 520)
            elide: Text.ElideRight
        }
        StyledText {
            visible: toast.actionText !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: toast.actionText
            font.pixelSize: Appearance.fs(12)
            font.weight: Font.DemiBold
            color: Appearance.accent
            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                cursorShape: Qt.PointingHandCursor
                onClicked: { toast.up = false; if (toast.action) toast.action(); }
            }
        }
    }
}
