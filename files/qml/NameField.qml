import QtQuick
import Hyprshell

// The field you type a name into — renaming a file, or naming a new folder.
//
// One component for both, because the awkward parts are the same in each:
// taking focus the moment it appears, selecting the stem rather than the
// extension so typing replaces "photo" and not "photo.png", and committing
// on Enter but not on losing focus, since a click elsewhere means "never
// mind" far more often than it means "yes, do it".
Rectangle {
    id: field

    property string start: ""
    property bool active: false
    property bool centred: false

    signal committed(string name)
    signal cancelled

    implicitHeight: 26
    height: implicitHeight
    radius: Appearance.rSm
    color: Appearance.ground
    border.width: 1
    border.color: Appearance.accent

    onActiveChanged: if (active) begin(); else release()
    // Closed — committed, cancelled, or the file it named gone — it lets go
    // of the keyboard. Hidden, it kept it: Escape put the field away but
    // left it holding the focus, and Ctrl+A went on selecting the text of
    // a name nobody could see instead of the files.
    onVisibleChanged: if (!visible) release()
    function release() { if (input.activeFocus) input.focus = false; }

    function begin() {
        input.text = field.start;
        input.forceActiveFocus();
        // Select the stem, not the extension. A dotfile has no stem to
        // speak of, so select all of it.
        const dot = field.start.lastIndexOf(".");
        if (dot > 0) input.select(0, dot);
        else input.selectAll();
    }

    Component.onCompleted: if (active) begin()

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 7
        anchors.rightMargin: 7
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: field.centred ? TextInput.AlignHCenter : TextInput.AlignLeft
        font.family: Appearance.fontFamily
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink
        selectionColor: Appearance.accent
        selectedTextColor: Appearance.inkOnAccent
        clip: true

        onAccepted: field.committed(text.trim())
        Keys.onEscapePressed: field.cancelled()
    }
}
