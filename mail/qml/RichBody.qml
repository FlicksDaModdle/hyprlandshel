import QtQuick
import Hyprshell
import Hyprshell.Backend

// A message's HTML in Qt's own rich text, for a build without WebEngine:
// scripts, styles and pictures from the web left out, links opened in the
// browser. Plain next to the real thing, but readable.
Item {
    id: rb
    property var body
    property bool allowRemote: false
    implicitHeight: txt.implicitHeight + 24
    height: implicitHeight
    Rectangle { anchors.fill: parent; radius: Appearance.rSm; color: "white" }
    TextEdit {
        id: txt
        x: 12; y: 12
        width: parent.width - 24
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.RichText
        text: rb.body ? MailApp.richText(rb.body.html, rb.allowRemote) : ""
        color: "#202020"
        font.family: Appearance.fontFamily
        font.pixelSize: Appearance.fs(13.5)
        selectionColor: Appearance.accent
        onLinkActivated: link => Qt.openUrlExternally(link)
        HoverHandler { enabled: txt.hoveredLink !== ""; cursorShape: Qt.PointingHandCursor }
    }
}
