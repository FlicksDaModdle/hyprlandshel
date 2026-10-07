import QtQuick
import Hyprshell
import Hyprshell.Backend

// The mail window's chrome: the title bar with search, the rail of
// mailboxes, the message list and the reader (or what is being written).
PanelSurface {
    id: frame

    required property var host

    showSeam: false
    showEdge: false
    radius: 0
    color: Appearance.sheet

    // Passed down as `frame:`; under its own name a child's `frame`
    // property would shadow the id.
    readonly property var frameSelf: frame
    property alias menu: contextMenu
    property alias toast: toastItem

    readonly property bool wide: frame.width > 1100
    // The list beside the reader, or one at a time when the window is narrow.
    readonly property bool single: frame.width < 900
    property bool setupOpen: false
    property var setupAccount: null

    function openSetup(acct) { frame.setupAccount = acct || null; frame.setupOpen = true; }

    focus: true
    Keys.onPressed: event => keyMap.handle(event)

    QtObject {
        id: keyMap
        function handle(e) {
            const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
            const shift = (e.modifiers & Qt.ShiftModifier) !== 0;
            const ids = Mail.selected.length > 0 ? Mail.selected : (Mail.openId >= 0 ? [Mail.openId] : []);
            const k = e.key;
            if (ctrl && k === Qt.Key_F || k === Qt.Key_Slash) { search.focusIn(); e.accepted = true; return; }
            if (ctrl && k === Qt.Key_N || (!ctrl && k === Qt.Key_C)) { Mail.newMessage(); e.accepted = true; return; }
            if (k === Qt.Key_F5) { Mail.call("sync", {}); e.accepted = true; return; }
            if (Mail.compose || ctrl) return;
            const b = Mail.openId >= 0 && Mail.thread.length > 0 ? Mail.bodies[Mail.thread[Mail.thread.length - 1].id] : null;
            switch (k) {
            case Qt.Key_J: case Qt.Key_Down: list.step(1); break;
            case Qt.Key_K: case Qt.Key_Up: list.step(-1); break;
            case Qt.Key_Return: case Qt.Key_O: if (list.current >= 0) Mail.open(Mail.items[list.current].id); break;
            case Qt.Key_E: Mail.archive(ids); break;
            case Qt.Key_Delete: case Qt.Key_NumberSign: Mail.trash(ids); break;
            case Qt.Key_Exclam: Mail.spam(ids); break;
            case Qt.Key_S: Mail.setFlag(ids, !(Mail.items.find(x => x.id === ids[0]) || {}).anyFlagged); break;
            case Qt.Key_U: Mail.setRead(ids, shift); break;
            case Qt.Key_I: Mail.setRead(ids, true); break;
            case Qt.Key_R: if (b) Mail.reply(b, false); break;
            case Qt.Key_A: if (b) Mail.reply(b, true); break;
            case Qt.Key_F: if (b) Mail.forward(b); break;
            case Qt.Key_Escape: if (Mail.openId >= 0) Mail.closeThread(); else Mail.selected = []; break;
            default: return;
            }
            e.accepted = true;
        }
    }

    // ── title bar ─────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 46

        MouseArea {
            anchors.fill: parent
            property real pressX: 0
            property real pressY: 0
            property bool moving: false
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moving = false; }
            onPositionChanged: mouse => {
                if (!pressed || moving) return;
                if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4) return;
                moving = true;
                frame.host.startSystemMove();
            }
            onDoubleClicked: frame.host.toggleMaximised()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 16; radius: 2
                color: frame.host.active ? Appearance.accent : Appearance.ink3
            }
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "mail"
                size: 20
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Mail"
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: !MailClient.connected
                text: "Connecting to the mail service…"
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }
        }

        SearchField {
            id: search
            anchors.centerIn: parent
            width: Math.min(460, parent.width - 560)
            visible: width > 160 && !Mail.inSettings
            placeholder: "Search mail — from:, subject:, has:attachment, is:unread"
            onEdited: t => searchSettle.restart()
            Timer { id: searchSettle; interval: 220; onTriggered: Mail.search(search.text) }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            ToolButton {
                anchors.verticalCenter: parent.verticalCenter
                icon: "refresh"
                onClicked: Mail.call("sync", {})
            }
            Item { width: 8; height: 1 }
            Repeater {
                model: [
                    { glyph: "minus",  danger: false, act: () => frame.host.minimise() },
                    { glyph: "square", danger: false, act: () => frame.host.toggleMaximised() },
                    { glyph: "x",      danger: true,  act: () => frame.host.close() }
                ]
                Rectangle {
                    id: winBtn
                    required property var modelData
                    width: 30; height: 30
                    radius: Appearance.rSm
                    color: !btnArea.containsMouse ? "transparent" : (modelData.danger ? Appearance.accent : Appearance.hover)
                    MonoIcon {
                        anchors.centerIn: parent
                        name: winBtn.modelData.glyph
                        size: 17
                        inkColor: btnArea.containsMouse && winBtn.modelData.danger ? Appearance.inkOnAccent : Appearance.ink2
                        monochrome: true
                    }
                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: winBtn.modelData.act()
                    }
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── the rail ──────────────────────────────────────────────────────────
    Rail {
        id: rail
        anchors.left: parent.left
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        width: frame.wide ? 236 : 206
        frame: frameSelf
    }

    // ── settings, or the list and the reader ──────────────────────────────
    Loader {
        anchors.left: rail.right
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        active: Mail.inSettings
        sourceComponent: SettingsView { frame: frameSelf }
    }

    MessageList {
        id: list
        visible: !Mail.inSettings && !(frame.single && (Mail.openId >= 0 || Mail.compose !== null))
        anchors.left: rail.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        width: frame.single ? frame.width - rail.width : (frame.wide ? 400 : 340)
        frame: frameSelf
    }
    Rectangle {
        visible: list.visible && !frame.single
        anchors.left: list.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        width: 1
        color: Appearance.rule
    }

    Item {
        id: right
        visible: !Mail.inSettings && (!frame.single || Mail.openId >= 0 || Mail.compose !== null)
        anchors.left: frame.single ? rail.right : list.right
        anchors.leftMargin: frame.single ? 0 : 1
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom

        Reader {
            anchors.fill: parent
            visible: Mail.compose === null
            frame: frameSelf
        }
        // A fresh pane for each new message, so a reply started while
        // writing another does not inherit what was typed there.
        Repeater {
            model: Mail.compose ? [Mail.compose.key] : []
            Compose { anchors.fill: parent; frame: frameSelf }
        }
    }

    // ── overlays ──────────────────────────────────────────────────────────
    AccountSetup {
        anchors.fill: parent
        open: frame.setupOpen
        account: frame.setupAccount
        frame: frameSelf
        onClosed: frame.setupOpen = false
    }
    ContextMenu { id: contextMenu }
    Toast {
        id: toastItem
        anchors.horizontalCenter: right.visible ? right.horizontalCenter : parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
    }
    Connections {
        target: Mail
        function onToast(message, failed, actionText, action) { toastItem.show(message, failed, actionText, action); }
    }

    // What the launch asked for.
    function takeStart() {
        if (MailApp.startMessage !== "") {
            const id = parseInt(MailApp.startMessage);
            if (id > 0) Mail.open(id);
        }
        if (MailApp.startCompose !== "") frame.composeMailto(MailApp.startCompose);
    }
    function composeMailto(url) {
        // mailto:a@b?subject=…&cc=…&body=…
        const rest = url.replace(/^mailto:/i, "");
        const [to, q] = rest.split("?");
        const f = { to: [], cc: [], bcc: [] };
        const addrs = s => decodeURIComponent(s || "").split(",").map(x => x.trim()).filter(x => x).map(x => ({ name: "", email: x }));
        f.to = addrs(to);
        for (const kv of (q || "").split("&")) {
            const [k, v] = kv.split("=");
            const key = (k || "").toLowerCase();
            const val = decodeURIComponent((v || "").replace(/\+/g, " "));
            if (key === "subject") f.subject = val;
            else if (key === "body") f.body = val + Mail.signatureFor(Mail.defaultAccount());
            else if (key === "cc") f.cc = addrs(v);
            else if (key === "bcc") f.bcc = addrs(v);
        }
        Mail.newMessage(f);
    }
    Connections {
        target: MailApp
        function onStartChanged() { frame.takeStart(); }
    }
    Component.onCompleted: {
        Mail.frameRef = frame;
        Mail.loadAccounts();
        Mail.loadSide();
        Mail.refresh(false);
        takeStart();
    }
    // First run: nothing to show until there is an account.
    Timer {
        interval: 1500
        running: true
        onTriggered: if (MailClient.connected && Mail.accounts.length === 0) frame.openSetup(null)
    }
}
