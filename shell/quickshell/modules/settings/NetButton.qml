import QtQuick
import "../../config" as Config
import "../common"

// A button for the Network and Bluetooth panes: accent-filled when it is the
// thing to do, quiet otherwise.
Rectangle {
    id: root

    property string label: ""
    property bool primary: false
    property bool danger: false
    property bool active: true
    signal clicked()

    implicitWidth: text.implicitWidth + 26
    implicitHeight: 30
    radius: Config.Appearance.rSm
    opacity: root.active ? 1 : 0.45
    color: root.primary ? Config.Appearance.accent
         : hover.hovered && root.active ? Config.Appearance.sel : Config.Appearance.hover
    border.width: root.primary ? 0 : 1
    border.color: Config.Appearance.rule

    StyledText {
        id: text
        anchors.centerIn: parent
        text: root.label
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        color: root.primary ? Config.Appearance.inkOnAccent
             : root.danger ? Config.Appearance.accent : Config.Appearance.ink
    }

    HoverHandler { id: hover; cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { enabled: root.active; onTapped: root.clicked() }
}
