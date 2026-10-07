import QtQuick
import Hyprshell
import Hyprshell.Backend

// Mail's settings: accounts, reading, writing, notifications, templates,
// the address book, and the sign-in apps for Google and Microsoft.
Item {
    id: sv
    property var frame
    property string contactQuery: ""
    property var contacts: []
    property var editingTemplate: null

    function loadContacts() {
        Mail.call(sv.contactQuery ? "contacts.search" : "contacts.list", { q: sv.contactQuery, limit: 300 }, (ok, r) => { if (ok) sv.contacts = r; });
    }
    Component.onCompleted: { loadContacts(); Mail.loadSide(); }

    component Section: Column {
        property string title: ""
        width: parent ? parent.width : 600
        spacing: 2
        StyledText {
            text: parent ? parent.title.toUpperCase() : ""
            font.pixelSize: Appearance.fs(11)
            font.weight: Font.DemiBold
            font.letterSpacing: 1
            color: Appearance.ink3
            bottomPadding: 6
            topPadding: 18
        }
    }
    component SettingRow: Item {
        id: sr
        property string title: ""
        property string note: ""
        default property alias control: holder.data
        width: parent ? parent.width : 600
        height: Math.max(52, txt.implicitHeight + 22)
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
        Column {
            id: txt
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - holder.width - 20
            spacing: 2
            StyledText { text: sr.title; font.pixelSize: Appearance.fs(13); font.weight: Font.Medium }
            StyledText { visible: sr.note !== ""; width: parent.width; wrapMode: Text.WordWrap; text: sr.note; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
        }
        Item {
            id: holder
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: col.implicitHeight + 60
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Column {
            id: col
            x: Math.max(24, (flick.width - 760) / 2)
            y: 20
            width: Math.min(760, flick.width - 48)

            StyledText { text: "Settings"; font.pixelSize: Appearance.fs(20); font.weight: Font.DemiBold }

            // ── accounts ──
            Section { title: "Accounts" }
            Repeater {
                model: Mail.accounts
                SettingRow {
                    id: ar
                    required property var modelData
                    readonly property var st: Mail.status[modelData.id] || ({})
                    title: (modelData.name || modelData.email) + "  ·  " + modelData.email
                    note: ar.st.error ? ar.st.error
                        : (modelData.auth === "oauth" ? "Signed in with " + (modelData.oauthProvider === "google" ? "Google" : "Microsoft") : "Password in the keyring")
                          + " · " + (ar.st.status === "syncing" ? "checking for mail" : ar.st.status === "idle" ? "up to date" : (ar.st.status || "starting"))
                    Row {
                        spacing: 6
                        DialogButton { text: "Check now"; onTriggered: Mail.call("sync", { account: ar.modelData.id }) }
                        DialogButton { text: "Edit"; onTriggered: sv.frame.openSetup(ar.modelData) }
                    }
                }
            }
            SettingRow {
                title: "Add an account"
                note: "Gmail, Outlook, or any IMAP account — school, work, your own."
                DialogButton { text: "Add…"; primary: true; onTriggered: sv.frame.openSetup(null) }
            }

            // ── reading ──
            Section { title: "Reading" }
            SettingRow {
                title: "Conversations"
                note: "Group replies with what they answer. Off, every message is a row of its own."
                Switch { checked: Mail.threaded; onToggled: on => { Mail.setSetting("threads", on); Mail.refresh(false); } }
            }
            SettingRow {
                title: "Mark as read when opened"
                Switch { checked: Mail.setting("markReadOnOpen", true); onToggled: on => Mail.setSetting("markReadOnOpen", on) }
            }
            SettingRow {
                title: "Pictures from the web"
                note: "Pictures that load from elsewhere let the sender know you opened the message. Hidden, each message offers to show them."
                Seg {
                    options: [{ label: "Ask", value: false }, { label: "Always show", value: true }]
                    value: Mail.setting("remoteImages", []).indexOf("*") >= 0
                    onPicked: v => {
                        const l = Mail.setting("remoteImages", []).filter(x => x !== "*");
                        Mail.setSetting("remoteImages", v ? l.concat(["*"]) : l);
                    }
                }
            }
            SettingRow {
                visible: Appearance.dark
                title: "Dark messages"
                note: "Turn messages written for a white page dark to match. Some look odd this way; off shows them as sent."
                Switch { checked: Mail.darkMessages; onToggled: on => Mail.setSetting("darkMessages", on) }
            }
            SettingRow {
                visible: !MailApp.hasWebEngine
                title: "Simplified HTML"
                note: "Qt WebEngine is not installed, so formatted mail is shown simplified. Install qt6-webengine and rebuild Mail for the full view."
                Item { width: 1; height: 1 }
            }

            // ── writing ──
            Section { title: "Writing" }
            SettingRow {
                title: "Undo send"
                note: "How long a message waits before it goes, with an Undo to take it back."
                Seg {
                    options: [{ label: "Off", value: 0 }, { label: "5 s", value: 5 }, { label: "10 s", value: 10 }, { label: "20 s", value: 20 }, { label: "30 s", value: 30 }]
                    value: Mail.undoSeconds
                    onPicked: v => Mail.setSetting("undoSend", v)
                }
            }
            SettingRow {
                title: "Signatures"
                note: "Each account has its own — Edit an account above to change it."
                Item { width: 1; height: 1 }
            }

            // ── templates ──
            Section { title: "Templates" }
            Repeater {
                model: Mail.templates
                SettingRow {
                    id: tr
                    required property var modelData
                    title: modelData.name
                    note: (modelData.subject ? modelData.subject + " — " : "") + modelData.body.replace(/\n/g, " ").slice(0, 90)
                    Row {
                        spacing: 6
                        DialogButton { text: "Edit"; onTriggered: { sv.editingTemplate = Object.assign({}, tr.modelData); tplBox.open = true; } }
                        DialogButton { text: "Delete"; onTriggered: Mail.call("templates.delete", { id: tr.modelData.id }, () => Mail.loadSide()) }
                    }
                }
            }
            SettingRow {
                title: Mail.templates.length === 0 ? "No templates yet" : "New template"
                note: "Text you send often, a click away in the compose pane."
                DialogButton { text: "New…"; onTriggered: { sv.editingTemplate = { id: 0, name: "", subject: "", body: "" }; tplBox.open = true; } }
            }

            // ── notifications ──
            Section { title: "Notifications" }
            SettingRow {
                title: "New mail"
                note: "A notification for mail that arrives in an inbox, from the background service — the window need not be open."
                Switch { checked: Mail.setting("notify", true); onToggled: on => Mail.setSetting("notify", on) }
            }

            // ── contacts ──
            Section { title: "Address book" }
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Learnt from the mail you write and receive; the people you write to most come first when you type an address."
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
                bottomPadding: 8
            }
            Row {
                spacing: 8
                bottomPadding: 6
                Field { id: cq; width: 300; placeholder: "Search people"; onEdited: t => { sv.contactQuery = t; contactSettle.restart(); } }
                DialogButton { text: "Add person…"; onTriggered: { personBox.email = ""; personBox.name = ""; personBox.open = true; } }
                Timer { id: contactSettle; interval: 200; onTriggered: sv.loadContacts() }
            }
            Repeater {
                model: sv.contacts.slice(0, 60)
                SettingRow {
                    id: cr
                    required property var modelData
                    title: modelData.name || modelData.email
                    note: modelData.name ? modelData.email : ""
                    Row {
                        spacing: 6
                        DialogButton { text: "Write"; onTriggered: { Mail.go("inbox"); Mail.newMessage({ to: [{ name: cr.modelData.name, email: cr.modelData.email }] }); } }
                        DialogButton { text: "Edit"; onTriggered: { personBox.email = cr.modelData.email; personBox.name = cr.modelData.name; personBox.open = true; } }
                        DialogButton { text: "Forget"; onTriggered: Mail.call("contacts.delete", { email: cr.modelData.email }, () => sv.loadContacts()) }
                    }
                }
            }

            // ── sign-in apps ──
            Section { title: "Sign-in apps" }
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Google and Microsoft only let apps sign in with a client ID registered with them. Make your own once (free; Mail's README shows how) and enter it here."
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
                bottomPadding: 8
            }
            SettingRow {
                title: "Google client ID"
                note: (Mail.oauthClients.google || {}).clientId || "Not set"
                DialogButton { text: "Set…"; onTriggered: { clientBox.provider = "google"; clientBox.open = true; } }
            }
            SettingRow {
                title: "Microsoft client ID"
                note: (Mail.oauthClients.microsoft || {}).clientId || "Not set"
                DialogButton { text: "Set…"; onTriggered: { clientBox.provider = "microsoft"; clientBox.open = true; } }
            }
        }
    }
    ScrollBar { target: flick; anchors.top: flick.top; anchors.bottom: flick.bottom }

    // ── dialogs ──
    Modal {
        id: tplBox
        anchors.fill: parent
        title: sv.editingTemplate && sv.editingTemplate.id ? "Edit template" : "New template"
        boxWidth: 520
        Column {
            width: parent.width
            spacing: 10
            Field { id: tName; width: parent.width; label: "Name"; text: sv.editingTemplate ? sv.editingTemplate.name : "" }
            Field { id: tSubj; width: parent.width; label: "Subject"; text: sv.editingTemplate ? sv.editingTemplate.subject : "" }
            Rectangle {
                width: parent.width
                height: 160
                radius: Appearance.rSm
                color: Appearance.hover
                border.width: 1
                border.color: Appearance.rule
                Flickable {
                    anchors.fill: parent
                    anchors.margins: 8
                    contentHeight: tBody.implicitHeight
                    clip: true
                    TextEdit {
                        id: tBody
                        width: parent.width
                        wrapMode: TextEdit.Wrap
                        color: Appearance.ink
                        selectByMouse: true
                        font.family: Appearance.fontFamily
                        font.pixelSize: Appearance.fs(13)
                        text: sv.editingTemplate ? sv.editingTemplate.body : ""
                    }
                }
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton { text: "Cancel"; onTriggered: tplBox.open = false }
                DialogButton {
                    text: "Save"
                    primary: true
                    onTriggered: {
                        const args = { name: tName.text || "Untitled", subject: tSubj.text, body: tBody.text };
                        if (sv.editingTemplate && sv.editingTemplate.id) args.id = sv.editingTemplate.id;
                        Mail.call("templates.save", args, () => Mail.loadSide());
                        tplBox.open = false;
                    }
                }
            }
        }
    }
    Modal {
        id: personBox
        anchors.fill: parent
        property string email: ""
        property string name: ""
        title: personBox.email ? "Edit person" : "Add a person"
        boxWidth: 420
        Column {
            width: parent.width
            spacing: 10
            Field { id: pName; width: parent.width; label: "Name"; text: personBox.name }
            Field { id: pEmail; width: parent.width; label: "Email"; text: personBox.email }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton { text: "Cancel"; onTriggered: personBox.open = false }
                DialogButton {
                    text: "Save"; primary: true
                    onTriggered: { Mail.call("contacts.save", { email: pEmail.text, name: pName.text }, () => sv.loadContacts()); personBox.open = false; }
                }
            }
        }
    }
    Modal {
        id: clientBox
        anchors.fill: parent
        property string provider: "google"
        title: clientBox.provider === "google" ? "Google client ID" : "Microsoft client ID"
        boxWidth: 480
        Column {
            width: parent.width
            spacing: 10
            Field { id: cId; width: parent.width; label: "Client ID"; text: (Mail.oauthClients[clientBox.provider] || {}).clientId || "" }
            Field { id: cSecret; visible: clientBox.provider === "google"; width: parent.width; label: "Secret"; password: true; placeholder: (Mail.oauthClients.google || {}).hasSecret ? "Unchanged" : "" }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton { text: "Cancel"; onTriggered: clientBox.open = false }
                DialogButton {
                    text: "Save"; primary: true
                    onTriggered: {
                        Mail.call("oauth.setClient", { provider: clientBox.provider, clientId: cId.text, clientSecret: cSecret.text }, () => Mail.loadSide());
                        clientBox.open = false;
                    }
                }
            }
        }
    }
}
