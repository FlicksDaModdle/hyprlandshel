import QtQuick
import Hyprshell

// A combo box, as 7-Zip's dialogs are made of: the value, a ▾, and a list
// that drops under it. `editable` makes the value a text field as well,
// for the ones 7-Zip lets you type into (the archive's name, the volume
// size, the folder to extract to).
//
// The list is drawn in `overlay`, or else across the whole window, so it is
// above everything after it in the layout and is not clipped by the box
// it sits in.
Item {
    id: combo

    property var model: []            // strings, or { label, value }
    property var value
    property bool editable: false
    property string text: ""          // what is typed, when editable
    property bool active: true
    property Item overlay: null
    signal picked(var value)
    signal edited(string text)

    implicitWidth: 180
    implicitHeight: 28
    opacity: combo.active ? 1 : 0.45

    function labelOf(o) { return (o !== null && typeof o === "object") ? o.label : String(o); }
    function valueOf(o) { return (o !== null && typeof o === "object") ? o.value : o; }
    readonly property string current: {
        for (const o of combo.model) if (combo.valueOf(o) === combo.value) return combo.labelOf(o);
        return combo.value === undefined || combo.value === null ? "" : String(combo.value);
    }
    property bool open: false
    onVisibleChanged: if (!visible) combo.open = false
    onOpenChanged: if (open) {
        drop.at = combo.mapToItem(combo.host, 0, combo.height + 2);
        // Keys to the list while it is out, so Escape puts away the list
        // and not the dialog under it.
        drop.forceActiveFocus();
    }
    readonly property Item host: combo.overlay || combo.Window.contentItem || combo

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: Appearance.ground
        border.width: (input.activeFocus || combo.open) ? 2 : 1
        border.color: (input.activeFocus || combo.open) ? Appearance.accent : Appearance.rule

        TextInput {
            id: input
            visible: combo.editable
            anchors.left: parent.left
            anchors.right: arrow.left
            anchors.leftMargin: 8
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            color: Appearance.ink
            selectionColor: Appearance.accent
            font.family: Appearance.fontFamily
            font.pixelSize: Appearance.fs(12)
            selectByMouse: true
            readOnly: !combo.active
            text: combo.text
            onTextEdited: combo.edited(text)
            // The start of a long path, not its end, while not being typed in.
            onTextChanged: if (!activeFocus) cursorPosition = 0
            Keys.onReturnPressed: e => { e.accepted = true; }
            Keys.onEnterPressed: e => { e.accepted = true; }
        }
        StyledText {
            visible: !combo.editable
            anchors.left: parent.left
            anchors.right: arrow.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: combo.current
            font.pixelSize: Appearance.fs(12)
        }
        StyledText {
            id: arrow
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "▾"
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink2
        }
        MouseArea {
            // The whole box opens the list, except where an editable
            // one's text is.
            anchors.fill: parent
            anchors.leftMargin: combo.editable ? parent.width - 26 : 0
            enabled: combo.active && combo.model.length > 0
            cursorShape: Qt.PointingHandCursor
            onClicked: combo.open = !combo.open
        }
    }

    // ── the list ──────────────────────────────────────────────────────────
    Item {
        parent: combo.host
        anchors.fill: parent
        // `visible` is the combo's effective one: closing the dialog it is
        // in puts the list away too, though the list is not inside it.
        visible: combo.open && combo.visible
        z: 5000

        // Anywhere else puts it away.
        MouseArea { anchors.fill: parent; onClicked: combo.open = false }

        Rectangle {
            id: drop
            // Measured each time it opens, not bound: a binding that only
            // touches `open` to re-run is one newer Qt's compiler drops the
            // touch from, and the list stayed where it was first worked out —
            // the window's top-left corner, before the dialog was laid out.
            property point at: Qt.point(0, 0)
            x: at.x
            // Above the box, as a menu would, when there is no room below.
            y: at.y + height + 4 <= combo.host.height ? at.y : Math.max(4, at.y - combo.height - height - 4)
            width: Math.max(combo.width, 120)
            height: Math.min(list.contentHeight + 6, 260)
            radius: 6
            color: Appearance.surface
            border.width: 1
            border.color: Appearance.rule
            clip: true
            Keys.onEscapePressed: e => { e.accepted = true; combo.open = false; }

            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: 3
                model: combo.model
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: combo.valueOf(modelData) === combo.value
                    width: list.width
                    height: 26
                    radius: 4
                    color: optArea.containsMouse ? Appearance.accent : on ? Appearance.sel : "transparent"
                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: combo.labelOf(modelData) === "" ? " " : combo.labelOf(modelData)
                        font.pixelSize: Appearance.fs(12)
                        color: optArea.containsMouse ? Appearance.inkOnAccent : Appearance.ink
                    }
                    MouseArea {
                        id: optArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            combo.open = false;
                            const v = combo.valueOf(modelData);
                            if (combo.editable) combo.edited(String(v));
                            combo.picked(v);
                        }
                    }
                }
            }
        }
    }
}
