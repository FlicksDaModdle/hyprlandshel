import QtQuick
import "../../config" as Config
import "../icons"

// The rows of a right-click menu: the dock's, and the launcher's for apps
// and files. Entries are { n, icon, run, rule?, keepOpen?, danger? };
// tapping one runs it and says whether the menu should close.
Column {
    id: root

    property var entries: []
    signal done(bool keepOpen)

    // For something that can't simply be undone (Move to Trash): the
    // same red the rest of the desktop uses for it.
    readonly property color danger: Config.Appearance.dark ? "#ff6b61" : "#d42c1f"

    spacing: 0

    Repeater {
        model: root.entries

        Item {
            id: item
            required property var modelData
            width: root.width
            height: modelData.rule === true ? 41 : 36

            Rectangle {
                visible: item.modelData.rule === true
                anchors.top: parent.top
                anchors.topMargin: 2
                width: parent.width
                height: 1
                color: Config.Appearance.rule
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 36
                radius: Config.Appearance.rPill
                color: rowHover.hovered
                       ? (item.modelData.danger === true ? root.danger : Config.Appearance.accent)
                       : "transparent"

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 11
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: item.modelData.icon || "dot"
                        size: 14
                        inkColor: rowHover.hovered ? Config.Appearance.inkOnAccent
                                  : (item.modelData.danger === true ? root.danger : Config.Appearance.ink)
                        accentColor: rowHover.hovered ? Config.Appearance.inkOnAccent : Config.Appearance.accent
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: item.modelData.n
                        font.pixelSize: Config.Appearance.fs(12)
                        color: rowHover.hovered ? Config.Appearance.inkOnAccent
                               : (item.modelData.danger === true ? root.danger : Config.Appearance.ink)
                    }
                }

                HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        const run = item.modelData.run;
                        const keepOpen = item.modelData.keepOpen === true;
                        if (run) run();
                        root.done(keepOpen);
                    }
                }
            }
        }
    }
}
