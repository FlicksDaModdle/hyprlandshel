import QtQuick
import Hyprshell

// One conversation in the list: who, when, what about, the start of it,
// and marks for attachments, invitations, flags and how many messages.
// Hovered, it offers the quick actions; dragged, it carries the selection
// to a folder.
Item {
    id: row
    required property var modelData
    required property int index
    property var list
    readonly property var m: modelData
    readonly property bool unread: m.unreadCount > 0 || !m.seen
    readonly property bool picked: Mail.selected.indexOf(m.id) >= 0
    readonly property bool opened: Mail.openId === m.id
    readonly property bool sentView: Mail.place.view === "sent" || Mail.place.view === "drafts"
    readonly property string who: {
        if (row.sentView) {
            const t = (m.to || [])[0];
            return t ? "To: " + (t.name || t.email) : "(no recipient)";
        }
        return m.fromName || m.fromAddr || "(unknown)";
    }
    property var dragIds: []

    width: ListView.view ? ListView.view.width : 300
    height: 78

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        anchors.topMargin: 2
        anchors.bottomMargin: 2
        radius: Appearance.rSm
        color: row.opened ? Appearance.sel : row.picked ? Appearance.sel : area.containsMouse ? Appearance.hover : "transparent"
        border.width: row.list && row.list.current === row.index && !row.opened ? 1 : 0
        border.color: Appearance.edge
    }
    // Unread: the accent mark at the edge.
    Rectangle {
        visible: row.unread
        x: 9
        anchors.verticalCenter: parent.verticalCenter
        width: 4; height: 4; radius: 2
        color: Appearance.accent
    }

    // The avatar, or a tick when picked (clicking it picks).
    Item {
        id: lead
        x: 18; y: 12
        width: 34; height: 34
        Avatar {
            visible: !row.picked
            name: row.sentView ? ((row.m.to || [])[0] || {}).name || "" : row.m.fromName
            email: row.sentView ? ((row.m.to || [])[0] || {}).email || "" : row.m.fromAddr
            size: 34
        }
        Rectangle {
            visible: row.picked
            anchors.fill: parent
            radius: width / 2
            color: Appearance.accent
            MonoIcon { anchors.centerIn: parent; name: "check"; size: 18; inkColor: Appearance.inkOnAccent; monochrome: true }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: row.list.toggle(row.m.id, row.index)
        }
    }

    StyledText {
        id: whoText
        anchors.left: lead.right
        anchors.leftMargin: 12
        anchors.right: dateText.left
        anchors.rightMargin: 8
        y: 11
        elide: Text.ElideRight
        text: row.who + (row.m.count > 1 ? "  " : "")
        font.pixelSize: Appearance.fs(13)
        font.weight: row.unread ? Font.Bold : Font.Medium
        color: Appearance.ink
        StyledText {
            visible: row.m.count > 1
            x: Math.min(parent.implicitWidth, parent.width) - 4
            anchors.baseline: parent.baseline
            text: row.m.count
            font.pixelSize: Appearance.fs(11)
            color: Appearance.ink3
        }
    }
    StyledText {
        id: dateText
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.baseline: whoText.baseline
        visible: !area.containsMouse
        text: row.m.snoozedUntil ? "⏰ " + Mail.when(row.m.snoozedUntil * 1000) : Mail.shortDate(row.m.sortDate || row.m.date)
        font.pixelSize: Appearance.fs(11.5)
        font.weight: row.unread ? Font.DemiBold : Font.Normal
        color: row.unread ? Appearance.accent : Appearance.ink3
    }
    Row {
        id: marks
        anchors.right: parent.right
        anchors.rightMargin: 16
        y: 33
        spacing: 4
        MonoIcon { visible: row.m.invite; name: "calendar"; size: 14; inkColor: Appearance.ink3; accentColor: Appearance.accent }
        MonoIcon { visible: row.m.attachments; name: "paperclip"; size: 14; inkColor: Appearance.ink3; accentColor: Appearance.accent }
        MonoIcon { visible: row.m.anyFlagged || row.m.flagged; name: "flag"; size: 14; inkColor: Appearance.accent; accentColor: Appearance.accent }
    }
    StyledText {
        id: subj
        anchors.left: whoText.left
        anchors.right: marks.left
        anchors.rightMargin: 6
        y: 32
        elide: Text.ElideRight
        text: row.m.subject || "(no subject)"
        font.pixelSize: Appearance.fs(12.5)
        font.weight: row.unread ? Font.DemiBold : Font.Normal
        color: Appearance.ink
    }
    StyledText {
        anchors.left: whoText.left
        anchors.right: parent.right
        anchors.rightMargin: 16
        y: 51
        elide: Text.ElideRight
        maximumLineCount: 1
        text: row.m.snippet
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.leftMargin: 56
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        drag.target: dragProxy
        drag.threshold: 8
        onPressed: m => { dragProxy.x = m.x; dragProxy.y = m.y; }
        onClicked: m => {
            if (m.button === Qt.RightButton) {
                if (!row.picked) Mail.selected = [row.m.id];
                const p = mapToItem(null, m.x, m.y);
                row.list.menuFor(p.x, p.y, Mail.selected.length > 0 ? Mail.selected : [row.m.id]);
                return;
            }
            if (m.modifiers & Qt.ControlModifier) { row.list.toggle(row.m.id, row.index); return; }
            if (m.modifiers & Qt.ShiftModifier) { row.list.range(row.index); return; }
            Mail.selected = [];
            row.list.current = row.index;
            Mail.anchorIndex = row.index;
            if (Mail.place.view === "drafts") return;
            Mail.open(row.m.id);
        }
        onReleased: dragProxy.Drag.drop()
    }

    // Quick actions on hover.
    Row {
        visible: area.containsMouse && !Mail.searching
        anchors.right: parent.right
        anchors.rightMargin: 10
        y: 6
        spacing: 0
        Repeater {
            model: [
                { icon: "archive", act: () => Mail.archive([row.m.id]) },
                { icon: "trash", act: () => Mail.trash([row.m.id]) },
                { icon: row.unread ? "mailOpen" : "mail", act: () => Mail.setRead([row.m.id], row.unread) },
                { icon: "clock", act: () => row.list.snoozeMenu([row.m.id], hoverRow) }
            ]
            Rectangle {
                id: qa
                required property var modelData
                width: 28; height: 26
                radius: Appearance.rSm
                color: qaArea.containsMouse ? Appearance.sel : "transparent"
                MonoIcon { anchors.centerIn: parent; name: qa.modelData.icon; size: 16; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                MouseArea {
                    id: qaArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: qa.modelData.act()
                }
            }
        }
    }
    Item { id: hoverRow; anchors.right: parent.right; anchors.rightMargin: 10; y: 30 }

    // What is dragged: the selection when this row is in it, else this row.
    Item {
        id: dragProxy
        width: 1; height: 1
        Drag.active: area.drag.active
        Drag.keys: ["hyprshell-mail-ids"]
        Drag.source: row
        Drag.hotSpot.x: 0
        Drag.hotSpot.y: 0
        Drag.onActiveChanged: if (Drag.active) row.dragIds = row.picked ? Mail.selected.slice() : [row.m.id]
        Rectangle {
            visible: area.drag.active
            x: 10; y: 10
            width: dragLabel.implicitWidth + 22
            height: 28
            radius: Appearance.rSm
            color: Appearance.accent
            StyledText {
                id: dragLabel
                anchors.centerIn: parent
                text: row.dragIds.length > 1 ? row.dragIds.length + " conversations" : (row.m.subject || "(no subject)").slice(0, 40)
                font.pixelSize: Appearance.fs(12)
                font.weight: Font.DemiBold
                color: Appearance.inkOnAccent
            }
        }
        onXChanged: if (!area.drag.active) {}
    }
}
