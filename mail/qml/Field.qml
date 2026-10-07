import QtQuick
import Hyprshell

// A one-line text box with an optional label to its left.
Item {
    id: f
    property string label: ""
    property real labelWidth: f.label === "" ? 0 : 96
    property alias text: input.text
    property string placeholder: ""
    property bool password: false
    property bool bare: false
    property alias input: input
    property bool readOnly: false
    property bool bold: false
    signal edited(string text)
    signal accepted()
    signal focusLost()
    implicitHeight: 34
    implicitWidth: 300

    StyledText {
        visible: f.label !== ""
        width: f.labelWidth
        anchors.verticalCenter: parent.verticalCenter
        text: f.label
        font.pixelSize: Appearance.fs(12.5)
        color: Appearance.ink2
    }
    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: f.labelWidth
        anchors.right: parent.right
        height: parent.height
        radius: Appearance.rSm
        color: f.bare ? "transparent" : Appearance.hover
        border.width: f.bare ? 0 : (input.activeFocus ? 2 : 1)
        border.color: input.activeFocus ? Appearance.accent : Appearance.rule
        TextInput {
            id: input
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: f.bare ? 0 : 10
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            echoMode: f.password ? TextInput.Password : TextInput.Normal
            color: Appearance.ink
            selectionColor: Appearance.accent
            selectedTextColor: Appearance.inkOnAccent
            selectByMouse: true
            font.family: Appearance.fontFamily
            font.pixelSize: Appearance.fs(13)
            readOnly: f.readOnly
            font.weight: f.bold ? Font.DemiBold : Font.Normal
            onTextEdited: f.edited(text)
            onAccepted: f.accepted()
            onActiveFocusChanged: if (!activeFocus) f.focusLost()
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === "" && !input.preeditText
                text: f.placeholder
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink3
            }
        }
    }
}
