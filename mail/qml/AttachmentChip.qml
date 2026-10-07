import QtQuick
import QtQuick.Dialogs
import Hyprshell
import Hyprshell.Backend

// An attachment: its kind, name and size. Click to open it; the menu saves
// it to Downloads, or somewhere chosen, or shows where it went.
Rectangle {
    id: chip
    property var att
    property int messageId: -1
    property var frame
    property string savedTo: ""

    readonly property string glyph: {
        const m = (chip.att.mime || "").toLowerCase();
        if (m === "application/pdf") return "pdf";
        if (m.startsWith("image/")) return "image";
        if (m.startsWith("audio/")) return "music";
        if (m.startsWith("video/")) return "film";
        if (m.indexOf("zip") >= 0 || m.indexOf("compressed") >= 0 || m.indexOf("tar") >= 0) return "archive";
        if (m.indexOf("sheet") >= 0 || m.indexOf("excel") >= 0 || m === "text/csv") return "sheet";
        if (m.indexOf("presentation") >= 0 || m.indexOf("powerpoint") >= 0) return "slides";
        if (m.indexOf("word") >= 0 || m.startsWith("text/")) return "doc";
        if (m === "text/calendar") return "calendar";
        return "file";
    }
    width: Math.min(280, row.implicitWidth + 24)
    height: 44
    radius: Appearance.rSm
    color: area.containsMouse ? Appearance.sel : Appearance.hover
    border.width: 1
    border.color: Appearance.rule

    function save(dest, then) {
        Mail.call("part.save", { id: chip.messageId, index: chip.att.index, dest: dest || "" }, (ok, r) => {
            if (!ok) return;
            chip.savedTo = r.path;
            if (then) then(r.path);
        });
    }

    Row {
        id: row
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 9
        MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: chip.glyph; size: 22; inkColor: Appearance.ink2; accentColor: Appearance.accent }
        Column {
            anchors.verticalCenter: parent.verticalCenter
            StyledText {
                width: Math.min(implicitWidth, 200)
                elide: Text.ElideMiddle
                text: chip.att.name
                font.pixelSize: Appearance.fs(12)
                font.weight: Font.Medium
            }
            StyledText {
                text: Mail.size(chip.att.size)
                font.pixelSize: Appearance.fs(11)
                color: Appearance.ink3
            }
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: m => {
            if (m.button === Qt.LeftButton) { chip.save("", p => MailApp.openFile(p)); return; }
            const p = mapToItem(null, m.x, m.y);
            chip.frame.menu.openAt(p.x, p.y, [
                { n: "Open", icon: "folderOpen", run: () => chip.save("", f => MailApp.openFile(f)) },
                { n: "Save to Downloads", icon: "download", run: () => chip.save(MailApp.downloadsDir(), f => Mail.toast("Saved to " + f, false, "Show", () => MailApp.showInFolder(f))) },
                { n: "Save as…", icon: "download", run: () => saveDialog.open() },
            ]);
        }
    }
    FileDialog {
        id: saveDialog
        fileMode: FileDialog.SaveFile
        currentFile: "file://" + MailApp.downloadsDir() + "/" + chip.att.name
        onAccepted: chip.save(MailApp.urlToPath(selectedFile.toString()), f => Mail.toast("Saved to " + f, false, "Show", () => MailApp.showInFolder(f)))
    }
}
