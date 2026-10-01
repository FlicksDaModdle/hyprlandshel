import QtQuick
import Hyprshell

// The archive sheet, in three modes, from app.archiveSheet:
//
//   { mode: "compress", names: [...] }          make an archive of these
//   { mode: "extract", archive, name, paths? }  get things out, choosing where
//   { mode: "browse", archive, name }           look inside without unpacking
//
// The work itself is Archives.qml's; this asks the questions. A sheet in
// the window, as Properties is, rather than a dialog of its own.
PanelSurface {
    id: sheet

    required property var app
    readonly property var svc: FilesService
    readonly property var arc: Archives
    readonly property var spec: sheet.app.archiveSheet
    readonly property string mode: sheet.spec ? sheet.spec.mode : ""

    showSeam: false
    visible: sheet.spec !== null
    z: 950
    implicitWidth: sheet.mode === "browse" ? 560 : 440
    implicitHeight: Math.min(column.implicitHeight + 28, sheet.maxHeight)
    property real maxHeight: 640
    clip: true

    // ── form state, reset whenever a new sheet opens ──────────────────────
    property string name: ""
    property string format: "zip"
    property int level: 5
    property string password: ""
    property bool showPassword: false
    property bool encryptNames: true
    property string volume: ""
    property string folder: ""
    property bool intoFolder: true
    property string overwrite: "rename"
    // browse
    property var listing: null           // { entries, needsPassword, error } or null while loading
    property string prefix: ""           // the folder inside the archive being looked at
    property var picked: []

    onSpecChanged: {
        sheet.password = ""; sheet.showPassword = false; sheet.picked = []; sheet.prefix = "";
        sheet.listing = null; sheet.volume = "";
        if (!sheet.spec) return;
        // The spec's own mode, not `sheet.mode`: that binding may not have
        // caught up yet while this handler runs.
        const mode = sheet.spec.mode;
        if (mode === "compress") {
            const n = sheet.spec.names || [];
            sheet.name = n.length === 1 ? sheet.arc.stem(n[0]) : sheet.svc.basename(sheet.app.cwd) || "Archive";
            sheet.format = sheet.arc.hasSevenZip ? "zip" : "tar.zst";
            sheet.level = 5;
        } else if (mode === "extract") {
            sheet.folder = sheet.arc.stem(sheet.spec.name);
            sheet.intoFolder = true;
            sheet.overwrite = "rename";
            sheet.password = sheet.spec.password || "";
        } else if (mode === "browse") {
            sheet.load();
        }
    }

    function load() {
        sheet.listing = null;
        const archive = sheet.spec.archive;
        sheet.arc.list(archive, sheet.password, r => {
            if (sheet.spec && sheet.spec.archive === archive) sheet.listing = r;
        });
    }

    function close() { sheet.app.archiveSheet = null; }

    // A name in the current folder nothing has yet: "photos", then
    // "photos (2)", …
    function unique(base) {
        const taken = {};
        for (const e of sheet.app.entries) taken[e.name] = true;
        if (!taken[base]) return base;
        for (let i = 2; i < 1000; i++) if (!taken[base + " (" + i + ")"]) return base + " (" + i + ")";
        return base;
    }

    readonly property bool sevenFormat: sheet.format === "zip" || sheet.format === "7z"
    readonly property bool blocked: sheet.mode === "compress" && sheet.sevenFormat && !sheet.arc.hasSevenZip

    function submit() {
        if (sheet.mode === "compress") {
            if (sheet.name.trim() === "" || sheet.blocked) return;
            const out = sheet.unique(sheet.name.trim() + sheet.arc.suffixFor(sheet.format));
            sheet.arc.compress({ dir: sheet.app.cwd, names: sheet.spec.names, out: out, format: sheet.format,
                                 level: sheet.level, password: sheet.sevenFormat ? sheet.password : "",
                                 encryptNames: sheet.encryptNames,
                                 volume: sheet.sevenFormat ? sheet.volume : "" });
            sheet.app.pendingSelect = out;
        } else if (sheet.mode === "extract") {
            const dest = sheet.intoFolder && sheet.folder.trim() !== ""
                ? sheet.svc.join(sheet.app.cwd, sheet.unique(sheet.folder.trim()))
                : sheet.app.cwd;
            sheet.arc.extract({ archive: sheet.spec.archive, dest: dest, paths: sheet.spec.paths || [],
                                password: sheet.password, overwrite: sheet.overwrite });
        }
        sheet.close();
    }

    // ── what is in the folder being looked at, inside the archive ─────────
    readonly property var here: {
        const l = sheet.listing;
        if (!l || !l.entries) return [];
        const pre = sheet.prefix === "" ? "" : sheet.prefix + "/";
        const out = [];
        for (const e of l.entries) {
            if (pre !== "" && e.path.indexOf(pre) !== 0) continue;
            const rest = e.path.slice(pre.length);
            if (rest === "" || rest.indexOf("/") >= 0) continue;
            out.push(Object.assign({ name: rest }, e));
        }
        out.sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name));
        return out;
    }
    readonly property var totals: {
        const l = sheet.listing;
        if (!l || !l.entries) return { files: 0, size: 0, packed: 0, encrypted: false };
        let files = 0, size = 0, packed = 0, enc = false;
        for (const e of l.entries) if (!e.dir) { files++; size += e.size; packed += e.packed; enc = enc || e.encrypted; }
        return { files: files, size: size, packed: packed, encrypted: enc };
    }
    function togglePick(path) {
        const p = sheet.picked.slice();
        const i = p.indexOf(path);
        if (i >= 0) p.splice(i, 1); else p.push(path);
        sheet.picked = p;
    }

    // ── pieces ────────────────────────────────────────────────────────────
    component Label: StyledText {
        font.pixelSize: Appearance.fs(12)
        font.weight: Font.Medium
        color: Appearance.ink2
    }
    component Note: StyledText {
        width: parent ? parent.width : 0
        wrapMode: Text.WordWrap
        font.pixelSize: Appearance.fs(11)
        color: Appearance.ink3
    }
    component Btn: Rectangle {
        id: btn
        property string label: ""
        property bool primary: false
        property bool active: true
        signal clicked()
        implicitWidth: btnText.implicitWidth + 26
        implicitHeight: 32
        radius: Appearance.rSm
        opacity: btn.active ? 1 : 0.45
        color: btn.primary ? Appearance.accent : (btnArea.containsMouse && btn.active ? Appearance.sel : Appearance.surface)
        StyledText {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            font.pixelSize: Appearance.fs(12)
            font.weight: Font.DemiBold
            color: btn.primary ? Appearance.inkOnAccent : Appearance.ink
        }
        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: btn.active ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (btn.active) btn.clicked()
        }
    }
    // Segments: [{ label, value }].
    component Seg: Row {
        id: seg
        property var options: []
        property var value
        signal picked(var v)
        spacing: 2
        Repeater {
            model: seg.options
            Rectangle {
                required property var modelData
                readonly property bool on: modelData.value === seg.value
                implicitWidth: segText.implicitWidth + 20
                implicitHeight: 28
                radius: Appearance.rSm
                color: on ? Appearance.accent : (segArea.containsMouse ? Appearance.sel : Appearance.surface)
                StyledText {
                    id: segText
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.DemiBold
                    color: parent.on ? Appearance.inkOnAccent : Appearance.ink2
                }
                MouseArea {
                    id: segArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(modelData.value)
                }
            }
        }
    }
    component Field: Rectangle {
        id: field
        property alias text: input.text
        property string placeholder: ""
        property bool secret: false
        property bool reveal: false
        property string suffix: ""
        signal accepted()
        implicitHeight: 34
        radius: Appearance.rSm
        color: Appearance.ground
        border.width: input.activeFocus ? 2 : 1
        border.color: input.activeFocus ? Appearance.accent : Appearance.rule
        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10 + (suffixText.visible ? suffixText.implicitWidth + 6 : 0)
                                    + (eye.visible ? eye.implicitWidth + 8 : 0)
            verticalAlignment: Text.AlignVCenter
            clip: true
            color: Appearance.ink
            selectionColor: Appearance.accent
            font.family: Appearance.fontFamily
            font.pixelSize: Appearance.fs(13)
            echoMode: field.secret && !field.reveal ? TextInput.Password : TextInput.Normal
            selectByMouse: true
            // Enter is the field's, and goes no further: let through, the
            // window behind took it as "open the selected file", which
            // opened the archive again under the sheet and wiped it.
            Keys.onReturnPressed: e => { e.accepted = true; field.accepted(); }
            Keys.onEnterPressed: e => { e.accepted = true; field.accepted(); }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === ""
                text: field.placeholder
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink3
            }
        }
        StyledText {
            id: suffixText
            visible: field.suffix !== ""
            anchors.right: eye.visible ? eye.left : parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: field.suffix
            font.pixelSize: Appearance.fs(13)
            color: Appearance.ink3
        }
        StyledText {
            id: eye
            visible: field.secret
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: field.reveal ? "Hide" : "Show"
            font.pixelSize: Appearance.fs(11)
            font.weight: Font.DemiBold
            color: eyeArea.containsMouse ? Appearance.ink : Appearance.ink3
            MouseArea {
                id: eyeArea
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: field.reveal = !field.reveal
            }
        }
    }
    component Check: Item {
        id: check
        property bool checked: false
        property string label: ""
        signal toggled(bool on)
        implicitWidth: checkRow.implicitWidth
        implicitHeight: 22
        Row {
            id: checkRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle {
                width: 18; height: 18
                radius: 5
                anchors.verticalCenter: parent.verticalCenter
                color: check.checked ? Appearance.accent : Appearance.ground
                border.width: check.checked ? 0 : 1
                border.color: Appearance.rule
                StyledText {
                    anchors.centerIn: parent
                    visible: check.checked
                    text: "✓"
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.Bold
                    color: Appearance.inkOnAccent
                }
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: check.label
                font.pixelSize: Appearance.fs(12)
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: check.toggled(!check.checked)
        }
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        spacing: 14

        StyledText {
            width: parent.width
            elide: Text.ElideMiddle
            text: sheet.mode === "compress"
                  ? "Compress " + ((sheet.spec && sheet.spec.names.length === 1) ? sheet.spec.names[0]
                                   : (sheet.spec ? sheet.spec.names.length : 0) + " items")
                  : sheet.spec ? sheet.spec.name : ""
            font.pixelSize: Appearance.fs(15)
            font.weight: Font.DemiBold
        }

        // ══ compress ══════════════════════════════════════════════════════
        Column {
            visible: sheet.mode === "compress"
            width: parent.width
            spacing: 14

            Column {
                width: parent.width; spacing: 6
                Label { text: "Name" }
                Field {
                    width: parent.width
                    text: sheet.name
                    suffix: sheet.arc.suffixFor(sheet.format)
                    onTextChanged: sheet.name = text
                    onAccepted: sheet.submit()
                }
            }
            Column {
                width: parent.width; spacing: 6
                Label { text: "Format" }
                Seg {
                    options: sheet.arc.formats.map(f => ({ label: f.label, value: f.value }))
                    value: sheet.format
                    onPicked: v => sheet.format = v
                }
                Note {
                    text: (sheet.arc.formats.find(f => f.value === sheet.format) || {}).note || ""
                }
                Note {
                    visible: sheet.blocked
                    color: Appearance.accent
                    text: "ZIP and 7z need 7-Zip — install the 7zip package (or p7zip). tar formats work without it."
                }
            }
            Column {
                width: parent.width; spacing: 6
                Label { text: "Compression" }
                Seg {
                    options: [{ label: "Store", value: 0 }, { label: "Fast", value: 1 }, { label: "Normal", value: 5 },
                              { label: "Maximum", value: 7 }, { label: "Ultra", value: 9 }]
                    value: sheet.level
                    onPicked: v => sheet.level = v
                }
                Note {
                    text: sheet.level === 0 ? "No compression: quickest, for things that are already compressed (photos, video)."
                        : sheet.level >= 9 ? "Smallest, and much slower — worth it for text and code, not for media."
                        : ""
                    visible: text !== ""
                }
            }
            Column {
                visible: sheet.sevenFormat
                width: parent.width; spacing: 6
                Label { text: "Password (optional)" }
                Field {
                    width: parent.width
                    secret: true
                    placeholder: "No password"
                    text: sheet.password
                    onTextChanged: sheet.password = text
                }
                Note {
                    visible: sheet.password !== ""
                    text: sheet.format === "zip"
                          ? "AES-256. File names inside a ZIP stay readable without the password; use 7z to hide them too."
                          : "AES-256."
                }
                Check {
                    visible: sheet.password !== "" && sheet.format === "7z"
                    label: "Hide file names too"
                    checked: sheet.encryptNames
                    onToggled: on => sheet.encryptNames = on
                }
            }
            Column {
                visible: sheet.sevenFormat
                width: parent.width; spacing: 6
                Label { text: "Split into parts" }
                Seg {
                    options: [{ label: "No", value: "" }, { label: "100 MB", value: "100m" },
                              { label: "1 GB", value: "1g" }, { label: "4 GB", value: "4000m" }]
                    value: sheet.volume
                    onPicked: v => sheet.volume = v
                }
            }
            Row {
                spacing: 8
                Btn {
                    label: "Compress"; primary: true
                    active: sheet.name.trim() !== "" && !sheet.blocked
                    onClicked: sheet.submit()
                }
                Btn { label: "Cancel"; onClicked: sheet.close() }
            }
        }

        // ══ extract ═══════════════════════════════════════════════════════
        Column {
            visible: sheet.mode === "extract"
            width: parent.width
            spacing: 14

            Note {
                visible: !!(sheet.spec && sheet.spec.paths && sheet.spec.paths.length)
                text: sheet.spec && sheet.spec.paths ? sheet.spec.paths.length + " selected item"
                      + (sheet.spec.paths.length === 1 ? "" : "s") + " from it" : ""
            }
            Column {
                width: parent.width; spacing: 6
                Check {
                    label: "Into a new folder"
                    checked: sheet.intoFolder
                    onToggled: on => sheet.intoFolder = on
                }
                Field {
                    visible: sheet.intoFolder
                    width: parent.width
                    text: sheet.folder
                    onTextChanged: sheet.folder = text
                    onAccepted: sheet.submit()
                }
                Note {
                    text: "In " + sheet.svc.pretty(sheet.app.cwd)
                          + (sheet.intoFolder ? "" : ", alongside what's already there")
                }
            }
            Column {
                width: parent.width; spacing: 6
                Label { text: "When a file is already there" }
                Seg {
                    options: [{ label: "Keep both", value: "rename" }, { label: "Skip", value: "skip" },
                              { label: "Replace", value: "overwrite" }]
                    value: sheet.overwrite
                    onPicked: v => sheet.overwrite = v
                }
            }
            Column {
                visible: !(sheet.spec && sheet.arc.isTar(sheet.spec.archive))
                width: parent.width; spacing: 6
                Label { text: "Password" }
                Field {
                    width: parent.width
                    secret: true
                    placeholder: "Only if it has one"
                    text: sheet.password
                    onTextChanged: sheet.password = text
                    onAccepted: sheet.submit()
                }
            }
            Row {
                spacing: 8
                Btn { label: "Extract"; primary: true; onClicked: sheet.submit() }
                Btn { label: "Cancel"; onClicked: sheet.close() }
            }
        }

        // ══ browse ════════════════════════════════════════════════════════
        Column {
            visible: sheet.mode === "browse"
            width: parent.width
            spacing: 12

            StyledText {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
                text: !sheet.listing ? "Reading…"
                    : sheet.listing.error !== "" ? ""
                    : sheet.totals.files + (sheet.totals.files === 1 ? " file, " : " files, ")
                      + sheet.svc.humanSize(sheet.totals.size)
                      + (sheet.totals.packed > 0 && sheet.totals.size > 0
                         ? " — packed to " + Math.round(100 * sheet.totals.packed / sheet.totals.size) + "%" : "")
                      + (sheet.totals.encrypted ? " · password-protected" : "")
            }

            // Locked: ask, then read it again.
            Column {
                visible: !!sheet.listing && sheet.listing.error !== ""
                width: parent.width
                spacing: 10
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: sheet.listing ? sheet.listing.error : ""
                    font.pixelSize: Appearance.fs(12)
                    color: sheet.listing && sheet.listing.needsPassword ? Appearance.ink2 : Appearance.accent
                }
                Row {
                    visible: !!sheet.listing && sheet.listing.needsPassword
                    spacing: 8
                    Field {
                        width: 260
                        secret: true
                        placeholder: "Password"
                        text: sheet.password
                        onTextChanged: sheet.password = text
                        onAccepted: sheet.load()
                    }
                    Btn { label: "Open"; primary: true; active: sheet.password !== ""; onClicked: sheet.load() }
                }
            }

            // Where in the archive.
            Row {
                visible: !!sheet.listing && sheet.listing.error === ""
                spacing: 4
                Repeater {
                    model: [""].concat(sheet.prefix === "" ? [] : sheet.prefix.split("/").map((p, i, a) => a.slice(0, i + 1).join("/")))
                    StyledText {
                        required property var modelData
                        required property int index
                        text: (index > 0 ? "› " : "") + (modelData === "" ? sheet.arc.stem(sheet.spec ? sheet.spec.name : "") : modelData.split("/").pop())
                        font.pixelSize: Appearance.fs(12)
                        font.weight: modelData === sheet.prefix ? Font.DemiBold : Font.Normal
                        color: modelData === sheet.prefix ? Appearance.ink : Appearance.accent
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: sheet.prefix = modelData
                        }
                    }
                }
            }

            Rectangle {
                visible: !!sheet.listing && sheet.listing.error === ""
                width: parent.width
                height: Math.min(list.contentHeight + 2, 330)
                radius: Appearance.rSm
                color: Appearance.ground
                border.width: 1
                border.color: Appearance.rule
                clip: true

                ListView {
                    id: list
                    anchors.fill: parent
                    anchors.margins: 1
                    model: sheet.here
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool chosen: sheet.picked.indexOf(modelData.path) >= 0
                        width: list.width
                        height: 34
                        color: chosen ? Appearance.sel : (rowArea.containsMouse ? Appearance.hover : "transparent")
                        Rectangle {
                            id: box
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16; height: 16; radius: 4
                            color: parent.chosen ? Appearance.accent : "transparent"
                            border.width: parent.chosen ? 0 : 1
                            border.color: Appearance.rule
                            StyledText {
                                anchors.centerIn: parent
                                visible: parent.parent.chosen
                                text: "✓"
                                font.pixelSize: Appearance.fs(11)
                                font.weight: Font.Bold
                                color: Appearance.inkOnAccent
                            }
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sheet.togglePick(modelData.path)
                            }
                        }
                        MonoIcon {
                            id: glyph
                            anchors.left: box.right
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData.dir ? "folder" : "file"
                            size: 18
                            inkColor: Appearance.ink2
                            accentColor: Appearance.accent
                        }
                        StyledText {
                            anchors.left: glyph.right
                            anchors.leftMargin: 9
                            anchors.right: sizeText.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.name + (modelData.encrypted ? "  🔒" : "")
                            elide: Text.ElideMiddle
                            font.pixelSize: Appearance.fs(12)
                        }
                        StyledText {
                            id: sizeText
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.dir ? "" : sheet.svc.humanSize(modelData.size)
                            font.pixelSize: Appearance.fs(11)
                            color: Appearance.ink3
                        }
                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            anchors.leftMargin: 32
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Into a folder; a file is picked.
                            onClicked: modelData.dir ? sheet.prefix = modelData.path : sheet.togglePick(modelData.path)
                        }
                    }
                }
            }

            Row {
                spacing: 8
                Btn {
                    visible: !!sheet.listing && sheet.listing.error === ""
                    primary: true
                    label: sheet.picked.length > 0 ? "Extract " + sheet.picked.length + " selected…" : "Extract all…"
                    onClicked: sheet.app.archiveSheet = { mode: "extract", archive: sheet.spec.archive,
                                                          name: sheet.spec.name, paths: sheet.picked.slice(),
                                                          password: sheet.password }
                }
                Btn {
                    visible: !!sheet.listing && sheet.listing.error === ""
                    label: "Test"
                    onClicked: { sheet.arc.test(sheet.spec.archive, sheet.password); }
                }
                Btn { label: "Close"; onClicked: sheet.close() }
            }
        }
    }
}
