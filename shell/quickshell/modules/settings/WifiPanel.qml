import QtQuick
import Quickshell
import Quickshell.Io
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Network.
//
// Laid out the way KDE's and Windows' network settings are: the switch and
// what you are connected to at the top, then the networks in range as one
// list, each opening in place to whatever it needs — a Connect button, a
// password, or for a university network a username, a password and the
// sign-in options behind "More options". Saved networks out of range, a
// hidden network, and NetworkManager's own editor are at the bottom.
//
// The form's contents live on the pane, not on the row: the list is rebuilt
// as the scan updates, and is held still while a form is open, so what was
// typed is not taken away halfway through.
Column {
    id: panel

    width: parent ? parent.width : 560
    spacing: 16

    readonly property var net: Services.Network
    readonly property color danger: "#d93a2b"

    // ── form state ────────────────────────────────────────────────────────
    property string openSsid: ""
    property bool hiddenOpen: false
    property string hName: ""
    property string hKind: "psk"           // open | psk | enterprise
    property string fPassword: ""
    property string fIdentity: ""
    property string fEap: "peap"
    property string fPhase2: "mschapv2"
    property string fCa: "none"            // none | system | file
    property string fCaFile: ""
    property string fDomain: ""
    property string fAnon: ""
    property bool fMore: false
    property bool fEditSignIn: false       // a saved enterprise network's settings, opened
    property bool fNewPassword: false      // a saved network, password typed again
    property bool showDetails: false
    property bool showSaved: false
    property bool showAll: false

    function resetForm() {
        fPassword = ""; fIdentity = ""; fEap = "peap"; fPhase2 = "mschapv2";
        fCa = "none"; fCaFile = ""; fDomain = ""; fAnon = ""; fMore = false;
        fEditSignIn = false; fNewPassword = false;
    }
    function openRow(ssid) {
        hiddenOpen = false;
        if (openSsid === ssid) { openSsid = ""; return; }
        resetForm();
        openSsid = ssid;
        const p = net.profileFor(ssid);
        if (p && p.enterprise) net.loadProfile(p.uuid);
    }
    // A saved university network's settings, into the form to change them.
    function prefillFrom(info) {
        if (!info) return;
        fIdentity = info.identity || "";
        fEap = ["peap", "ttls", "pwd"].indexOf(info.eap) >= 0 ? info.eap : "peap";
        fPhase2 = info.phase2 || (fEap === "ttls" ? "pap" : "mschapv2");
        fCa = info.systemCa ? "system" : info.ca ? "file" : "none";
        fCaFile = (info.ca || "").replace(/^file:\/\//, "");
        fDomain = info.domain || "";
        fAnon = info.anonymous || "";
        fMore = true;
    }
    function enterpriseOpts() {
        return { identity: fIdentity.trim(), password: fPassword, eap: fEap, phase2: fPhase2,
                 ca: fCa === "file" ? (fCaFile || "none") : fCa, domain: fDomain.trim(),
                 anonymous: fAnon.trim() };
    }

    // The control center sends a network here when it needs more than a
    // password: open its form.
    Connections {
        target: Services.Network
        function onFocusSsidChanged() {
            if (Services.Network.focusSsid === "") return;
            panel.openRow(Services.Network.focusSsid);
            Services.Network.focusSsid = "";
        }
        function onNetworksChanged() { if (panel.openSsid === "") panel.refreshList(); }
        // Joined: the form has done its job.
        function onConnectedChanged() {
            if (Services.Network.connected && Services.Network.ssid === panel.openSsid) panel.openSsid = "";
        }
    }
    Component.onCompleted: {
        refreshList();
        if (net.focusSsid !== "") { openRow(net.focusSsid); net.focusSsid = ""; }
    }

    property var list: []
    function refreshList() { list = net.networks.filter(n => !n.inUse); }
    onOpenSsidChanged: if (openSsid === "") refreshList()

    // A certificate file, from zenity or kdialog.
    Process {
        id: pickCa
        command: ["sh", "-c",
            'if command -v zenity >/dev/null 2>&1; then zenity --file-selection --title="CA certificate" '
          + '--file-filter="Certificates | *.pem *.crt *.cer *.der" --file-filter="All files | *"; '
          + 'elif command -v kdialog >/dev/null 2>&1; then kdialog --getopenfilename "$HOME" "*.pem *.crt *.cer *.der"; fi']
        stdout: StdioCollector {
            onStreamFinished: { const f = text.trim(); if (f !== "") { panel.fCaFile = f; panel.fCa = "file"; } }
        }
    }

    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Config.Appearance.ink3
    }
    component Card: Rectangle {
        width: panel.width
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
    }
    component Line: StyledText {
        width: parent ? parent.width : 0
        wrapMode: Text.WordWrap
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    // ══ NetworkManager not running ════════════════════════════════════════
    Card {
        visible: !panel.net.available
        height: noNm.implicitHeight + 32
        Column {
            id: noNm
            x: 16; y: 16; width: parent.width - 32; spacing: 4
            StyledText { text: "NetworkManager isn't running"; font.pixelSize: Config.Appearance.fs(14); font.weight: Font.DemiBold }
            Line { text: "The shell reads and drives the network through it. Start it with: sudo systemctl enable --now NetworkManager" }
        }
    }

    // ══ NetworkManager asking for a password ══════════════════════════════
    Card {
        id: ask
        visible: !!panel.net.secrets
        readonly property var req: panel.net.secrets
        property string value: ""
        property bool remember: true
        onReqChanged: { value = ""; remember = true; }
        border.width: 2
        border.color: Config.Appearance.accent
        height: askCol.implicitHeight + 32

        Column {
            id: askCol
            x: 16; y: 16; width: parent.width - 32; spacing: 12
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: ask.req ? (ask.req.ssid || ask.req.name) + " needs a password" : ""
                font.pixelSize: Config.Appearance.fs(15)
                font.weight: Font.DemiBold
            }
            Line {
                text: !ask.req ? ""
                    : (ask.req.again ? "The saved password didn't work. " : "")
                      + (ask.req.setting === "802-1x"
                         ? "Sign in" + (ask.req.identity ? " as " + ask.req.identity : "") + "."
                         : "Enter the network's password.")
            }
            NetField {
                width: Math.min(parent.width, 360)
                secret: true
                placeholder: "Password"
                text: ask.value
                onEdited: t => ask.value = t
                onAccepted: if (ask.value !== "") submitAsk.clicked()
            }
            Row {
                spacing: 10
                Toggle { checked: ask.remember; onToggled: on => ask.remember = on; anchors.verticalCenter: parent.verticalCenter }
                StyledText { text: "Remember it for this network"; font.pixelSize: Config.Appearance.fs(12); anchors.verticalCenter: parent.verticalCenter }
            }
            Row {
                spacing: 8
                NetButton {
                    id: submitAsk
                    label: "Connect"; primary: true; active: ask.value !== ""
                    onClicked: {
                        const f = (ask.req.fields || [])[0] || "password";
                        const v = {};
                        v[f] = ask.value;
                        panel.net.answerSecrets(v, ask.remember);
                    }
                }
                NetButton { label: "Cancel"; onClicked: panel.net.cancelSecrets() }
            }
        }
    }

    // ══ the switch, and what is connected ═════════════════════════════════
    Card {
        visible: panel.net.available
        height: top.implicitHeight + 32

        Column {
            id: top
            x: 16; y: 16; width: parent.width - 32; spacing: 14

            Item {
                width: parent.width
                height: 40
                Rectangle {
                    id: badge
                    width: 40; height: 40; radius: 20
                    color: panel.net.wifiEnabled ? Config.Appearance.accent : Config.Appearance.div
                    MonoIcon {
                        anchors.centerIn: parent
                        name: panel.net.wifiEnabled ? "wifi" : "wifiOff"
                        size: 20
                        monochrome: true
                        inkColor: panel.net.wifiEnabled ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                    }
                }
                Column {
                    anchors.left: badge.right
                    anchors.leftMargin: 12
                    anchors.right: wifiSwitch.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: !panel.net.wifiEnabled ? "Wi-Fi is off"
                            : panel.net.connecting ? "Connecting to " + (panel.net.ssid || "…")
                            : panel.net.connected ? panel.net.ssid : "Not connected"
                        font.pixelSize: Config.Appearance.fs(15)
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: !panel.net.wifiEnabled ? "Turn it on to see networks"
                            : panel.net.connected
                              ? ["Connected", panel.net.security, panel.net.details.band || ""].filter(s => s).join(" · ")
                              : panel.net.connecting ? "Signing in…" : "Pick a network below"
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink3
                    }
                }
                Toggle {
                    id: wifiSwitch
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.net.wifiEnabled
                    onToggled: on => panel.net.setWifiEnabled(on)
                }
            }

            // Connected: what about it, and what to do with it.
            Row {
                visible: panel.net.connected
                spacing: 8
                NetButton { label: "Disconnect"; onClicked: panel.net.disconnect() }
                NetButton {
                    label: panel.showDetails ? "Hide details" : "Details"
                    onClicked: panel.showDetails = !panel.showDetails
                }
            }

            Grid {
                visible: panel.net.connected && panel.showDetails
                columns: 2
                columnSpacing: 24
                rowSpacing: 6
                readonly property var d: panel.net.details
                readonly property var rows: [
                    ["IP address", (d.ip4 || "").replace(/\/.*/, "")],
                    ["Gateway", d.gateway || ""],
                    ["DNS", d.dns || ""],
                    ["IPv6", (d.ip6 || "").replace(/\/.*/, "")],
                    ["Band", d.band || ""],
                    ["Link speed", d.rate || ""],
                    ["Hardware address", d.hw || ""],
                    ["Signal", panel.net.signalStrength + "%"]
                ].filter(r => r[1] !== "")
                Repeater {
                    model: parent.rows.length * 2
                    StyledText {
                        required property int index
                        readonly property var r: parent.rows[Math.floor(index / 2)]
                        text: index % 2 === 0 ? r[0] : r[1]
                        font.pixelSize: Config.Appearance.fs(12)
                        font.family: index % 2 === 0 ? Config.Appearance.fontFamily : Config.Appearance.monoFamily
                        color: index % 2 === 0 ? Config.Appearance.ink3 : Config.Appearance.ink
                    }
                }
            }
            Row {
                visible: panel.net.connected && panel.showDetails && !!panel.net.profileFor(panel.net.ssid)
                spacing: 10
                readonly property var p: panel.net.profileFor(panel.net.ssid)
                Toggle {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: !!parent.p && parent.p.autoconnect
                    onToggled: on => { if (parent.p) panel.net.setAutoconnect(parent.p.uuid, on); }
                }
                StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Connect automatically"; font.pixelSize: Config.Appearance.fs(12) }
                Item { width: 12; height: 1 }
                NetButton {
                    label: "Forget"; danger: true
                    onClicked: { if (parent.p) panel.net.forget(parent.p.uuid); panel.showDetails = false; }
                }
            }
        }
    }

    // ══ networks in range ═════════════════════════════════════════════════
    Item {
        visible: panel.net.available && panel.net.wifiEnabled
        width: panel.width
        height: 26
        Caption { anchors.verticalCenter: parent.verticalCenter; text: "Networks" }
        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: panel.net.scanning ? "Looking…" : "Look again"
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.DemiBold
            color: scanHover.hovered ? Config.Appearance.ink : Config.Appearance.accent
            HoverHandler { id: scanHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: panel.net.scan() }
        }
    }

    Column {
        visible: panel.net.available && panel.net.wifiEnabled
        width: panel.width
        spacing: 2

        Repeater {
            model: panel.showAll ? panel.list : panel.list.slice(0, 12)

            Rectangle {
                id: row
                required property var modelData
                readonly property var ap: modelData
                readonly property bool open: panel.openSsid === ap.ssid
                readonly property var profile: panel.net.profileFor(ap.ssid)
                readonly property string err: panel.net.errors[ap.ssid] || ""
                readonly property bool busy: panel.net.busySsid === ap.ssid
                                             || (panel.net.connecting && panel.net.ssid === ap.ssid)

                width: panel.width
                height: rowCol.implicitHeight
                radius: Config.Appearance.rSm
                color: row.open || head.hovered ? Config.Appearance.hover : "transparent"
                border.width: row.open ? 1 : 0
                border.color: Config.Appearance.rule

                Column {
                    id: rowCol
                    width: parent.width

                    Item {
                        id: head
                        property bool hovered: headHover.hovered
                        width: parent.width
                        height: 52
                        SignalBars {
                            id: bars
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            signal: row.ap.signal
                        }
                        Column {
                            anchors.left: bars.right
                            anchors.leftMargin: 14
                            anchors.right: chevron.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Row {
                                spacing: 6
                                StyledText {
                                    text: row.ap.ssid
                                    font.pixelSize: Config.Appearance.fs(13)
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }
                                MonoIcon {
                                    visible: row.ap.secured
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "lock"; size: 12; monochrome: true
                                    inkColor: Config.Appearance.ink3
                                }
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: row.busy ? "Connecting…"
                                    : row.err !== "" ? "Didn't connect — open for details"
                                    : [row.profile ? "Saved" : "", panel.net.securityLabel(row.ap), row.ap.band]
                                        .filter(s => s).join(" · ")
                                font.pixelSize: Config.Appearance.fs(12)
                                color: row.err !== "" && !row.busy ? panel.danger : Config.Appearance.ink3
                            }
                        }
                        MonoIcon {
                            id: chevron
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            name: row.open ? "chevronUp" : "chevronDown"
                            size: 14; monochrome: true
                            inkColor: Config.Appearance.ink3
                        }
                        HoverHandler { id: headHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: panel.openRow(row.ap.ssid) }
                    }

                    // What opening it offers.
                    // Sized by hand: a Loader keeps its last height after
                    // it unloads, which left a gap where a form had been.
                    Loader {
                        active: row.open
                        width: parent.width
                        height: active && item ? item.implicitHeight : 0
                        sourceComponent: Column {
                            x: 14
                            width: row.width - 28
                            spacing: 12
                            bottomPadding: 14

                            Line {
                                visible: row.err !== ""
                                text: row.err
                                color: panel.danger
                            }

                            // ── saved ─────────────────────────────────────
                            Column {
                                visible: !!row.profile
                                width: parent.width
                                spacing: 12
                                Line {
                                    visible: !!row.profile && row.profile.enterprise
                                    readonly property var info: row.profile ? panel.net.profileInfo[row.profile.uuid] : null
                                    text: !info ? "Signs in with a username and password."
                                        : "Signs in" + (info.identity ? " as " + info.identity : "")
                                          + " with " + info.eap.toUpperCase()
                                          + (info.phase2 ? " / " + info.phase2.toUpperCase() : "")
                                          + (info.systemCa ? ", checking the server against the system's certificates"
                                             : info.ca ? ", checking the server's certificate"
                                             : ", without checking the server's certificate") + "."
                                }
                                Row {
                                    spacing: 8
                                    NetButton {
                                        label: row.busy ? "Connecting…" : "Connect"
                                        primary: true
                                        active: !row.busy
                                        visible: !panel.fEditSignIn && !panel.fNewPassword
                                        onClicked: panel.net.join(row.ap.ssid, "")
                                    }
                                    NetButton {
                                        visible: !!row.profile && !row.profile.enterprise && !panel.fNewPassword
                                        label: "New password"
                                        onClicked: panel.fNewPassword = true
                                    }
                                    NetButton {
                                        visible: !!row.profile && row.profile.enterprise && !panel.fEditSignIn
                                        label: "Change sign-in"
                                        onClicked: {
                                            panel.prefillFrom(panel.net.profileInfo[row.profile.uuid]);
                                            panel.fEditSignIn = true;
                                        }
                                    }
                                    NetButton {
                                        label: "Forget"; danger: true
                                        onClicked: { panel.net.forget(row.profile.uuid); panel.openSsid = ""; }
                                    }
                                }
                                Row {
                                    visible: !!row.profile && !panel.fEditSignIn && !panel.fNewPassword
                                    spacing: 10
                                    Toggle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        checked: !!row.profile && row.profile.autoconnect
                                        onToggled: on => panel.net.setAutoconnect(row.profile.uuid, on)
                                    }
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Connect automatically"
                                        font.pixelSize: Config.Appearance.fs(12)
                                    }
                                }
                            }

                            // ── a password (new home network, or a saved
                            // one whose password changed) ─────────────────
                            Column {
                                visible: (!row.profile && row.ap.secured && !row.ap.enterprise) || panel.fNewPassword
                                width: parent.width
                                spacing: 12
                                NetField {
                                    width: Math.min(parent.width, 360)
                                    label: "Password"
                                    secret: true
                                    text: panel.fPassword
                                    onEdited: t => panel.fPassword = t
                                    onAccepted: if (panel.fPassword !== "") panel.net.join(row.ap.ssid, panel.fPassword)
                                }
                                Row {
                                    spacing: 8
                                    NetButton {
                                        label: row.busy ? "Connecting…" : "Connect"
                                        primary: true
                                        active: panel.fPassword !== "" && !row.busy
                                        onClicked: panel.net.join(row.ap.ssid, panel.fPassword)
                                    }
                                    NetButton { label: "Cancel"; onClicked: panel.openSsid = "" }
                                }
                            }

                            // ── open, new ─────────────────────────────────
                            Column {
                                visible: !row.profile && !row.ap.secured
                                width: parent.width
                                spacing: 10
                                Line { text: "An open network: anyone nearby can see what you send over it that isn't encrypted." }
                                NetButton {
                                    label: row.busy ? "Connecting…" : "Connect"
                                    primary: true
                                    active: !row.busy
                                    onClicked: panel.net.join(row.ap.ssid, "")
                                }
                            }

                            // ── sign-in: new university network, or a
                            // saved one's settings opened ──────────────────
                            Loader {
                                active: (!row.profile && row.ap.enterprise) || panel.fEditSignIn
                                width: parent.width
                                height: active && item ? item.implicitHeight : 0
                                sourceComponent: signInForm
                                property string target: row.ap.ssid
                                property bool saved: !!row.profile
                                property bool busy: row.busy
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            visible: panel.list.length > 12
            topPadding: 6
            text: panel.showAll ? "Show fewer" : "Show all " + panel.list.length + " networks"
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.DemiBold
            color: Config.Appearance.accent
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: panel.showAll = !panel.showAll }
        }

        Line {
            visible: panel.list.length === 0
            topPadding: 6
            text: panel.net.scanning ? "Looking for networks…" : "No other networks in range."
        }
    }

    // ══ the sign-in form, KDE's options ═══════════════════════════════════
    // Loaded with `target` (the network), `saved` and `busy` on its Loader.
    Component {
        id: signInForm
        Column {
            id: form
            readonly property string target: parent ? parent.target : ""
            readonly property bool saved: parent ? parent.saved : false
            readonly property bool busy: parent ? parent.busy : false
            width: parent ? parent.width : 0
            spacing: 12

            Line {
                text: "This network signs you in with your own account — usually your university or "
                    + "work email and password (eduroam: your full email address)."
            }
            NetField {
                width: Math.min(form.width, 360)
                label: "Username"
                placeholder: "name@university.edu"
                text: panel.fIdentity
                onEdited: t => panel.fIdentity = t
            }
            NetField {
                width: Math.min(form.width, 360)
                label: "Password"
                placeholder: form.saved ? "Unchanged" : ""
                secret: true
                text: panel.fPassword
                onEdited: t => panel.fPassword = t
            }

            StyledText {
                text: panel.fMore ? "Fewer options" : "More options"
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: Config.Appearance.accent
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: panel.fMore = !panel.fMore }
            }

            Column {
                visible: panel.fMore
                width: form.width
                spacing: 12

                Line { text: "Your university's IT pages list these, often under \"eduroam\" or \"Wi-Fi on Linux\". PEAP with MSCHAPv2 is the most common; TTLS with PAP is next." }

                Column {
                    spacing: 5
                    StyledText { text: "Sign-in method"; font.pixelSize: Config.Appearance.fs(12); font.weight: Font.Medium; color: Config.Appearance.ink2 }
                    Segmented {
                        options: [{ label: "PEAP", value: "peap" }, { label: "TTLS", value: "ttls" },
                                  { label: "PWD", value: "pwd" }]
                        value: panel.fEap
                        onSelected: v => {
                            panel.fEap = v;
                            if (v === "ttls" && panel.fPhase2 === "mschapv2") panel.fPhase2 = "pap";
                            if (v === "peap" && panel.fPhase2 === "pap") panel.fPhase2 = "mschapv2";
                        }
                    }
                }
                Column {
                    visible: panel.fEap !== "pwd"
                    spacing: 5
                    StyledText { text: "Inner authentication"; font.pixelSize: Config.Appearance.fs(12); font.weight: Font.Medium; color: Config.Appearance.ink2 }
                    Segmented {
                        options: panel.fEap === "ttls"
                            ? [{ label: "PAP", value: "pap" }, { label: "MSCHAPv2", value: "mschapv2" },
                               { label: "MSCHAP", value: "mschap" }, { label: "CHAP", value: "chap" }]
                            : [{ label: "MSCHAPv2", value: "mschapv2" }, { label: "GTC", value: "gtc" },
                               { label: "MD5", value: "md5" }]
                        value: panel.fPhase2
                        onSelected: v => panel.fPhase2 = v
                    }
                }
                Column {
                    spacing: 5
                    width: form.width
                    StyledText { text: "Server certificate"; font.pixelSize: Config.Appearance.fs(12); font.weight: Font.Medium; color: Config.Appearance.ink2 }
                    Segmented {
                        options: [{ label: "Don't check", value: "none" }, { label: "System's", value: "system" },
                                  { label: "File…", value: "file" }]
                        value: panel.fCa
                        onSelected: v => { panel.fCa = v; if (v === "file" && panel.fCaFile === "") pickCa.running = true; }
                    }
                    Line {
                        text: panel.fCa === "none"
                            ? "Joins without checking it's really your university's network. Works everywhere, but a fake network with the same name could collect your password."
                            : panel.fCa === "system"
                            ? "Checks the server against the certificates this computer trusts. Add the domain below too."
                            : (panel.fCaFile !== "" ? panel.fCaFile : "No file chosen")
                    }
                    NetButton {
                        visible: panel.fCa === "file"
                        label: panel.fCaFile === "" ? "Choose file…" : "Change file…"
                        onClicked: pickCa.running = true
                    }
                }
                NetField {
                    width: Math.min(form.width, 360)
                    label: "Domain"
                    placeholder: "radius.university.edu"
                    hint: "Optional. The server's name must end in this — what makes the certificate check mean something."
                    text: panel.fDomain
                    onEdited: t => panel.fDomain = t
                }
                NetField {
                    width: Math.min(form.width, 360)
                    label: "Anonymous identity"
                    placeholder: "anonymous@university.edu"
                    hint: "Optional. What's sent before the encrypted part; some networks ask for one."
                    text: panel.fAnon
                    onEdited: t => panel.fAnon = t
                }
            }

            Row {
                spacing: 8
                NetButton {
                    label: form.busy ? "Connecting…" : form.saved ? "Save and connect" : "Connect"
                    primary: true
                    active: !form.busy && panel.fIdentity.trim() !== "" && (panel.fPassword !== "" || form.saved)
                    onClicked: {
                        if (panel.hiddenOpen) panel.net.joinHidden(form.target, "enterprise", panel.fPassword, panel.enterpriseOpts());
                        else panel.net.joinEnterprise(form.target, panel.enterpriseOpts());
                    }
                }
                NetButton {
                    label: "Cancel"
                    onClicked: { if (panel.fEditSignIn) panel.fEditSignIn = false; else { panel.openSsid = ""; panel.hiddenOpen = false; } }
                }
            }
        }
    }

    // ══ a hidden network ══════════════════════════════════════════════════
    Column {
        visible: panel.net.available && panel.net.wifiEnabled
        width: panel.width
        spacing: 12

        StyledText {
            text: panel.hiddenOpen ? "Hidden network" : "Join a hidden network…"
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.DemiBold
            color: panel.hiddenOpen ? Config.Appearance.ink : Config.Appearance.accent
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: {
                    panel.openSsid = "";
                    panel.resetForm();
                    panel.hiddenOpen = !panel.hiddenOpen;
                }
            }
        }
        Column {
            visible: panel.hiddenOpen
            width: panel.width
            spacing: 12
            readonly property string err: panel.net.errors[panel.hName] || ""
            NetField {
                width: Math.min(panel.width, 360)
                label: "Network name"
                text: panel.hName
                onEdited: t => panel.hName = t
            }
            Segmented {
                options: [{ label: "Password", value: "psk" }, { label: "Sign-in", value: "enterprise" },
                          { label: "Open", value: "open" }]
                value: panel.hKind
                onSelected: v => panel.hKind = v
            }
            NetField {
                visible: panel.hKind === "psk"
                width: Math.min(panel.width, 360)
                label: "Password"
                secret: true
                text: panel.fPassword
                onEdited: t => panel.fPassword = t
            }
            Loader {
                active: panel.hKind === "enterprise"
                width: panel.width
                height: active && item ? item.implicitHeight : 0
                sourceComponent: signInForm
                property string target: panel.hName.trim()
                property bool saved: false
                property bool busy: panel.net.busySsid === panel.hName.trim()
            }
            Row {
                visible: panel.hKind !== "enterprise"
                spacing: 8
                NetButton {
                    label: panel.net.busySsid === panel.hName.trim() && panel.hName !== "" ? "Connecting…" : "Connect"
                    primary: true
                    active: panel.hName.trim() !== "" && (panel.hKind === "open" || panel.fPassword !== "")
                    onClicked: panel.net.joinHidden(panel.hName.trim(), panel.hKind, panel.fPassword)
                }
                NetButton { label: "Cancel"; onClicked: panel.hiddenOpen = false }
            }
            Line { visible: parent.err !== ""; text: parent.err; color: panel.danger }
        }
    }

    // ══ saved, not in range ═══════════════════════════════════════════════
    Column {
        readonly property var away: panel.net.saved.filter(p =>
            !panel.net.networks.some(n => n.ssid === p.ssid))
        visible: panel.net.available && away.length > 0
        width: panel.width
        spacing: 2

        Item {
            width: panel.width
            height: 26
            Caption { anchors.verticalCenter: parent.verticalCenter; text: "Saved networks" }
            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: panel.showSaved ? "Hide" : "Show " + parent.parent.away.length
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: Config.Appearance.accent
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: panel.showSaved = !panel.showSaved }
            }
        }
        Repeater {
            model: panel.showSaved ? parent.away : []
            Item {
                required property var modelData
                width: panel.width
                height: 44
                Column {
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText { text: modelData.ssid; font.pixelSize: Config.Appearance.fs(13); font.weight: Font.Medium }
                    StyledText {
                        text: (modelData.enterprise ? "Sign-in" : modelData.keyMgmt ? "Password" : "Open")
                              + (modelData.autoconnect ? " · connects automatically" : "")
                        font.pixelSize: Config.Appearance.fs(11)
                        color: Config.Appearance.ink3
                    }
                }
                NetButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Forget"; danger: true
                    onClicked: panel.net.forget(modelData.uuid)
                }
            }
        }
    }

    // ══ the rest ══════════════════════════════════════════════════════════
    Column {
        visible: panel.net.available
        width: panel.width
        spacing: 8
        Line {
            visible: panel.net.vpnActive
            text: "VPN: " + panel.net.vpnName + " is connected."
        }
        Row {
            spacing: 8
            NetButton { label: "All connections…"; onClicked: panel.net.openEditor() }
        }
        Line { text: "Wired, VPN and anything not covered here are in NetworkManager's own editor (nm-connection-editor)." }
    }
}
