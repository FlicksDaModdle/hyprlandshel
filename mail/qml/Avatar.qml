import QtQuick
import Hyprshell

// A person's initials on their own colour.
Rectangle {
    id: av
    property string name: ""
    property string email: ""
    property real size: 34
    width: size
    height: size
    radius: size / 2
    color: Mail.hue((av.email || av.name).toLowerCase())
    StyledText {
        anchors.centerIn: parent
        text: Mail.initials(av.name, av.email)
        font.pixelSize: Math.round(av.size * 0.38)
        font.weight: Font.DemiBold
        color: "white"
    }
}
