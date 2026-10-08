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

    // The accent pill, which slides from the old choice to the new one
    // rather than one segment going out as another lights up.
    readonly property int activeIndex: {
        for (let i = 0; i < options.length; i++) if (valueOf(options[i]) === value) return i;
        return -1;
    }
    readonly property Item activeItem: {
        // Re-read when the delegates are made or resized.
        const n = segs.count + track.implicitWidth;
        return n >= 0 && activeIndex >= 0 ? segs.itemAt(activeIndex) : null;
    }
    Rectangle {
        id: thumb
        visible: root.activeItem !== null
        x: track.x + (root.activeItem ? root.activeItem.x : 0)
        y: track.y
        width: root.activeItem ? root.activeItem.width : 0
        height: track.height
        radius: Config.Appearance.rSm
        color: Config.Appearance.accent
        // Not on the first placing: only a change of choice slides.
        property bool ready: false
        Component.onCompleted: Qt.callLater(() => thumb.ready = true)
        Behavior on x { enabled: thumb.ready; Spring { ms: 360 } }
        Behavior on width { enabled: thumb.ready; Spring { ms: 360 } }
    }

    Row {
        id: track
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            id: segs
            model: root.options

            Rectangle {
                id: seg
                required property var modelData
                readonly property bool active: root.valueOf(modelData) === root.value

                radius: Config.Appearance.rSm
                color: !active && segHover.hovered ? Config.Appearance.sel : "transparent"
                implicitWidth: segLabel.implicitWidth + root.segmentPadding * 2
                implicitHeight: 26
                Behavior on color { ColorAnimation { duration: Config.Appearance.anim(140) } }

                StyledText {
                    id: segLabel
                    anchors.centerIn: parent
                    text: root.labelOf(seg.modelData)
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                    color: seg.active ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                    Behavior on color { ColorAnimation { duration: Config.Appearance.anim(160) } }
                }

                HoverHandler { id: segHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: root.selected(root.valueOf(seg.modelData))
                }
            }
        }
    }
}
