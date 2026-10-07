import QtQuick
import Hyprshell
import Hyprshell.Backend

// To, Cc or Bcc: the people as chips, a box to type more, and suggestions
// from the address book as you type. Enter, Tab, comma or a pick turns
// what is typed into a chip; Backspace in an empty box takes the last back.
Item {
    id: af
    property string label: "To"
    property var people: []
    property var suggestions: []
    property int pick: 0
    signal changed(var people)
    // Tab out of an empty box: on to the next field.
    signal tabbed()
    readonly property string typed: input.text.trim()
    implicitHeight: Math.max(36, flow.implicitHeight + 10)

    function valid(e) { return /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/.test(e); }
    function add(p) {
        if (!p || !p.email) return;
        if (af.people.some(x => x.email.toLowerCase() === p.email.toLowerCase())) { input.text = ""; return; }
        af.people = af.people.concat([p]);
        af.changed(af.people);
        input.text = "";
        af.suggestions = [];
    }
    // "Name <a@b>", or a bare address.
    function commit() {
        const t = af.typed.replace(/[,;]+$/, "");
        if (!t) return false;
        const m = /^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/.exec(t);
        af.add(m ? { name: m[1].trim(), email: m[2].trim() } : { name: "", email: t });
        return true;
    }
    // A name, not an address, and no suggestions shown yet: the best match
    // from the address book, or what was typed if there is none.
    function best() {
        const q = af.typed;
        lookup.stop();
        Mail.call("contacts.search", { q: q, limit: 1 }, (ok, r) => {
            if (af.typed !== q) return;
            if (ok && r.length > 0) af.add(r[0]); else af.commit();
        });
    }
    function remove(i) { const p = af.people.slice(); p.splice(i, 1); af.people = p; af.changed(p); }
    function focusIn() { input.forceActiveFocus(); }

    StyledText {
        id: lbl
        x: 0
        y: 10
        width: 48
        text: af.label
        font.pixelSize: Appearance.fs(12.5)
        color: Appearance.ink3
    }
    Flow {
        id: flow
        anchors.left: lbl.right
        anchors.right: parent.right
        y: 5
        spacing: 6
        Repeater {
            model: af.people
            Rectangle {
                id: chip
                required property var modelData
                required property int index
                readonly property bool ok: af.valid(modelData.email)
                height: 26
                width: chipRow.implicitWidth + 16
                radius: 13
                color: ok ? Appearance.sel : Qt.rgba(0.9, 0.2, 0.15, 0.25)
                Row {
                    id: chipRow
                    x: 4
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Avatar { anchors.verticalCenter: parent.verticalCenter; name: chip.modelData.name; email: chip.modelData.email; size: 18 }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: chip.modelData.name || chip.modelData.email
                        font.pixelSize: Appearance.fs(12)
                    }
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "x"; size: 12; inkColor: Appearance.ink3; monochrome: true
                        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: af.remove(chip.index) }
                    }
                }
                ToolTipLite { text: chip.modelData.email; shown: chipHover.hovered && chip.modelData.name !== "" }
                HoverHandler { id: chipHover }
            }
        }
        TextInput {
            id: input
            width: af.people.length === 0 ? flow.width - 4 : 180
            height: 26
            verticalAlignment: TextInput.AlignVCenter
            color: Appearance.ink
            selectionColor: Appearance.accent
            selectByMouse: true
            font.family: Appearance.fontFamily
            font.pixelSize: Appearance.fs(13)
            onTextEdited: {
                if (/[,;]$/.test(text)) { af.commit(); return; }
                lookup.restart();
            }
            Keys.onPressed: e => {
                if (af.suggestions.length > 0 && (e.key === Qt.Key_Down || e.key === Qt.Key_Up)) {
                    af.pick = (af.pick + (e.key === Qt.Key_Down ? 1 : af.suggestions.length - 1)) % af.suggestions.length;
                    e.accepted = true;
                } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || (e.key === Qt.Key_Tab && af.typed !== "")) {
                    if (af.suggestions.length > 0) af.add(af.suggestions[af.pick]);
                    else if (af.typed !== "" && af.typed.indexOf("@") < 0) af.best();
                    else af.commit();
                    e.accepted = true;
                } else if (e.key === Qt.Key_Tab) {
                    af.tabbed();
                    e.accepted = true;
                } else if (e.key === Qt.Key_Backspace && input.text === "" && af.people.length > 0) {
                    af.remove(af.people.length - 1);
                    e.accepted = true;
                } else if (e.key === Qt.Key_Escape && af.suggestions.length > 0) {
                    af.suggestions = [];
                    e.accepted = true;
                }
            }
            onActiveFocusChanged: if (!activeFocus) { af.commit(); af.suggestions = []; }
        }
    }
    Timer {
        id: lookup
        interval: 120
        onTriggered: {
            const q = af.typed;
            if (q.length < 1) { af.suggestions = []; return; }
            Mail.call("contacts.search", { q: q, limit: 6 }, (ok, r) => {
                if (!ok || af.typed !== q) return;
                af.suggestions = r.filter(c => !af.people.some(p => p.email.toLowerCase() === c.email.toLowerCase()));
                af.pick = 0;
            });
        }
    }
    MouseArea { anchors.fill: parent; z: -1; onClicked: input.forceActiveFocus() }

    // Suggestions, under the field, over what follows.
    PanelSurface {
        visible: af.suggestions.length > 0 && input.activeFocus
        showSeam: false
        color: Appearance.dialog
        z: 100
        x: lbl.width
        y: af.height + 2
        width: 340
        height: sugCol.implicitHeight + 8
        Column {
            id: sugCol
            x: 4; y: 4
            width: parent.width - 8
            Repeater {
                model: af.suggestions
                Rectangle {
                    id: sug
                    required property var modelData
                    required property int index
                    width: sugCol.width
                    height: 40
                    radius: Appearance.rSm
                    color: af.pick === index ? Appearance.sel : sugArea.containsMouse ? Appearance.hover : "transparent"
                    Avatar { x: 8; anchors.verticalCenter: parent.verticalCenter; name: sug.modelData.name; email: sug.modelData.email; size: 26 }
                    Column {
                        x: 44
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText { text: sug.modelData.name || sug.modelData.email; font.pixelSize: Appearance.fs(12.5); font.weight: Font.Medium }
                        StyledText { visible: sug.modelData.name !== ""; text: sug.modelData.email; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                    }
                    MouseArea { id: sugArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPressed: af.add(sug.modelData) }
                }
            }
        }
    }
}
