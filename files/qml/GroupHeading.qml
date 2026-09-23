import QtQuick
import Hyprshell

// "Today", "Yesterday", "Earlier this week" — the rule that breaks a
// date-sorted listing into runs you can skim.
//
// Set in the same tracked small caps as the column headings, because that
// is already this window's word for "this labels what is under it", and
// ruled on the right so the heading reads as a band rather than as a row
// that happens to have no file in it.
Item {
    id: heading

    required property string text
    property bool firstOne: false

    implicitHeight: heading.firstOne ? 30 : 38
    height: implicitHeight

    StyledText {
        id: label
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        text: heading.text.toUpperCase()
        font.pixelSize: Appearance.fs(10.5)
        font.weight: Font.DemiBold
        font.letterSpacing: 1.05
        color: Appearance.ink3
    }

    Rectangle {
        anchors.left: label.right
        anchors.leftMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: label.verticalCenter
        height: 1
        color: Appearance.rule
    }
}
