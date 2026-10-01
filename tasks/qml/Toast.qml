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
        toast.opacity = 1;
        hide.restart();
    }
    showSeam: false
    color: Appearance.dialog
    width: Math.min(parent ? parent.width - 40 : 500, row.implicitWidth + 30)
    height: 42
    opacity: 0
    visible: opacity > 0
    z: 2500
    Behavior on opacity { NumberAnimation { duration: 180 } }
    Timer { id: hide; interval: toast.actionText !== "" ? 9000 : 3500; onTriggered: toast.opacity = 0 }
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
                onClicked: { toast.opacity = 0; if (toast.action) toast.action(); }
            }
        }
    }
}
