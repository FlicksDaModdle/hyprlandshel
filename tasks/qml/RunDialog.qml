import QtQuick
import Hyprshell
import Hyprshell.Backend

// Run new task: a command, started detached through the shell.
Modal {
    id: dlg
    title: "Run new task"
    boxWidth: 460
    onOpenChanged: if (open) { cmd.text = ""; focusTimer.restart(); }
    Timer { id: focusTimer; interval: 30; onTriggered: cmd.forceActiveFocus() }
    function run() {
        if (cmd.text.trim() === "") return;
        Tools.runDetached(["sh", "-c", cmd.text]);
        dlg.open = false;
    }
    Column {
        width: parent.width
        spacing: 12
        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Type the name of a program or a command line."
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink2
        }
        Rectangle {
            width: parent.width
            height: 34
            radius: Appearance.rSm
            color: Appearance.ground
            border.width: cmd.activeFocus ? 2 : 1
            border.color: cmd.activeFocus ? Appearance.accent : Appearance.rule
            TextInput {
                id: cmd
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: Text.AlignVCenter
                clip: true
                color: Appearance.ink
                selectionColor: Appearance.accent
                font.family: "monospace"
                font.pixelSize: Appearance.fs(12.5)
                Keys.onReturnPressed: e => { e.accepted = true; dlg.run(); }
                Keys.onEnterPressed: e => { e.accepted = true; dlg.run(); }
                Keys.onEscapePressed: e => { e.accepted = true; dlg.open = false; }
            }
        }
        Row {
            spacing: 8
            DialogButton { text: "Run"; primary: true; onTriggered: dlg.run() }
            DialogButton { text: "Cancel"; onTriggered: dlg.open = false }
        }
    }
}
