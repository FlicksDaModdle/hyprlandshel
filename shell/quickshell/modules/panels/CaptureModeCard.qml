import QtQuick
import "../../config" as Config
import "../common"
import "../icons"

// The capture panel's choice of what to take: a card that lights up in
// the accent.
Rectangle {
    id: card
    property string icon: ""
    property string label: ""
    property bool on: false
    signal clicked
    height: 80
    radius: Config.Appearance.r
    color: tint.value
    border.width: card.on ? 2 : 1
    border.color: edge.value
    ColorSpring {
        id: tint
        to: card.on ? Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.14)
                    : (cardHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
    }
    ColorSpring { id: edge; to: card.on ? Config.Appearance.accent : Config.Appearance.rule }
    scale: press.value
    Spring { id: press; to: cardTap.pressed ? 0.95 : 1; response: 260 }
    Column {
        anchors.centerIn: parent
        spacing: 7
        MonoIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: card.icon
            size: 22
            inkColor: card.on ? Config.Appearance.accent : Config.Appearance.ink
            accentColor: Config.Appearance.accent
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: card.label
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.DemiBold
            color: card.on ? Config.Appearance.ink : Config.Appearance.ink2
        }
    }
    HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { id: cardTap; onTapped: card.clicked() }
}
