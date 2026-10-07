import QtQuick
import QtQuick.Dialogs
import Hyprshell
import Hyprshell.Backend
import "Snooze.js" as Snooze

// Writing: from, to, cc and bcc, subject, the message, attachments. Kept
// as a draft every few seconds while it changes. Sent with a moment's grace
// to take it back (Settings → Undo send), or at a time chosen.
Item {
    id: comp
    property var frame
    readonly property var c: Mail.compose || ({})
    property var to: comp.c.to || []
    property var cc: comp.c.cc || []
    property var bcc: comp.c.bcc || []
    property string account: comp.c.account || Mail.defaultAccount()
    property var attachments: comp.c.attachments || []
    property var forwardParts: comp.c.forwardParts || []
    property int draftId: comp.c.draftId || 0
    property bool showCc: comp.cc.length > 0 || comp.bcc.length > 0
    property bool dirty: false
    property bool sending: false

    function request() {
        return {
            account: comp.account,
            to: comp.to, cc: comp.cc, bcc: comp.bcc,
            subject: subject.text,
            text: body.text,
            html: Mail.toHtml(body.text),
            attachments: comp.attachments.map(a => a.path),
            forwardOf: comp.forwardParts.length > 0 ? comp.c.forwardOf : undefined,
            forwardParts: comp.forwardParts.map(p => p.index),
            inReplyTo: comp.c.inReplyTo || "",
            references: comp.c.references || [],
            replyToId: comp.c.replyToId,
            draftId: comp.draftId > 0 ? comp.draftId : undefined
        };
    }
    function draft() {
        return { account: comp.account, to: comp.to, cc: comp.cc, bcc: comp.bcc, subject: subject.text, body: body.text,
                 attachments: comp.attachments, inReplyTo: comp.c.inReplyTo, references: comp.c.references,
                 replyToId: comp.c.replyToId, forwardOf: comp.c.forwardOf, forwardParts: comp.forwardParts };
    }
    function saveDraft(then) {
        const args = { draft: comp.draft() };
        if (comp.draftId > 0) args.id = comp.draftId;
        Mail.call("drafts.save", args, (ok, id) => { if (ok) { comp.draftId = id; comp.dirty = false; } if (then) then(); });
    }
    function close() { Mail.compose = null; }
    function discard() {
        if (comp.draftId > 0) Mail.call("drafts.delete", { id: comp.draftId });
        comp.close();
        Mail.toast("Discarded", false, "", null);
    }
    function problems() {
        if (comp.to.length + comp.cc.length + comp.bcc.length === 0) return "Add someone to send it to";
        const bad = comp.to.concat(comp.cc).concat(comp.bcc).find(p => !toField.valid(p.email));
        if (bad) return "\"" + bad.email + "\" is not an email address";
        if (!comp.account) return "Add an account to send from";
        return "";
    }
    function send(at) {
        // Finish whatever is half-typed in an address box.
        toField.commit(); ccField.commit(); bccField.commit();
        const p = comp.problems();
        if (p) { Mail.toast(p, true, "", null); return; }
        if (subject.text.trim() === "" && !confirmNoSubject.asked) { confirmNoSubject.asked = true; Mail.toast("No subject — press Send again to send it anyway", true, "", null); return; }
        const req = comp.request();
        const undo = Mail.undoSeconds;
        if (at) req.sendAt = Math.round(at / 1000);
        else if (undo > 0) req.sendAt = Math.round(Date.now() / 1000) + undo;
        comp.sending = true;
        Mail.call("send", req, (ok, r) => {
            comp.sending = false;
            if (!ok) return;
            const back = { request: req, draftId: comp.draftId };
            comp.close();
            if (r.queued && at) Mail.toast("Will send " + Mail.when(at), false, "Cancel", () => Mail.call("outbox.cancel", { id: r.queued }, (ok2, q) => { if (ok2 && q) Mail.newMessage(Mail.composeFromRequest(q)); }));
            else if (r.queued) Mail.toast("Sending…", false, "Undo", () => Mail.call("outbox.cancel", { id: r.queued }, (ok2, q) => { if (ok2 && q) Mail.newMessage(Mail.composeFromRequest(q)); }));
            else Mail.toast("Sent", false, "", null);
        });
    }
    QtObject { id: confirmNoSubject; property bool asked: false }

    Timer { interval: 4000; running: comp.dirty; repeat: false; onTriggered: comp.saveDraft() }

    // ── the bar ───────────────────────────────────────────────────────────
    Item {
        id: bar
        width: parent.width
        height: 52
        Row {
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: comp.c.inReplyTo ? "Reply" : comp.c.forwardOf ? "Forward" : "New message"
                font.pixelSize: Appearance.fs(15)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: comp.draftId > 0 && !comp.dirty ? "Draft saved" : ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            ToolButton { icon: "trash"; onClicked: comp.discard() }
            ToolButton { icon: "x"; onClicked: { if (comp.dirty || subject.text || body.text.trim()) comp.saveDraft(() => comp.close()); else comp.close(); } }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── the fields ────────────────────────────────────────────────────────
    Column {
        id: head
        anchors.top: bar.bottom
        anchors.topMargin: 8
        x: 20
        width: parent.width - 40
        spacing: 2
        z: 10

        // From.
        Item {
            width: parent.width
            height: 34
            visible: Mail.accounts.length > 1
            StyledText { y: 9; width: 48; text: "From"; font.pixelSize: Appearance.fs(12.5); color: Appearance.ink3 }
            Rectangle {
                id: fromBtn
                x: 48
                anchors.verticalCenter: parent.verticalCenter
                width: fromText.implicitWidth + 36
                height: 28
                radius: Appearance.rSm
                color: fromArea.containsMouse ? Appearance.hover : "transparent"
                readonly property var acct: Mail.accountById(comp.account) || ({})
                StyledText {
                    id: fromText
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: (fromBtn.acct.displayName ? fromBtn.acct.displayName + " " : "") + "<" + (fromBtn.acct.email || "") + ">"
                    font.pixelSize: Appearance.fs(12.5)
                }
                MonoIcon { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; name: "chevronDown"; size: 13; inkColor: Appearance.ink3; monochrome: true }
                MouseArea {
                    id: fromArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const p = fromBtn.mapToItem(null, 0, fromBtn.height);
                        comp.frame.menu.openAt(p.x, p.y, Mail.accounts.map(a => ({
                            n: a.name + " — " + a.email, checked: a.id === comp.account,
                            run: () => {
                                // The signature follows the account.
                                const oldSig = Mail.signatureFor(comp.account), newSig = Mail.signatureFor(a.id);
                                if (oldSig && body.text.indexOf(oldSig) >= 0) body.text = body.text.replace(oldSig, newSig);
                                comp.account = a.id;
                                comp.dirty = true;
                            }
                        })));
                    }
                }
            }
        }
        Item {
            width: parent.width
            height: toField.height
            AddressField {
                id: toField
                width: parent.width - 70
                label: "To"
                people: comp.to
                onChanged: p => { comp.to = p; comp.dirty = true; }
                onTabbed: comp.showCc ? ccField.focusIn() : subject.input.forceActiveFocus()
            }
            StyledText {
                visible: !comp.showCc
                anchors.right: parent.right
                y: 10
                text: "Cc  Bcc"
                font.pixelSize: Appearance.fs(12)
                color: Appearance.accent
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: { comp.showCc = true; ccField.focusIn(); } }
            }
        }
        AddressField {
            id: ccField
            visible: comp.showCc
            width: parent.width
            label: "Cc"
            people: comp.cc
            onChanged: p => { comp.cc = p; comp.dirty = true; }
            onTabbed: bccField.focusIn()
        }
        AddressField {
            id: bccField
            visible: comp.showCc
            width: parent.width
            label: "Bcc"
            people: comp.bcc
            onChanged: p => { comp.bcc = p; comp.dirty = true; }
            onTabbed: subject.input.forceActiveFocus()
        }
        Rectangle { width: parent.width; height: 1; color: Appearance.rule }
        Field {
            id: subject
            width: parent.width
            bare: true
            label: "Subject"
            labelWidth: 60
            text: comp.c.subject || ""
            onEdited: comp.dirty = true
            onAccepted: body.forceActiveFocus()
            bold: true
            Keys.onTabPressed: body.forceActiveFocus()
        }
        Rectangle { width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── the message ───────────────────────────────────────────────────────
    Flickable {
        id: bodyFlick
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.bottom: atts.top
        x: 20
        width: parent.width - 40
        contentHeight: body.implicitHeight + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        function ensureVisible(r) {
            if (contentY >= r.y) contentY = r.y;
            else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height + 20;
        }
        TextEdit {
            id: body
            width: bodyFlick.width
            height: Math.max(bodyFlick.height, implicitHeight)
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            selectByMouse: true
            persistentSelection: true
            color: Appearance.ink
            selectionColor: Appearance.accent
            selectedTextColor: Appearance.inkOnAccent
            font.family: Appearance.fontFamily
            font.pixelSize: Appearance.fs(13.5)
            text: comp.c.body || ""
            onTextChanged: if (activeFocus) comp.dirty = true
            onCursorRectangleChanged: bodyFlick.ensureVisible(cursorRectangle)
            Keys.onPressed: e => {
                if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) { comp.send(0); e.accepted = true; }
            }
            StyledText {
                visible: body.text === "" || body.text === Mail.signatureFor(comp.account)
                y: 0
                text: "Write your message"
                font.pixelSize: Appearance.fs(13.5)
                color: Appearance.ink3
            }
            Component.onCompleted: {
                if (comp.to.length === 0) toField.focusIn();
                else { body.forceActiveFocus(); body.cursorPosition = 0; }
            }
        }
    }
    SmoothScroll { target: bodyFlick; anchors.fill: bodyFlick; z: 5 }
    ScrollBar { target: bodyFlick; anchors.top: bodyFlick.top; anchors.bottom: bodyFlick.bottom }

    // Files dropped anywhere on it are attached.
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: d => {
            if (!d.hasUrls) return;
            comp.attachments = comp.attachments.concat(d.urls.map(u => { const fi = MailApp.fileInfo(u.toString()); return { path: fi.path, name: fi.name, size: fi.size }; }).filter(a => a.name));
            comp.dirty = true;
            d.accept();
        }
    }

    // ── attachments ───────────────────────────────────────────────────────
    Flow {
        id: atts
        anchors.bottom: foot.top
        anchors.bottomMargin: comp.attachments.length + comp.forwardParts.length > 0 ? 8 : 0
        x: 20
        width: parent.width - 40
        spacing: 6
        Repeater {
            model: comp.forwardParts.map(p => Object.assign({ fwd: true }, p)).concat(comp.attachments)
            Rectangle {
                id: ach
                required property var modelData
                required property int index
                height: 30
                width: achRow.implicitWidth + 20
                radius: Appearance.rSm
                color: Appearance.hover
                border.width: 1
                border.color: Appearance.rule
                Row {
                    id: achRow
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "paperclip"; size: 14; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: ach.modelData.name; font.pixelSize: Appearance.fs(12) }
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: Mail.size(ach.modelData.size || 0); font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "x"; size: 12; inkColor: Appearance.ink3; monochrome: true
                        MouseArea {
                            anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (ach.modelData.fwd) comp.forwardParts = comp.forwardParts.filter(p => p.index !== ach.modelData.index);
                                else comp.attachments = comp.attachments.filter(a => a.path !== ach.modelData.path);
                                comp.dirty = true;
                            }
                        }
                    }
                }
            }
        }
    }

    // ── sending ───────────────────────────────────────────────────────────
    Item {
        id: foot
        anchors.bottom: parent.bottom
        width: parent.width
        height: 60
        Rectangle { width: parent.width; height: 1; color: Appearance.rule }
        Row {
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            // Send, and its menu of later.
            Rectangle {
                id: sendBtn
                width: sendRow.implicitWidth + 24 + 30
                height: 36
                radius: Appearance.rSm
                color: sendArea.containsMouse ? Qt.lighter(Appearance.accent, 1.1) : Appearance.accent
                opacity: comp.sending ? 0.6 : 1
                Row {
                    id: sendRow
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "send"; size: 16; inkColor: Appearance.inkOnAccent; accentColor: Appearance.inkOnAccent }
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: comp.sending ? "Sending…" : "Send"; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold; color: Appearance.inkOnAccent }
                }
                MouseArea {
                    id: sendArea
                    anchors.fill: parent
                    anchors.rightMargin: 30
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !comp.sending
                    onClicked: comp.send(0)
                }
                Rectangle { x: parent.width - 30; y: 6; width: 1; height: parent.height - 12; color: Qt.rgba(1, 1, 1, 0.35) }
                MonoIcon { x: parent.width - 23; anchors.verticalCenter: parent.verticalCenter; name: "chevronUp"; size: 14; inkColor: Appearance.inkOnAccent; monochrome: true }
                MouseArea {
                    x: parent.width - 30
                    width: 30; height: parent.height
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const p = sendBtn.mapToItem(null, 0, -6);
                        const items = Snooze.choices(Date.now()).map(c => ({ n: "Send " + c.n.toLowerCase() + " — " + Mail.when(c.at), icon: "calendar", run: () => comp.send(c.at) }));
                        items.push({ n: "Pick a time…", icon: "clock", rule: true, run: () => laterBox.open = true });
                        comp.frame.menu.openAt(p.x, p.y - items.length * 32 - 20, items);
                    }
                }
            }
            ToolButton { icon: "paperclip"; onClicked: attachDialog.open() }
            ToolButton {
                id: tplBtn
                icon: "doc"
                text: "Templates"
                onClicked: {
                    const p = tplBtn.mapToItem(null, 0, -6);
                    const items = Mail.templates.map(t => ({ n: t.name, icon: "doc", run: () => {
                        if (!subject.text && t.subject) subject.text = t.subject;
                        body.insert(body.cursorPosition, t.body);
                        comp.dirty = true;
                    } }));
                    items.push({ n: "Save this as a template", icon: "plus", rule: true, run: () => {
                        Mail.call("templates.save", { name: subject.text || "Untitled", subject: subject.text, body: body.text.replace(Mail.signatureFor(comp.account), "") }, (ok) => {
                            if (ok) { Mail.loadSide(); Mail.toast("Saved as a template", false, "", null); }
                        });
                    } });
                    comp.frame.menu.openAt(p.x, p.y - items.length * 32 - 20, items);
                }
            }
        }
        StyledText {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            text: "Ctrl+Enter to send"
            font.pixelSize: Appearance.fs(11)
            color: Appearance.ink3
        }
    }

    FileDialog {
        id: attachDialog
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            comp.attachments = comp.attachments.concat(selectedFiles.map(u => { const fi = MailApp.fileInfo(u.toString()); return { path: fi.path, name: fi.name, size: fi.size }; }));
            comp.dirty = true;
        }
    }

    // A time of one's own for sending later.
    Modal {
        id: laterBox
        anchors.fill: parent
        title: "Send at"
        boxWidth: 360
        Column {
            width: parent.width
            spacing: 12
            Field {
                id: laterField
                width: parent.width
                placeholder: "2026-10-08 09:30"
                text: Qt.formatDateTime(new Date(Date.now() + 3600000), "yyyy-MM-dd hh:00")
            }
            StyledText {
                id: laterErr
                visible: text !== ""
                text: ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.accent
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton { text: "Cancel"; onTriggered: laterBox.open = false }
                DialogButton {
                    text: "Schedule"
                    primary: true
                    onTriggered: {
                        const at = Snooze.parse(laterField.text);
                        if (isNaN(at) || at < Date.now() + 60000) { laterErr.text = "Give a time in the future, as year-month-day hour:minute"; return; }
                        laterBox.open = false;
                        comp.send(at);
                    }
                }
            }
        }
    }
}
