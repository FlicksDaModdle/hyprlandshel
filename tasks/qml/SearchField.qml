import QtQuick
import Hyprshell

// The search box in the title bar.
Rectangle {
    id: field
    property alias text: input.text
    property string placeholder: "Search"
    signal edited(string text)
    function focusIn() { input.forceActiveFocus(); input.selectAll(); }
    implicitHeight: 30
    radius: Appearance.rPill
    color: Appearance.hover
    border.width: input.activeFocus ? 2 : 1
    border.color: input.activeFocus ? Appearance.accent : Appearance.rule
    MonoIcon {
        id: glass
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        name: "search"
        size: 15
        inkColor: Appearance.ink3
        monochrome: true
    }
    TextInput {
        id: input
        anchors.left: glass.right
        anchors.leftMargin: 8
        anchors.right: clear.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        clip: true
        color: Appearance.ink
        selectionColor: Appearance.accent
        selectedTextColor: Appearance.inkOnAccent
        font.family: Appearance.fontFamily
        font.pixelSize: Appearance.fs(12.5)
        onTextEdited: field.edited(text)
        Keys.onEscapePressed: e => { if (text !== "") { text = ""; field.edited(""); e.accepted = true; } else e.accepted = false; }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === ""
            text: field.placeholder
            font.pixelSize: Appearance.fs(12.5)
            color: Appearance.ink3
        }
    }
    MonoIcon {
        id: clear
        anchors.right: parent.right
        anchors.rightMargin: 9
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text !== ""
        name: "x"
        size: 14
        inkColor: Appearance.ink3
        monochrome: true
        MouseArea {
            anchors.fill: parent
            anchors.margins: -5
            cursorShape: Qt.PointingHandCursor
            onClicked: { input.text = ""; field.edited(""); }
        }
    }
}
