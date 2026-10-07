import QtQuick
import QtQuick.Dialogs
import Hyprshell
import Hyprshell.Backend

// One message of a conversation. Folded, a line: who and the start of it.
// Open: who to whom and when, an invitation if it is one, the body, and
// its attachments.
PanelSurface {
    id: card
    property var summary
    property bool isLast: false
    property var frame
    readonly property var body: Mail.bodies[card.summary.id] || null
    property bool expanded: card.isLast || !card.summary.seen
    property bool showDetails: false
    // Images from elsewhere: off until asked, per message or per sender.
    property bool remoteNow: false
    readonly property bool remoteOk: card.remoteNow || (card.body && card.body.remoteAllowed) || Mail.setting("remoteImages", []).indexOf("*") >= 0

    // Every attachment into one folder: the Files app's folder dialog, or
    // Qt's when Files isn't installed. Beside what is there, never over it.
    function saveAll() {
        if (!MailApp.hasFiles) { folderDialog.open(); return; }
        MailApp.pick({ directory: true, start: MailApp.downloadsDir() }, paths => {
            if (paths && paths.length > 0) card.saveAllTo(paths[0]);
        });
    }
    function saveAllTo(dir) {
        const atts = card.body.attachments;
        let left = atts.length, saved = 0, last = "";
        const where = MailApp.prettyPath(dir);
        for (const a of atts) {
            Mail.call("part.save", { id: card.summary.id, index: a.index, dest: dir }, (ok, r) => {
                if (ok) { saved++; last = r.path; }
                if (--left > 0) return;
                const msg = saved === atts.length ? "Saved " + saved + " files to " + where
                                                  : "Saved " + saved + " of " + atts.length + " files to " + where;
                Mail.toast(msg, saved < atts.length, last ? "Show" : "", last ? () => MailApp.showInFolder(last) : null);
            });
        }
    }
    FolderDialog {
        id: folderDialog
        currentFolder: "file://" + MailApp.downloadsDir()
        onAccepted: card.saveAllTo(MailApp.urlToPath(selectedFolder.toString()))
    }

    showSeam: false
    color: Appearance.dialog
    height: inner.implicitHeight + 28
    onExpandedChanged: if (expanded) Mail.loadBody(card.summary.id)

    Column {
        id: inner
        x: 16; y: 14
        width: parent.width - 32
        spacing: 12

        // Who, when.
        Item {
            width: parent.width
            height: 40
            Avatar { id: av; name: card.summary.fromName; email: card.summary.fromAddr; size: 38 }
            StyledText {
                id: fromText
                anchors.left: av.right
                anchors.leftMargin: 12
                y: card.expanded ? 1 : 10
                text: card.summary.fromName || card.summary.fromAddr
                font.pixelSize: Appearance.fs(13.5)
                font.weight: Font.DemiBold
            }
            StyledText {
                visible: card.expanded && card.summary.fromName !== ""
                anchors.left: fromText.right
                anchors.leftMargin: 8
                anchors.baseline: fromText.baseline
                text: "<" + card.summary.fromAddr + ">"
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }
            StyledText {
                visible: card.expanded
                anchors.left: fromText.left
                anchors.right: parent.right
                anchors.rightMargin: 160
                y: 22
                elide: Text.ElideRight
                text: card.body ? "to " + (card.body.to || []).concat(card.body.cc || []).map(x => x.name || x.email).join(", ") + "  ▾" : ""
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.showDetails = !card.showDetails }
            }
            StyledText {
                visible: !card.expanded
                anchors.left: fromText.right
                anchors.leftMargin: 12
                anchors.right: dateText.left
                anchors.rightMargin: 12
                anchors.baseline: fromText.baseline
                elide: Text.ElideRight
                text: card.summary.snippet
                font.pixelSize: Appearance.fs(12.5)
                color: Appearance.ink3
            }
            StyledText {
                id: dateText
                anchors.right: tools.left
                anchors.rightMargin: 6
                anchors.verticalCenter: fromText.verticalCenter
                text: card.expanded ? Mail.longDate(card.summary.date) : Mail.shortDate(card.summary.date)
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
            Row {
                id: tools
                visible: card.expanded && !!card.body
                anchors.right: parent.right
                anchors.verticalCenter: fromText.verticalCenter
                ToolButton { icon: "reply"; onClicked: Mail.reply(card.body, false) }
                ToolButton {
                    id: moreBtn
                    icon: "moreHorizontal"
                    onClicked: {
                        const p = moreBtn.mapToItem(null, 0, moreBtn.height);
                        card.frame.menu.openAt(p.x - 200, p.y, [
                            { n: "Reply all", icon: "replyAll", run: () => Mail.reply(card.body, true) },
                            { n: "Forward", icon: "forward", run: () => Mail.forward(card.body) },
                            { n: "Mark unread from here", icon: "mail", rule: true, run: () => Mail.call("flag", { ids: [card.summary.id], flag: "seen", value: false }) },
                            { n: card.summary.flagged ? "Remove flag" : "Flag this message", icon: "flag", run: () => Mail.call("flag", { ids: [card.summary.id], flag: "flagged", value: !card.summary.flagged }) },
                            { n: "Show images from " + card.summary.fromAddr + " always", icon: "image", rule: true,
                              run: () => { const l = Mail.setting("remoteImages", []).concat([card.summary.fromAddr]); Mail.setSetting("remoteImages", l); card.remoteNow = true; } },
                            { n: "Unsubscribe", icon: "x", active: !!(card.body && card.body.unsubscribe),
                              run: () => Qt.openUrlExternally(card.body.unsubscribe) }
                        ]);
                    }
                }
            }
            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: card.expanded ? 260 : 0
                z: -1
                cursorShape: Qt.PointingHandCursor
                onClicked: card.expanded = !card.expanded || card.isLast
            }
        }

        // Every address, when asked.
        Column {
            visible: card.expanded && card.showDetails && !!card.body
            width: parent.width
            spacing: 3
            Repeater {
                model: card.body ? [["From", card.body.from], ["To", card.body.to], ["Cc", card.body.cc], ["Reply to", card.body.replyTo]].filter(r => r[1] && r[1].length > 0) : []
                StyledText {
                    required property var modelData
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "<b>" + modelData[0] + ":</b> " + modelData[1].map(x => (x.name ? x.name + " " : "") + "&lt;" + x.email + "&gt;").join(", ")
                    textFormat: Text.StyledText
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink2
                }
            }
        }

        Loader {
            width: parent.width
            active: card.expanded && !!card.body && !!card.body.invite
            visible: active
            sourceComponent: InviteCard { width: parent ? parent.width : 400; body: card.body }
        }

        // Pictures from elsewhere are held back.
        Rectangle {
            visible: card.expanded && !!card.body && !card.remoteOk && card.body.html !== "" && MailApp.hasRemote(card.body.html)
            width: parent.width
            height: 36
            radius: Appearance.rSm
            color: Appearance.hover
            Row {
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "image"; size: 16; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Pictures from the web are hidden — they can tell the sender you opened this."
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink2
                }
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 16
                StyledText {
                    text: "Show"
                    font.pixelSize: Appearance.fs(12); font.weight: Font.DemiBold; color: Appearance.accent
                    MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor; onClicked: card.remoteNow = true }
                }
                StyledText {
                    text: "Always from this sender"
                    font.pixelSize: Appearance.fs(12); font.weight: Font.DemiBold; color: Appearance.accent
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor
                        onClicked: { Mail.setSetting("remoteImages", Mail.setting("remoteImages", []).concat([card.summary.fromAddr])); card.remoteNow = true; }
                    }
                }
            }
        }

        // The body.
        Loader {
            id: bodyLoader
            width: parent.width
            active: card.expanded && !!card.body
            visible: active
            source: !card.body ? ""
                  : card.body.html !== "" && MailApp.hasWebEngine ? "web/WebBody.qml"
                  : card.body.html !== "" ? "RichBody.qml" : "TextBody.qml"
            onLoaded: { item.body = Qt.binding(() => card.body); item.allowRemote = Qt.binding(() => card.remoteOk); }
        }
        StyledText {
            visible: card.expanded && !card.body
            text: "Loading…"
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink3
        }

        // Attachments.
        Flow {
            visible: card.expanded && !!card.body && card.body.attachments.length > 0
            width: parent.width
            spacing: 8
            Repeater {
                model: card.body ? card.body.attachments : []
                AttachmentChip {
                    required property var modelData
                    att: modelData
                    messageId: card.summary.id
                    frame: card.frame
                }
            }
            // Several: all of them into one folder, chosen with Files.
            Rectangle {
                visible: !!card.body && card.body.attachments.length > 1
                width: allRow.implicitWidth + 24
                height: 44
                radius: Appearance.rSm
                color: allArea.containsMouse ? Appearance.sel : "transparent"
                border.width: 1
                border.color: Appearance.rule
                Row {
                    id: allRow
                    anchors.centerIn: parent
                    spacing: 8
                    MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "download"; size: 18; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Save all " + (card.body ? card.body.attachments.length : 0)
                        font.pixelSize: Appearance.fs(12)
                        font.weight: Font.Medium
                    }
                }
                MouseArea {
                    id: allArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: card.saveAll()
                }
            }
        }
    }
}
