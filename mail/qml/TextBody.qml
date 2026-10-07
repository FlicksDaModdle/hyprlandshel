import QtQuick
import Hyprshell

// A plain-text message: as written, with links that work and quoted
// lines set back.
Item {
    id: tb
    property var body
    property bool allowRemote: false
    implicitHeight: txt.implicitHeight + 8
    height: implicitHeight

    function render(t) {
        const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        const quoteInk = Appearance.ink3;
        return (t || "").replace(/\r/g, "").split("\n").map(l => {
            let line = esc(l).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1">$1</a>').replace(/  /g, " &nbsp;");
            if (/^\s*&gt;/.test(line)) line = '<span style="color:' + quoteInk + '">' + line + '</span>';
            return line;
        }).join("<br>");
    }

    TextEdit {
        id: txt
        width: parent.width
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.RichText
        text: tb.body ? tb.render(tb.body.text) : ""
        color: Appearance.ink
        font.family: Appearance.fontFamily
        font.pixelSize: Appearance.fs(13.5)
        selectionColor: Appearance.accent
        selectedTextColor: Appearance.inkOnAccent
        onLinkActivated: link => Qt.openUrlExternally(link)
        HoverHandler { enabled: txt.hoveredLink !== ""; cursorShape: Qt.PointingHandCursor }
    }
}
