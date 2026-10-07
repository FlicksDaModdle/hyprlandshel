import QtQuick
import QtQuick.Dialogs
import Hyprshell
import Hyprshell.Backend

// An attachment: its kind, name and size. Click to open it; the download
// button saves it where you choose, with the Files app's dialog; the menu
// also saves straight to Downloads.
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
    width: Math.min(320, row.implicitWidth + 24 + saveBtn.width + 4)
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
    function saved(f) { Mail.toast("Saved to " + MailApp.prettyPath(f), false, "Show", () => MailApp.showInFolder(f)); }
    // Where to keep it: the Files app's own save dialog, opening in
    // Downloads with the attachment's name; Qt's when Files isn't here.
    function saveAs() {
        if (!MailApp.hasFiles) { saveDialog.open(); return; }
        MailApp.pick({ save: true, name: chip.att.name, start: MailApp.downloadsDir() }, paths => {
            if (paths && paths.length > 0) chip.save(paths[0], chip.saved);
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
                { n: "Save as…", icon: "download", run: () => chip.saveAs() },
                { n: "Save to Downloads", icon: "download", run: () => chip.save(MailApp.downloadsDir(), chip.saved) },
            ].concat(chip.savedTo !== "" && chip.savedTo.indexOf("/parts/") < 0
                     ? [{ n: "Show in Files", icon: "folderOpen", rule: true, run: () => MailApp.showInFolder(chip.savedTo) }] : []));
        }
    }
    // Download: save it somewhere of your choosing.
    Rectangle {
        id: saveBtn
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 30
        height: 30
        radius: Appearance.rSm
        color: saveArea.containsMouse ? Appearance.hover : "transparent"
        MonoIcon { anchors.centerIn: parent; name: "download"; size: 18; inkColor: Appearance.ink2; accentColor: Appearance.accent }
        MouseArea {
            id: saveArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.saveAs()
        }
        ToolTipLite { text: "Save…"; shown: saveArea.containsMouse }
    }
    FileDialog {
        id: saveDialog
        fileMode: FileDialog.SaveFile
        currentFile: "file://" + MailApp.downloadsDir() + "/" + chip.att.name
        onAccepted: chip.save(MailApp.urlToPath(selectedFile.toString()), chip.saved)
    }
}
