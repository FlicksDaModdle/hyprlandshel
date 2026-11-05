import QtQuick
import Hyprshell

// "Today", "Yesterday", "Earlier this week" — the rule that breaks a
// date-sorted listing into runs you can skim.
//
// As Explorer's: a chevron, the group's name and how many it holds, and a
// click anywhere on it folds the group away or opens it again.
//
// Set in the same tracked small caps as the column headings, because that
// is already this window's word for "this labels what is under it", and
// ruled on the right so the heading reads as a band rather than as a row
// that happens to have no file in it.
Item {
    id: heading

    required property string text
    property int count: 0
    property bool collapsed: false
    property bool firstOne: false
    signal toggled()

    implicitHeight: heading.firstOne ? 30 : 38
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: heading.firstOne ? 2 : 8
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        radius: 6
        color: area.containsMouse ? Appearance.hover : "transparent"
    }

    MonoIcon {
        id: chevron
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: label.verticalCenter
        name: heading.collapsed ? "chevronRight" : "chevronDown"
        size: 12
        monochrome: true
        inkColor: area.containsMouse ? Appearance.ink2 : Appearance.ink3
    }

    StyledText {
        id: label
        anchors.left: chevron.right
        anchors.leftMargin: 6
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        text: heading.text.toUpperCase()
        font.pixelSize: Appearance.fs(10.5)
        font.weight: Font.DemiBold
        font.letterSpacing: 1.05
        color: area.containsMouse ? Appearance.ink2 : Appearance.ink3
    }

    StyledText {
        id: countLabel
        anchors.left: label.right
        anchors.leftMargin: 7
        anchors.baseline: label.baseline
        text: heading.count
        font.pixelSize: Appearance.fs(10.5)
        color: Appearance.ink3
        opacity: 0.8
    }

    Rectangle {
        anchors.left: countLabel.right
        anchors.leftMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: label.verticalCenter
        height: 1
        color: Appearance.rule
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.topMargin: heading.firstOne ? 2 : 8
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: heading.toggled()
    }
}
