import QtQuick
import Hyprshell
import Hyprshell.Backend

// The mailboxes: every account's inbox and the like together at the top,
// then each account with its own folders, and settings at the foot.
Item {
    id: rail
    property var frame

    readonly property var unified: [
        { view: "inbox",       label: "Inbox",       icon: "inbox" },
        { view: "flagged",     label: "Flagged",     icon: "flag" },
        { view: "snoozed",     label: "Snoozed",     icon: "clock" },
        { view: "drafts",      label: "Drafts",      icon: "pencil" },
        { view: "sent",        label: "Sent",        icon: "send" },
        { view: "outbox",      label: "Scheduled",   icon: "calendar" },
        { view: "archive",     label: "Archive",     icon: "archive" },
        { view: "attachments", label: "Attachments", icon: "paperclip" },
        { view: "junk",        label: "Junk",        icon: "alert" },
        { view: "trash",       label: "Bin",         icon: "trash" }
    ]
    property var collapsed: ({})

    function countFor(view) {
        if (view === "inbox") return Mail.unread > 0 ? String(Mail.unread) : "";
        if (view === "drafts") return Mail.drafts.length > 0 ? String(Mail.drafts.length) : "";
        if (view === "outbox") return Mail.outbox.length > 0 ? String(Mail.outbox.length) : "";
        return "";
    }
    function roleIcon(role) {
        return ({ inbox: "inbox", sent: "send", drafts: "pencil", trash: "trash", junk: "alert", archive: "archive", all: "archive", flagged: "flag" })[role] || "folder";
    }
    function customFolders(acct) {
        return Mail.folders.filter(f => f.account === acct && f.selectable);
    }

    // Compose.
    Rectangle {
        id: composeBtn
        x: 12; y: 12
        width: parent.width - 24
        height: 40
        radius: Appearance.rSm
        color: composeArea.containsMouse ? Qt.lighter(Appearance.accent, 1.1) : Appearance.accent
        Row {
            anchors.centerIn: parent
            spacing: 9
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "pencil"; size: 17
                inkColor: Appearance.inkOnAccent; accentColor: Appearance.inkOnAccent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Compose"
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
                color: Appearance.inkOnAccent
            }
        }
        MouseArea {
            id: composeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Mail.newMessage()
        }
    }

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    Flickable {
        id: flick
        anchors.top: composeBtn.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: foot.top
        contentHeight: col.implicitHeight + 10
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Column {
            id: col
            width: rail.width
            Repeater {
                model: rail.unified
                RailRow {
                    required property var modelData
                    width: col.width
                    visible: !(modelData.view === "outbox" && Mail.outbox.length === 0)
                    height: visible ? implicitHeight : 0
                    icon: modelData.icon
                    label: modelData.label
                    count: rail.countFor(modelData.view)
                    bold: modelData.view === "inbox" && Mail.unread > 0
                    current: Mail.place.view === modelData.view && Mail.place.account === "" && !Mail.searching
                    dropTarget: ["inbox", "archive", "junk", "trash"].indexOf(modelData.view) >= 0
                    onPicked: Mail.go(modelData.view)
                    onDropped: ids => {
                        if (modelData.view === "archive") Mail.archive(ids);
                        else if (modelData.view === "trash") Mail.trash(ids);
                        else if (modelData.view === "junk") Mail.spam(ids);
                        else Mail.act("notSpam", ids, {}, "Moved to Inbox");
                    }
                }
            }

            // Each account.
            Repeater {
                model: Mail.accounts
                Column {
                    id: acctCol
                    required property var modelData
                    readonly property var st: Mail.status[modelData.id] || ({})
                    readonly property bool open: !rail.collapsed[modelData.id]
                    width: col.width
                    Item { width: 1; height: 10 }
                    RailRow {
                        width: col.width
                        icon: ""
                        dot: modelData.color || Mail.hue(modelData.email)
                        label: modelData.name || modelData.email
                        bold: true
                        warn: acctCol.st.status === "error" || acctCol.st.status === "signin"
                        count: Mail.unreadBy[modelData.id] > 0 ? String(Mail.unreadBy[modelData.id]) : ""
                        current: Mail.place.account === acctCol.modelData.id && Mail.place.view === "inbox"
                        onPicked: {
                            if (Mail.place.account === acctCol.modelData.id && Mail.place.view === "inbox") {
                                const c = Object.assign({}, rail.collapsed);
                                c[acctCol.modelData.id] = acctCol.open;
                                rail.collapsed = c;
                            } else Mail.go("inbox", acctCol.modelData.id);
                        }
                        onMenu: (x, y) => rail.frame.menu.openAt(x, y, [
                            { n: "Check for mail", icon: "refresh", run: () => Mail.call("sync", { account: acctCol.modelData.id }) },
                            { n: "Write from this account", icon: "pencil", run: () => Mail.newMessage({ account: acctCol.modelData.id, body: Mail.signatureFor(acctCol.modelData.id) }) },
                            { n: "Account settings…", icon: "settings", rule: true, run: () => rail.frame.openSetup(acctCol.modelData) }
                        ])
                    }
                    // What is wrong, said plainly, with the way to fix it.
                    Item {
                        visible: acctCol.st.error !== undefined && acctCol.st.error !== ""
                        width: col.width
                        height: visible ? errText.implicitHeight + 10 : 0
                        StyledText {
                            id: errText
                            x: 22; y: 2
                            width: parent.width - 40
                            wrapMode: Text.WordWrap
                            text: acctCol.st.error || ""
                            font.pixelSize: Appearance.fs(11)
                            color: Appearance.accent
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: rail.frame.openSetup(acctCol.modelData)
                            }
                        }
                    }
                    Repeater {
                        model: acctCol.open ? rail.customFolders(acctCol.modelData.id) : []
                        RailRow {
                            required property var modelData
                            width: col.width
                            indent: 1 + Math.max(0, (modelData.path.split(modelData.delim || "/").length - 1))
                            icon: rail.roleIcon(modelData.role)
                            label: modelData.name
                            count: modelData.unread > 0 && modelData.role !== "trash" && modelData.role !== "junk" && modelData.role !== "sent" ? String(modelData.unread) : ""
                            current: Mail.place.view === "folder" && Mail.place.account === modelData.account && Mail.place.folder === modelData.path
                            dropTarget: true
                            onPicked: Mail.go("folder", modelData.account, modelData.path)
                            onDropped: ids => Mail.moveTo(ids, modelData.account, modelData.path)
                        }
                    }
                }
            }

            Item { width: 1; height: 8 }
            RailRow {
                width: col.width
                icon: "plus"
                label: "Add an account"
                onPicked: rail.frame.openSetup(null)
            }
        }
    }
    ScrollBar { target: flick; anchors.right: parent.right; anchors.top: flick.top; anchors.bottom: flick.bottom }

    Column {
        id: foot
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        width: parent.width
        RailRow {
            width: parent.width
            icon: "settings"
            label: "Settings"
            current: Mail.inSettings
            onPicked: Mail.go("settings")
        }
    }
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Appearance.rule }
}
