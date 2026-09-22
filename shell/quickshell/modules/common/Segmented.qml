import QtQuick
import "../../config" as Config

// Segmented control: a recessed track with the selected option filled in
// accent. The mockup uses it for Theme, Wallpaper tint, Dock position,
// clock format, power profile and so on.
Item {
    id: root

    property var options: []            // array of strings, or { label, value }
    // Bound by the caller to live state; never written from in here.
    property string value: ""
    property real segmentPadding: 14
    signal selected(string value)

    function labelOf(o) { return typeof o === "string" ? o : o.label; }
    function valueOf(o) { return typeof o === "string" ? o : o.value; }

    implicitWidth: track.implicitWidth + 6
    implicitHeight: track.implicitHeight + 6

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rSm
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
    }

    Row {
        id: track
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: root.options

            Rectangle {
                id: seg
                required property var modelData
                readonly property bool active: root.valueOf(modelData) === root.value

                radius: Config.Appearance.rSm
                color: active ? Config.Appearance.accent
                              : (segHover.hovered ? Config.Appearance.sel : "transparent")
                implicitWidth: segLabel.implicitWidth + root.segmentPadding * 2
                implicitHeight: 26
                Behavior on color { ColorAnimation { duration: 140 } }

                StyledText {
                    id: segLabel
                    anchors.centerIn: parent
                    text: root.labelOf(seg.modelData)
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: seg.active ? Config.Appearance.onAccent : Config.Appearance.ink2
                }

                HoverHandler { id: segHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: root.selected(root.valueOf(seg.modelData))
                }
            }
        }
    }
}
