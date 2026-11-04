import QtQuick
import "../../config" as Config
import "../common"

// A button for the HDR calibration screen (HdrCalibration.qml): plain and
// dim on its black ground, so it doesn't light the area being judged.
Rectangle {
    id: btn

    property string label: ""
    property bool primary: false
    signal clicked()

    implicitWidth: txt.implicitWidth + 40
    implicitHeight: 40
    radius: 8
    color: primary ? Config.Appearance.accent
         : area.containsMouse ? Qt.rgba(0.22, 0.22, 0.22, 1) : Qt.rgba(0.14, 0.14, 0.14, 1)

    StyledText {
        id: txt
        anchors.centerIn: parent
        text: btn.label
        font.pixelSize: 14
        color: btn.primary ? Config.Appearance.inkOnAccent : Qt.rgba(0.8, 0.8, 0.8, 1)
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
