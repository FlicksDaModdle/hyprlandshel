import QtQuick
import Hyprshell
import Hyprshell.Backend

// Adding an account, or changing one.
//
// New: pick Google, Microsoft or other; give the address. Google and
// Microsoft sign in in the browser (once their client ID is set — see the
// README), Gmail can use an app password instead; anything else is IMAP
// with a password, its servers looked up from the address and editable.
Item {
    id: setup
    property bool open: false
    property var account: null          // an existing account to change
    property var frame
    signal closed()
    visible: open
    z: 2000

    readonly property bool editing: setup.account !== null
    property string step: "pick"        // pick | details | wait
    property string kind: ""            // google | microsoft | other
    property var cfg: ({})              // server settings
    property string pendingId: ""
    property string error: ""
    property bool busy: false
    property bool showServers: false
    property bool appPassword: false
    property string hostedNote: ""

    readonly property bool useOAuth: (setup.kind === "google" && !setup.appPassword) || setup.kind === "microsoft"
    readonly property string provider: setup.kind === "google" ? "google" : "microsoft"
    readonly property bool clientMissing: setup.useOAuth && !((Mail.oauthClients[setup.provider] || {}).clientId)

    onOpenChanged: if (open) reset()
    function reset() {
        setup.error = "";
        setup.busy = false;
        setup.appPassword = false;
        setup.pendingId = "";
        setup.hostedNote = "";
        if (setup.editing) {
            const a = setup.account;
            setup.kind = a.provider === "gmail" ? "google" : a.provider === "outlook" ? "microsoft" : "other";
            setup.appPassword = a.provider === "gmail" && a.auth !== "oauth";
            setup.cfg = Object.assign({}, a);
            setup.step = "details";
            setup.showServers = setup.kind === "other";
            email.text = a.email; name.text = a.name; display.text = a.displayName || "";
            signature.text = a.signature || ""; password.text = "";
        } else {
            setup.step = "pick";
            setup.kind = "";
            setup.cfg = {};
            setup.showServers = false;
            email.text = ""; name.text = ""; display.text = ""; signature.text = ""; password.text = "";
        }
        Mail.call("oauth.clients", {}, (ok, r) => { if (ok) Mail.oauthClients = r; });
    }
    function choose(k) {
        setup.kind = k;
        setup.step = "details";
        setup.cfg = {};
        Mail.call("accounts.preset", { provider: k === "google" ? "gmail" : k === "microsoft" ? "outlook" : "" }, (ok, r) => { if (ok && r) setup.cfg = r; });
        email.input.forceActiveFocus();
    }
    function lookup() {
        if (setup.kind !== "other" || setup.editing || email.text.indexOf("@") < 0) return;
        setup.busy = true;
        Mail.call("accounts.autoconfig", { email: email.text.trim() }, (ok, r) => {
            setup.busy = false;
            if (!ok) return;
            // A school on Google Workspace or Microsoft 365 is either of those.
            if (r.hosted === "google") { setup.kind = "google"; setup.cfg = r; setup.hostedNote = "This address's mail is on Google Workspace, so it signs in with Google."; return; }
            if (r.hosted === "microsoft") {
                setup.kind = "microsoft"; setup.cfg = r;
                setup.hostedNote = (r.organisation ? r.organisation + "'s" : "This address's") + " mail is on Microsoft 365, so it signs in with Microsoft — passwords alone aren't accepted there.";
                return;
            }
            setup.cfg = r;
            if (!r.found) setup.showServers = true;
        });
    }
    function buildAccount() {
        const c = setup.cfg;
        const a = Object.assign({}, setup.editing ? setup.account : {}, {
            email: email.text.trim(),
            name: name.text.trim() || (setup.kind === "google" ? "Gmail" : setup.kind === "microsoft" ? "Outlook" : email.text.trim().split("@")[1] || "Mail"),
            displayName: display.text.trim(),
            signature: signature.text,
            provider: setup.kind === "google" ? "gmail" : setup.kind === "microsoft" ? "outlook" : "imap",
            imapHost: imapHost.text.trim() || c.imapHost || "", imapPort: parseInt(imapPort.text) || c.imapPort || 993, imapSecurity: imapSec.value || c.imapSecurity || "tls",
            smtpHost: smtpHost.text.trim() || c.smtpHost || "", smtpPort: parseInt(smtpPort.text) || c.smtpPort || 587, smtpSecurity: smtpSec.value || c.smtpSecurity || "starttls",
            username: username.text.trim(),
            auth: setup.useOAuth ? "oauth" : "password",
            oauthProvider: setup.useOAuth ? setup.provider : "",
        });
        delete a.status; delete a.error;
        return a;
    }
    function save(after) {
        const args = { account: setup.buildAccount() };
        if (setup.pendingId) args.pendingId = setup.pendingId;
        if (password.text) args.password = password.text;
        Mail.call("accounts.save", args, (ok, r) => {
            setup.busy = false;
            if (!ok) { setup.error = String(r); return; }
            password.text = "";
            Mail.loadAccounts();
            if (after) after(r.id);
            setup.closed();
            Mail.toast(setup.editing ? "Account updated" : "Added — fetching your mail", false, "", null);
            if (!setup.editing) Mail.go("inbox", r.id);
        });
    }
    // Password accounts: try both servers, then save.
    function connect() {
        setup.error = "";
        if (email.text.indexOf("@") < 0) { setup.error = "Enter the email address"; return; }
        if (setup.useOAuth) { setup.signIn(); return; }
        if (!password.text && !setup.editing) { setup.error = "Enter the password"; return; }
        setup.busy = true;
        const args = { account: setup.buildAccount() };
        if (password.text) args.password = password.text;
        Mail.call("accounts.test", args, (ok, r) => {
            if (!ok) {
                setup.busy = false;
                setup.error = String(r);
                setup.showServers = true;
                return;
            }
            setup.save();
        });
    }
    function signIn() {
        if (setup.clientMissing) { setup.error = "Add the client ID first"; return; }
        setup.busy = true;
        setup.step = "wait";
        Mail.call("oauth.begin", { provider: setup.provider, email: email.text.trim(), account: setup.editing ? setup.account.id : "" }, (ok, r) => {
            if (!ok) { setup.busy = false; setup.step = "details"; setup.error = String(r); return; }
            setup.pendingId = r.account;
            setup.authUrl = r.url;
        });
    }
    property string authUrl: ""
    Connections {
        target: MailClient
        function onEvent(name, data) {
            if (name !== "oauth" || !setup.open || data.account !== setup.pendingId) return;
            if (!data.ok) { setup.busy = false; setup.step = "details"; setup.error = data.error; return; }
            if (data.email && !email.text) email.text = data.email;
            setup.save();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.4)
        MouseArea { anchors.fill: parent; onClicked: if (!setup.busy) setup.closed(); onWheel: w => w.accepted = true }
    }
    PanelSurface {
        id: box
        anchors.centerIn: parent
        showSeam: false
        color: Appearance.dialog
        width: Math.min(560, parent.width - 40)
        height: Math.min(parent.height - 40, content.implicitHeight + 40)
        MouseArea { anchors.fill: parent }
        Flickable {
            id: boxFlick
            anchors.fill: parent
            anchors.margins: 20
            contentHeight: content.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: content
                width: boxFlick.width
                spacing: 14

                StyledText {
                    text: setup.editing ? (setup.account.name || setup.account.email) : "Add an account"
                    font.pixelSize: Appearance.fs(17)
                    font.weight: Font.DemiBold
                }

                // ── which kind ──
                Column {
                    visible: setup.step === "pick"
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: [
                            { k: "google", n: "Google", s: "Gmail, or a school or work Google account", icon: "mail" },
                            { k: "microsoft", n: "Microsoft", s: "Outlook, Hotmail, Live, or Microsoft 365 for school or work", icon: "mail" },
                            { k: "other", n: "Other", s: "Any IMAP account — school, work, iCloud, Fastmail, your own server", icon: "globe" }
                        ]
                        Rectangle {
                            id: kindRow
                            required property var modelData
                            width: content.width
                            height: 58
                            radius: Appearance.rSm
                            color: kArea.containsMouse ? Appearance.sel : Appearance.hover
                            border.width: 1
                            border.color: Appearance.rule
                            MonoIcon { x: 16; anchors.verticalCenter: parent.verticalCenter; name: kindRow.modelData.icon; size: 24; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                            Column {
                                x: 54
                                anchors.verticalCenter: parent.verticalCenter
                                StyledText { text: kindRow.modelData.n; font.pixelSize: Appearance.fs(13.5); font.weight: Font.DemiBold }
                                StyledText { text: kindRow.modelData.s; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
                            }
                            MouseArea { id: kArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: setup.choose(kindRow.modelData.k) }
                        }
                    }
                }

                // ── the details ──
                Column {
                    visible: setup.step === "details"
                    width: parent.width
                    spacing: 10
                    Field { id: email; width: parent.width; label: "Email"; placeholder: "you@example.com"; onAccepted: setup.lookup(); onFocusLost: setup.lookup(); readOnly: setup.editing }
                    Field { id: display; width: parent.width; label: "Your name"; placeholder: "As people see it" }
                    Field { id: name; width: parent.width; label: "Call it"; placeholder: setup.kind === "other" ? "School" : "Personal" }

                    StyledText {
                        visible: setup.hostedNote !== ""
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: setup.hostedNote
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.accent
                    }

                    // Google: browser sign-in, or an app password.
                    Row {
                        visible: setup.kind === "google"
                        spacing: 8
                        Seg {
                            options: [{ label: "Sign in with Google", value: false }, { label: "App password", value: true }]
                            value: setup.appPassword
                            onPicked: v => setup.appPassword = v
                        }
                    }
                    StyledText {
                        visible: setup.kind === "google" && setup.appPassword
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Make one at myaccount.google.com → Security → 2-Step Verification → App passwords, and paste it below. (Google only offers them with 2-Step Verification on.)"
                        font.pixelSize: Appearance.fs(11.5)
                        color: Appearance.ink3
                    }

                    // The client ID, the first time.
                    Rectangle {
                        visible: setup.useOAuth && setup.clientMissing
                        width: parent.width
                        height: cidCol.implicitHeight + 24
                        radius: Appearance.rSm
                        color: Appearance.hover
                        Column {
                            id: cidCol
                            x: 12; y: 12
                            width: parent.width - 24
                            spacing: 8
                            StyledText {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: setup.provider === "google"
                                    ? "Signing in with Google needs a client ID of your own — free, made once: console.cloud.google.com → APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app. Enable the Gmail API, add yourself as a test user. Mail's README walks through it."
                                    : "Signing in with Microsoft needs a client ID of your own — free, made once: entra.microsoft.com → App registrations → New registration → \"Personal Microsoft accounts and any organisation\", redirect \"Mobile and desktop\" http://localhost. Add the IMAP.AccessAsUser.All and SMTP.Send permissions. Mail's README walks through it."
                                font.pixelSize: Appearance.fs(11.5)
                                color: Appearance.ink2
                            }
                            Field { id: cid; width: parent.width; label: "Client ID" }
                            Field { id: csecret; visible: setup.provider === "google"; width: parent.width; label: "Secret"; password: true }
                            DialogButton {
                                text: "Save client ID"
                                onTriggered: Mail.call("oauth.setClient", { provider: setup.provider, clientId: cid.text, clientSecret: csecret.text }, (ok) => {
                                    if (ok) Mail.call("oauth.clients", {}, (ok2, r) => { if (ok2) Mail.oauthClients = r; });
                                })
                            }
                        }
                    }

                    Field {
                        id: password
                        visible: !setup.useOAuth
                        width: parent.width
                        label: setup.kind === "google" ? "App password" : "Password"
                        password: true
                        placeholder: setup.editing ? "Unchanged" : ""
                        onAccepted: setup.connect()
                    }

                    // Servers.
                    StyledText {
                        visible: !setup.useOAuth
                        text: setup.showServers ? "Hide server settings" : "Server settings"
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.accent
                        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: setup.showServers = !setup.showServers }
                    }
                    Column {
                        visible: setup.showServers && !setup.useOAuth
                        width: parent.width
                        spacing: 8
                        Field { id: username; width: parent.width; label: "Username"; placeholder: "Usually the email address"; text: setup.cfg.username || "" }
                        Row {
                            spacing: 8
                            Field { id: imapHost; width: content.width - 90 - 8; label: "Incoming"; placeholder: "imap.example.com"; text: setup.cfg.imapHost || "" }
                            Field { id: imapPort; width: 90; placeholder: "993"; text: setup.cfg.imapPort ? String(setup.cfg.imapPort) : "" }
                        }
                        Seg {
                            id: imapSec
                            x: 96
                            options: [{ label: "SSL/TLS", value: "tls" }, { label: "STARTTLS", value: "starttls" }, { label: "None (this computer)", value: "none" }]
                            value: setup.cfg.imapSecurity || "tls"
                            onPicked: v => { value = v; }
                        }
                        Row {
                            spacing: 8
                            Field { id: smtpHost; width: content.width - 90 - 8; label: "Outgoing"; placeholder: "smtp.example.com"; text: setup.cfg.smtpHost || "" }
                            Field { id: smtpPort; width: 90; placeholder: "587"; text: setup.cfg.smtpPort ? String(setup.cfg.smtpPort) : "" }
                        }
                        Seg {
                            id: smtpSec
                            x: 96
                            options: [{ label: "SSL/TLS", value: "tls" }, { label: "STARTTLS", value: "starttls" }, { label: "None (this computer)", value: "none" }]
                            value: setup.cfg.smtpSecurity || "starttls"
                            onPicked: v => { value = v; }
                        }
                    }

                    // Signature, when changing an account.
                    Column {
                        visible: setup.editing
                        width: parent.width
                        spacing: 6
                        StyledText { text: "Signature"; font.pixelSize: Appearance.fs(12.5); color: Appearance.ink2 }
                        Rectangle {
                            width: parent.width
                            height: Math.max(70, signature.implicitHeight + 16)
                            radius: Appearance.rSm
                            color: Appearance.hover
                            border.width: signature.activeFocus ? 2 : 1
                            border.color: signature.activeFocus ? Appearance.accent : Appearance.rule
                            TextEdit {
                                id: signature
                                x: 10; y: 8
                                width: parent.width - 20
                                wrapMode: TextEdit.Wrap
                                color: Appearance.ink
                                selectByMouse: true
                                font.family: Appearance.fontFamily
                                font.pixelSize: Appearance.fs(13)
                            }
                        }
                    }
                }

                // ── waiting for the browser ──
                Column {
                    visible: setup.step === "wait"
                    width: parent.width
                    spacing: 10
                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Finish signing in in your browser. This window carries on by itself when you have."
                        font.pixelSize: Appearance.fs(13)
                    }
                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        visible: setup.authUrl !== ""
                        text: "Browser didn't open? <a href=\"" + setup.authUrl + "\">Open the sign-in page</a>."
                        textFormat: Text.StyledText
                        linkColor: Appearance.accent
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.ink3
                        onLinkActivated: l => Qt.openUrlExternally(l)
                    }
                }

                StyledText {
                    visible: setup.error !== ""
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: setup.error
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.accent
                }

                Item {
                    width: parent.width
                    height: 34
                    DialogButton {
                        visible: setup.editing && setup.step === "details"
                        text: "Remove account"
                        onTriggered: removeConfirm.open = true
                    }
                    Row {
                        anchors.right: parent.right
                        spacing: 8
                        DialogButton { text: setup.step === "details" && !setup.editing ? "Back" : "Cancel"; onTriggered: { if (setup.step === "details" && !setup.editing) setup.step = "pick"; else if (setup.step === "wait") { setup.step = "details"; setup.busy = false; } else setup.closed(); } }
                        DialogButton {
                            visible: setup.step === "details"
                            primary: true
                            enabled: !setup.busy
                            text: setup.busy ? "Checking…" : setup.useOAuth ? (setup.provider === "google" ? "Sign in with Google" : "Sign in with Microsoft")
                                : setup.editing ? "Save" : "Connect"
                            onTriggered: {
                                if (setup.editing && !setup.useOAuth && !password.text) { setup.busy = true; setup.save(); }
                                else if (setup.editing && setup.useOAuth && setup.account.auth === "oauth" && setup.account.oauthProvider === setup.provider && Mail.status[setup.account.id] && Mail.status[setup.account.id].status !== "signin") { setup.busy = true; setup.save(); }
                                else setup.connect();
                            }
                        }
                    }
                }
            }
        }
    }

    Modal {
        id: removeConfirm
        anchors.fill: parent
        title: "Remove " + (setup.account ? setup.account.email : "") + "?"
        boxWidth: 380
        Column {
            width: parent.width
            spacing: 14
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Its mail is removed from this computer and its password from the keyring. Nothing is deleted on the server."
                font.pixelSize: Appearance.fs(12.5)
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton { text: "Keep it"; onTriggered: removeConfirm.open = false }
                DialogButton {
                    text: "Remove"
                    primary: true
                    onTriggered: {
                        Mail.call("accounts.remove", { account: setup.account.id }, () => { Mail.loadAccounts(); Mail.go("inbox"); });
                        removeConfirm.open = false;
                        setup.closed();
                    }
                }
            }
        }
    }
}
