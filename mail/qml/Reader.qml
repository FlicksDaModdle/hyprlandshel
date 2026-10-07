import QtQuick
import Hyprshell
import Hyprshell.Backend
import "Snooze.js" as Snooze

// The conversation open on the right: its subject and what can be done to
// it, then each message, the older ones folded to a line.
Item {
    id: reader
    property var frame
    readonly property var last: Mail.thread.length > 0 ? Mail.thread[Mail.thread.length - 1] : null
    readonly property var lastBody: reader.last ? Mail.bodies[reader.last.id] : null
    readonly property var ids: Mail.openId >= 0 ? [Mail.openId] : []
    readonly property bool flagged: Mail.thread.some(m => m.flagged)

    // Nothing open.
    Column {
        visible: Mail.openId < 0
        anchors.centerIn: parent
        spacing: 10
        MonoIcon { anchors.horizontalCenter: parent.horizontalCenter; name: "mail"; size: 48; inkColor: Appearance.ink3; accentColor: Appearance.accent }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Mail.selected.length > 1 ? Mail.selected.length + " conversations picked" : "Nothing open"
            font.pixelSize: Appearance.fs(14); font.weight: Font.DemiBold; color: Appearance.ink2
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "j / k to move, Enter to open, c to write, / to search"
            font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3
        }
    }

    // ── the conversation's bar ────────────────────────────────────────────
    Item {
        id: bar
        visible: Mail.openId >= 0
        width: parent.width
        height: 52
        Row {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            ToolButton { visible: reader.frame.single; icon: "chevronLeft"; onClicked: Mail.closeThread() }
            ToolButton { icon: "archive"; onClicked: Mail.archive(reader.ids) }
            ToolButton { icon: "trash"; onClicked: Mail.trash(reader.ids) }
            ToolButton { icon: "alert"; onClicked: Mail.spam(reader.ids) }
            Item { width: 8; height: 1 }
            ToolButton { icon: "mail"; onClicked: { Mail.setRead(reader.ids, false); Mail.closeThread(); } }
            ToolButton { icon: "flag"; checked: reader.flagged; onClicked: Mail.setFlag(reader.ids, !reader.flagged) }
            ToolButton {
                id: snz
                icon: "clock"
                onClicked: {
                    const p = snz.mapToItem(null, 0, snz.height);
                    reader.frame.menu.openAt(p.x, p.y, Snooze.choices(Date.now()).map(c => ({ n: c.n + " — " + Mail.when(c.at), icon: "clock", run: () => Mail.snooze(reader.ids, c.at) })));
                }
            }
            ToolButton {
                id: mv
                icon: "folder"
                onClicked: {
                    const one = reader.last || {};
                    const p = mv.mapToItem(null, 0, mv.height);
                    reader.frame.menu.openAt(p.x, p.y, Mail.folders.filter(f => f.account === one.account && f.selectable && f.path !== one.folder)
                        .map(f => ({ n: f.path, icon: "folder", run: () => Mail.moveTo(reader.ids, f.account, f.path) })));
                }
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            ToolButton { icon: "reply"; text: reader.width > 700 ? "Reply" : ""; active: !!reader.lastBody; onClicked: Mail.reply(reader.lastBody, false) }
            ToolButton { icon: "replyAll"; active: !!reader.lastBody; onClicked: Mail.reply(reader.lastBody, true) }
            ToolButton { icon: "forward"; active: !!reader.lastBody; onClicked: Mail.forward(reader.lastBody) }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── the messages ──────────────────────────────────────────────────────
    Flickable {
        id: flick
        visible: Mail.openId >= 0
        anchors.top: bar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: col.implicitHeight + 40
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Column {
            id: col
            x: Math.max(20, (flick.width - 900) / 2)
            y: 20
            width: Math.min(900, flick.width - 40)
            spacing: 10
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: reader.last ? (reader.last.subject || "(no subject)") : ""
                font.pixelSize: Appearance.fs(20)
                font.weight: Font.DemiBold
            }
            Item { width: 1; height: 4 }
            Repeater {
                model: Mail.thread
                MessageCard {
                    required property var modelData
                    required property int index
                    width: col.width
                    summary: modelData
                    isLast: index === Mail.thread.length - 1
                    frame: reader.frame
                }
            }
            // Answering, at the foot.
            Row {
                visible: !!reader.lastBody
                spacing: 8
                topPadding: 6
                DialogButton { text: "Reply"; onTriggered: Mail.reply(reader.lastBody, false) }
                DialogButton { text: "Reply all"; visible: !!reader.lastBody && ((reader.lastBody.to || []).length + (reader.lastBody.cc || []).length) > 1; onTriggered: Mail.reply(reader.lastBody, true) }
                DialogButton { text: "Forward"; onTriggered: Mail.forward(reader.lastBody) }
            }
        }
    }
    SmoothScroll { target: flick; anchors.fill: flick; z: 5; visible: flick.visible }
    ScrollBar { target: flick; anchors.top: flick.top; anchors.bottom: flick.bottom; visible: flick.visible }
}
