import QtQuick
import QtQuick.Window
import Hyprshell

// The window a "Save as…" or "Open…" puts up.
//
// The same browser as the main window — same sidebar, same list, same
// sorting and grouping — with a footer carrying the name and the two
// buttons. Reusing it is the point: a file dialog that looks nothing like
// the file manager is two things to learn instead of one.
Window {
    id: dlg

    required property string token
    required property string mode        // "open" | "save" | "savefiles"
    required property string startFolder
    required property string suggestedName
    required property bool multiple
    required property bool directory
    property var filters: []

    // Which of the caller's filters is in force; -1 is "All files".
    //
    // "All files" is offered whenever a caller named any. Its list is a
    // suggestion — it is written by an application that cannot see the
    // disk, and the file someone means is often spelled in a way it did
    // not think of. Being unable to reach a file that is right there is
    // the worse failure of the two.
    property int filterIndex: dlg.filters.length > 0 ? 0 : -1

    readonly property var activePatterns:
        dlg.filterIndex >= 0 && dlg.filterIndex < dlg.filters.length
        ? (dlg.filters[dlg.filterIndex].patterns || []) : []

    readonly property bool saving: dlg.mode === "save"
    readonly property bool pickingFolder: dlg.directory || dlg.mode === "savefiles"

    width: 880
    height: 580
    minimumWidth: 560
    minimumHeight: 380
    visible: true
    color: "transparent"
    title: dlg.saving ? "Save" : (dlg.pickingFolder ? "Choose folder" : "Open")

    // The host contract FilesFrame reads, same as Main.qml's.
    readonly property bool tiled: true
    readonly property bool maximised: dlg.visibility === Window.Maximized
    readonly property real normalWidth: dlg.width
    readonly property real normalHeight: dlg.height
    readonly property real workTop: 0
    readonly property real workBottom: dlg.height
    function moveTo(x, y) { dlg.startSystemMove(); }
    function toggleMaximised() {
        dlg.visibility = dlg.maximised ? Window.Windowed : Window.Maximized;
    }
    function minimise() { dlg.visibility = Window.Minimized; }
    function close() { dlg.cancel(); }

    signal chosen(string token, var paths)

    function accept() {
        const out = [];
        if (dlg.pickingFolder) {
            out.push(files.cwd);
        } else if (dlg.saving) {
            const n = nameField.text.trim();
            if (n === "") return;
            out.push(FilesService.join(files.cwd, n));
        } else {
            for (const n of files.selection) out.push(FilesService.join(files.cwd, n));
            if (out.length === 0) return;
        }
        dlg.chosen(dlg.token, out);
        dlg.destroy();
    }

    function cancel() {
        dlg.chosen(dlg.token, []);
        dlg.destroy();
    }

    Files {
        id: files
        Component.onCompleted: {
            files.go(dlg.startFolder && dlg.startFolder !== ""
                     ? dlg.startFolder : FilesService.home);
        }
        dialogMode: true
        kindFilter: dlg.activePatterns
    }

    // Double-clicking a file in an Open dialog is the commonest way anyone
    // finishes one, and a dialog that launched it instead would be a trap.
    Connections {
        target: files
        function onActivateRequested(entry) {
            if (entry.dir) { files.go(FilesService.join(files.cwd, entry.name)); return; }
            if (dlg.saving) { nameField.text = entry.name; return; }
            dlg.accept();
        }
    }

    FilesFrame {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: bar.top
        host: dlg
        app: files
    }

    // ── the footer ───────────────────────────────────────────────────────
    Rectangle {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 58 + (kinds.visible ? 36 : 0)
        color: Appearance.surface

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Appearance.rule
        }

        // What the caller said it will take, one chip each, plus the way
        // out. Only when there is something to choose between.
        Item {
            id: kinds
            visible: dlg.filters.length > 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 36

            Flickable {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                clip: true
                contentWidth: chips.width
                flickableDirection: Flickable.HorizontalFlick
                interactive: contentWidth > width

                Row {
                    id: chips
                    height: parent.height
                    spacing: 6

                    Repeater {
                        // The caller's filters, then "All files" last.
                        model: dlg.filters.length + 1

                        Rectangle {
                            required property int index
                            readonly property bool isAll: index === dlg.filters.length
                            readonly property bool on: isAll ? dlg.filterIndex < 0
                                                             : dlg.filterIndex === index
                            anchors.verticalCenter: parent.verticalCenter
                            width: label.implicitWidth + 20
                            height: 24
                            radius: height / 2
                            color: on ? Appearance.accent
                                      : (hover.containsMouse ? Appearance.hover
                                                             : "transparent")
                            border.width: on ? 0 : 1
                            border.color: Appearance.rule

                            StyledText {
                                id: label
                                anchors.centerIn: parent
                                text: parent.isAll ? "All files"
                                                   : (dlg.filters[parent.index].name
                                                      || "Files")
                                font.pixelSize: Appearance.fs(11.5)
                                color: parent.on ? Appearance.inkOnAccent
                                                 : Appearance.ink2
                            }

                            MouseArea {
                                id: hover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dlg.filterIndex = parent.isAll ? -1 : parent.index
                            }
                        }
                    }
                }
            }
        }

        // Everything else sits in the bottom 58, whether or not the chips
        // are above it.
        Item {
            id: mainRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 58

            StyledText {
                id: nameLabel
                visible: dlg.saving
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "Name"
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }

            Rectangle {
                visible: dlg.saving
                anchors.left: nameLabel.right
                anchors.leftMargin: 10
                anchors.right: buttons.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                height: 30
                radius: Appearance.rSm
                color: Appearance.hover
                border.width: 1
                border.color: nameField.activeFocus ? Appearance.accent : Appearance.rule

                TextInput {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    text: dlg.suggestedName
                    color: Appearance.ink
                    font.family: Appearance.fontFamily
                    font.pixelSize: Appearance.fs(12.5)
                    selectByMouse: true
                    selectionColor: Appearance.accent
                    selectedTextColor: Appearance.inkOnAccent
                    onAccepted: dlg.accept()
                    Component.onCompleted: {
                        forceActiveFocus();
                        // The stem, not the suffix: changing "report" to
                        // "invoice" is the common edit, and ".pdf" is not.
                        const dot = text.lastIndexOf(".");
                        if (dot > 0) select(0, dot); else selectAll();
                    }
                }
            }

            // What is going to be chosen, when there is no name to type.
            StyledText {
                visible: !dlg.saving
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.right: buttons.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideMiddle
                text: dlg.pickingFolder
                      ? FilesService.pretty(files.cwd)
                      : (files.selection.length === 0
                         ? "Nothing selected"
                         : (files.selection.length === 1 ? files.selection[0]
                            : files.selection.length + " items"))
                font.pixelSize: Appearance.fs(12.5)
                color: files.selection.length === 0 && !dlg.pickingFolder
                       ? Appearance.ink3 : Appearance.ink
            }

            Row {
                id: buttons
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                DialogButton {
                    text: "Cancel"
                    onTriggered: dlg.cancel()
                }
                DialogButton {
                    text: dlg.saving ? "Save" : (dlg.pickingFolder ? "Choose" : "Open")
                    primary: true
                    enabled: dlg.saving ? nameField.text.trim() !== ""
                           : (dlg.pickingFolder || files.selection.length > 0)
                    onTriggered: dlg.accept()
                }
            }
        }
    }

    // Escape cancels, wherever the focus is.
    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: dlg.cancel()
    }
}
