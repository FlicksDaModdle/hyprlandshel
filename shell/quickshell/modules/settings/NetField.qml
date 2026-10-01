import QtQuick
import "../../config" as Config
import "../common"

// A labelled text field for the Network and Bluetooth panes. `text` is the
// caller's to bind; edits come back through edited(), so a list rebuilt
// under it cannot take away what was typed.
Column {
    id: root

    property string label: ""
    property string hint: ""
    property string text: ""
    property string placeholder: ""
    property bool secret: false
    property bool digits: false
    property bool reveal: false
    property alias input: field
    signal edited(string text)
    signal accepted()

    spacing: 5

    StyledText {
        visible: root.label !== ""
        text: root.label
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.Medium
        color: Config.Appearance.ink2
    }

    Rectangle {
        width: root.width
        height: 34
        radius: Config.Appearance.rSm
        color: Config.Appearance.ground
        border.width: field.activeFocus ? 2 : 1
        border.color: field.activeFocus ? Config.Appearance.accent : Config.Appearance.rule

        TextInput {
            id: field
            anchors.fill: parent
            anchors.leftMargin: 11
            anchors.rightMargin: root.secret ? 40 : 11
            verticalAlignment: Text.AlignVCenter
            clip: true
            color: Config.Appearance.ink
            font.family: Config.Appearance.fontFamily
            font.pixelSize: Config.Appearance.fs(13)
            echoMode: root.secret && !root.reveal ? TextInput.Password : TextInput.Normal
            inputMethodHints: root.digits ? Qt.ImhDigitsOnly : Qt.ImhNone
            validator: root.digits ? digitsOnly : null
            selectByMouse: true
            text: root.text
            onTextEdited: root.edited(text)
            onAccepted: root.accepted()

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: field.text === ""
                text: root.placeholder
                font.pixelSize: Config.Appearance.fs(13)
                color: Config.Appearance.ink3
            }
        }
        RegularExpressionValidator { id: digitsOnly; regularExpression: /[0-9]{0,16}/ }

        // Show the password: typing one blind on a phone-sized keyboard
        // prompt is how a campus password goes wrong three times.
        StyledText {
            visible: root.secret
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.reveal ? "Hide" : "Show"
            font.pixelSize: Config.Appearance.fs(11)
            font.weight: Font.DemiBold
            color: eyeHover.hovered ? Config.Appearance.ink : Config.Appearance.ink3
            HoverHandler { id: eyeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.reveal = !root.reveal }
        }
    }

    StyledText {
        visible: root.hint !== ""
        width: root.width
        wrapMode: Text.WordWrap
        text: root.hint
        font.pixelSize: Config.Appearance.fs(11)
        color: Config.Appearance.ink3
    }
}
