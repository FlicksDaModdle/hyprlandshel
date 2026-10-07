import QtQuick
import Hyprshell
import Hyprshell.Backend
import "Snooze.js" as Snooze

// The middle column: what is in the mailbox (or matches the search), a
// conversation a row; above it, the mailbox's name, or what can be done to
// the rows picked.
Item {
    id: list
    property var frame
    property int current: -1
    // For the rows, whose own `list` property would shadow the id.
    readonly property var listRef: list

    readonly property var titles: ({
        inbox: "Inbox", flagged: "Flagged", snoozed: "Snoozed", drafts: "Drafts", sent: "Sent",
        outbox: "Scheduled", archive: "Archive", attachments: "Attachments", junk: "Junk", trash: "Bin"
    })
    readonly property string title: {
        if (Mail.searching) return "Search";
        const p = Mail.place;
        if (p.view === "folder") return p.folder.split("/").pop() === "INBOX" ? "Inbox" : p.folder.split("/").pop();
        const t = list.titles[p.view] || "";
        const a = p.account ? Mail.accountById(p.account) : null;
        return a ? (a.name || a.email) + (p.view !== "inbox" ? " · " + t : "") : t;
    }
    readonly property bool special: Mail.place.view === "drafts" || Mail.place.view === "outbox"

    function step(d) {
        const n = Mail.items.length;
        if (n === 0) return;
        list.current = Math.max(0, Math.min(n - 1, list.current + d));
        listView.positionViewAtIndex(list.current, ListView.Contain);
        if (Mail.openId >= 0) Mail.open(Mail.items[list.current].id);
    }
    function toggle(id, index) {
        const s = Mail.selected.slice();
        const i = s.indexOf(id);
        if (i >= 0) s.splice(i, 1); else s.push(id);
        Mail.selected = s;
        Mail.anchorIndex = index;
    }
    function range(index) {
        const a = Mail.anchorIndex < 0 ? index : Mail.anchorIndex;
        const lo = Math.min(a, index), hi = Math.max(a, index);
        Mail.selected = Mail.items.slice(lo, hi + 1).map(x => x.id);
    }
    function snoozeMenu(ids, item) {
        const p = item.mapToItem(null, 0, 0);
        list.frame.menu.openAt(p.x - 200, p.y, Snooze.choices(Date.now()).map(c => ({
            n: c.n + " — " + Mail.when(c.at), icon: "clock", run: () => Mail.snooze(ids, c.at)
        })));
    }
    function menuFor(x, y, ids) {
        const one = Mail.items.find(r => r.id === ids[0]) || {};
        const folders = Mail.folders.filter(f => f.account === one.account && f.selectable && f.path !== one.folder);
        const entries = [
            { n: one.seen && one.unreadCount === 0 ? "Mark as unread" : "Mark as read", icon: "mailOpen",
              run: () => Mail.setRead(ids, !(one.seen && one.unreadCount === 0)) },
            { n: one.anyFlagged ? "Remove flag" : "Flag", icon: "flag", run: () => Mail.setFlag(ids, !one.anyFlagged) },
            { n: "Snooze", icon: "clock", sub: Snooze.choices(Date.now()).map(c => ({ n: c.n + " — " + Mail.when(c.at), run: () => Mail.snooze(ids, c.at) })) },
            { n: Mail.place.view === "archive" ? "Move to Inbox" : "Archive", icon: "archive", rule: true, run: () => Mail.archive(ids) },
            { n: "Move to", icon: "folder", sub: folders.map(f => ({ n: f.path, icon: "folder", run: () => Mail.moveTo(ids, f.account, f.path) })) },
            { n: Mail.place.view === "junk" ? "Not junk" : "Junk", icon: "alert", run: () => Mail.spam(ids) },
            { n: Mail.place.view === "trash" ? "Delete for good" : "Move to the bin", icon: "trash", danger: true, run: () => Mail.trash(ids) }
        ];
        if (Mail.place.view === "snoozed") entries.splice(2, 1, { n: "Unsnooze", icon: "clock", run: () => Mail.unsnooze(ids) });
        list.frame.menu.openAt(x, y, entries);
    }

    // ── header ────────────────────────────────────────────────────────────
    Item {
        id: head
        width: parent.width
        height: 52
        Row {
            visible: Mail.selected.length === 0
            x: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: list.title
                font.pixelSize: Appearance.fs(16)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: list.special ? "" : Mail.loading && Mail.items.length === 0 ? "Loading…" : Mail.total > 0 ? Mail.total.toLocaleString() : ""
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }
        }
        // The rows picked: what to do with them.
        Row {
            visible: Mail.selected.length > 0
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            ToolButton { icon: "x"; onClicked: Mail.selected = [] }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Mail.selected.length + "  "
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
            }
            ToolButton { icon: "archive"; onClicked: Mail.archive(Mail.selected) }
            ToolButton { icon: "trash"; onClicked: Mail.trash(Mail.selected) }
            ToolButton { icon: "mailOpen"; onClicked: Mail.setRead(Mail.selected, true) }
            ToolButton { icon: "flag"; onClicked: Mail.setFlag(Mail.selected, true) }
            ToolButton { id: snzBtn; icon: "clock"; onClicked: list.snoozeMenu(Mail.selected, snzBtn) }
            ToolButton { id: moreBtn; icon: "moreHorizontal"; onClicked: { const p = moreBtn.mapToItem(null, 0, moreBtn.height); list.menuFor(p.x, p.y, Mail.selected); } }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: Mail.selected.length === 0 && !list.special
            ToolButton {
                icon: "check"
                onClicked: Mail.selected = Mail.items.map(x => x.id)
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── conversations ─────────────────────────────────────────────────────
    ListView {
        id: listView
        visible: !list.special
        anchors.top: head.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 4
        clip: true
        model: Mail.items
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        delegate: MessageRow { list: listRef }
        // More when the end comes into view.
        onAtYEndChanged: if (atYEnd && Mail.items.length < Mail.total && !Mail.loading && !Mail.searching) Mail.refresh(true)
        footer: Item {
            width: listView.width
            height: Mail.items.length < Mail.total ? 40 : 10
            StyledText {
                anchors.centerIn: parent
                visible: Mail.items.length < Mail.total
                text: "Loading more…"
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
        }
    }
    SmoothScroll { target: listView; anchors.fill: listView; z: 5; visible: listView.visible }
    ScrollBar { target: listView; anchors.top: listView.top; anchors.bottom: listView.bottom; visible: listView.visible }

    // Nothing here.
    Column {
        visible: !list.special && Mail.items.length === 0 && !Mail.loading
        anchors.centerIn: listView
        spacing: 10
        MonoIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: Mail.searching ? "search" : Mail.place.view === "inbox" ? "inbox" : "mail"
            size: 40
            inkColor: Appearance.ink3
            accentColor: Appearance.accent
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Mail.accounts.length === 0 ? "No accounts yet"
                : Mail.searching ? "Nothing matches"
                : Mail.place.view === "inbox" ? "All caught up" : "Nothing here"
            font.pixelSize: Appearance.fs(14)
            font.weight: Font.DemiBold
            color: Appearance.ink2
        }
        DialogButton {
            visible: Mail.accounts.length === 0
            anchors.horizontalCenter: parent.horizontalCenter
            primary: true
            text: "Add an account"
            onTriggered: list.frame.openSetup(null)
        }
    }

    // ── drafts and scheduled mail ─────────────────────────────────────────
    ListView {
        id: sideList
        visible: list.special
        anchors.top: head.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 4
        clip: true
        model: Mail.place.view === "drafts" ? Mail.drafts : Mail.outbox
        delegate: Item {
            id: sRow
            required property var modelData
            readonly property bool isDraft: Mail.place.view === "drafts"
            readonly property var d: isDraft ? modelData.draft : modelData
            width: sideList.width
            height: 66
            Rectangle {
                anchors.fill: parent
                anchors.margins: 3
                anchors.leftMargin: 6; anchors.rightMargin: 6
                radius: Appearance.rSm
                color: sArea.containsMouse ? Appearance.hover : "transparent"
            }
            StyledText {
                x: 20; y: 12
                width: parent.width - 120
                elide: Text.ElideRight
                text: sRow.isDraft ? ((sRow.d.to || []).map(t => t.name || t.email).join(", ") || "(no recipient)") : sRow.d.summary
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
            }
            StyledText {
                x: 20; y: 34
                width: parent.width - 40
                elide: Text.ElideRight
                text: sRow.isDraft ? (sRow.d.subject || "(no subject)") : (sRow.d.error ? "Not sent: " + sRow.d.error : "Sends " + Mail.when(sRow.d.sendAt * 1000))
                font.pixelSize: Appearance.fs(12)
                color: sRow.d.error ? Appearance.accent : Appearance.ink3
            }
            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: 16
                y: 12
                text: sRow.isDraft ? Mail.shortDate(sRow.modelData.updated) : ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
            MouseArea {
                id: sArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: m => {
                    const p = mapToItem(null, m.x, m.y);
                    if (sRow.isDraft) {
                        if (m.button === Qt.RightButton)
                            list.frame.menu.openAt(p.x, p.y, [{ n: "Delete draft", icon: "trash", danger: true, run: () => Mail.call("drafts.delete", { id: sRow.modelData.id }) }]);
                        else Mail.newMessage(Object.assign({}, sRow.d, { draftId: sRow.modelData.id }));
                        return;
                    }
                    list.frame.menu.openAt(p.x, p.y, [
                        { n: "Send now", icon: "send", run: () => Mail.call("outbox.sendNow", { id: sRow.d.id }) },
                        { n: "Edit", icon: "pencil", run: () => Mail.call("outbox.cancel", { id: sRow.d.id }, (ok, r) => { if (ok && r) Mail.newMessage(Mail.composeFromRequest(r)); }) },
                        { n: "Cancel sending", icon: "x", danger: true, rule: true, run: () => Mail.call("outbox.cancel", { id: sRow.d.id }) }
                    ]);
                }
            }
        }
    }
    Column {
        visible: list.special && sideList.count === 0
        anchors.centerIn: sideList
        spacing: 10
        MonoIcon { anchors.horizontalCenter: parent.horizontalCenter; name: Mail.place.view === "drafts" ? "pencil" : "calendar"; size: 40; inkColor: Appearance.ink3; accentColor: Appearance.accent }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Mail.place.view === "drafts" ? "No drafts" : "Nothing scheduled"
            font.pixelSize: Appearance.fs(14); font.weight: Font.DemiBold; color: Appearance.ink2
        }
    }
}
