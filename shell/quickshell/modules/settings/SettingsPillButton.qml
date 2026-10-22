import QtQuick
import "../../config" as Config
import "../common"
import "../icons"

// A rounded button for Settings' panels: quiet, or in the accent.
Rectangle {
    id: pb
    property string label: ""
    property string icon: ""
    property bool primary: false
    property bool active: true
    signal clicked
    width: pbRow.implicitWidth + 24
    height: 32
    radius: height / 2
    opacity: active ? 1 : 0.5
    color: primary ? (pbHover.hovered ? Qt.lighter(Config.Appearance.accent, 1.08) : Config.Appearance.accent)
                   : (pbHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
    border.width: primary ? 0 : 1
    border.color: Config.Appearance.rule
    Row {
        id: pbRow
        anchors.centerIn: parent
        spacing: 6
        MonoIcon {
            visible: pb.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            name: pb.icon
            size: 14
            inkColor: pb.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
            accentColor: pb.primary ? Config.Appearance.inkOnAccent : Config.Appearance.accent
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: pb.label
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.DemiBold
            color: pb.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
        }
    }
    HoverHandler { id: pbHover; cursorShape: Qt.PointingHandCursor; enabled: pb.active }
    TapHandler { enabled: pb.active; onTapped: pb.clicked() }
}
