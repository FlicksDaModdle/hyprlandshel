import QtQuick
import Hyprshell

// What a file actually is: the panel behind Properties, and behind
// Ctrl+I.
//
// A sheet inside the window rather than a second toplevel, because the
// compositor would tile a second window beside this one and a five-row
// fact sheet does not deserve half the screen.
PanelSurface {
    id: props

    required property var app
    readonly property var svc: FilesService
    readonly property var entry: props.app.propertiesFor

    showSeam: false
    visible: props.entry !== null
    z: 950
    implicitWidth: 340
    implicitHeight: column.implicitHeight + 24

    readonly property var facts: {
        const e = props.entry;
        if (!e) return [];
        const d = props.svc.details || ({});
        const out = [];

        out.push({ k: "Type", v: props.svc.typeLabel(e) });

        // A folder's size is the walk `du` did, and it is worth saying that
        // the number covers everything inside rather than the directory
        // entry itself, which is what `ls` would tell you.
        if (e.dir) {
            out.push({ k: "Size",
                       v: props.svc.inspecting ? "counting…"
                          : (d.bytes ? props.svc.humanSize(d.bytes) + " in total" : "—") });
            out.push({ k: "Contents",
                       v: props.svc.inspecting ? "…"
                          : (d.items === 1 ? "1 item" : (d.items || 0) + " items") });
        } else {
            out.push({ k: "Size", v: props.svc.humanSize(e.size)
                                     + (e.size >= 1000
                                        ? "  (" + e.size.toLocaleString(Qt.locale(), "f", 0)
                                          + " bytes)" : "") });
        }

        out.push({ k: "Location", v: props.svc.pretty(props.app.cwd) });
        out.push({ k: "Modified", v: props.fullTime(e.mtime) });
        if (d.perms) out.push({ k: "Permissions", v: d.perms });
        if (d.owner) out.push({ k: "Owner", v: d.owner });
        if (e.link) out.push({ k: "Links to", v: d.target || "—" });
        return out;
    }

    function fullTime(epoch) {
        if (!epoch) return "—";
        return Qt.formatDateTime(new Date(epoch * 1000), "d MMMM yyyy, HH:mm");
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 14
        spacing: 0

        // The thing itself: its glyph and its name.
        Row {
            width: parent.width
            spacing: 11
            bottomPadding: 12

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 42
                height: 38
                radius: Appearance.rSm
                color: Appearance.surface

                MonoIcon {
                    anchors.centerIn: parent
                    name: props.entry ? props.svc.iconFor(props.entry) : "file"
                    size: 28
                    inkColor: Appearance.ink2
                    accentColor: Appearance.accent
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 53
                text: props.entry ? props.entry.name : ""
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
                maximumLineCount: 2
                wrapMode: Text.Wrap
            }
        }

        Rectangle { width: parent.width; height: 1; color: Appearance.rule }

        Repeater {
            model: props.facts

            Item {
                required property var modelData
                width: column.width
                height: 30

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 96
                    text: modelData.k
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink3
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 100
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.v
                    font.pixelSize: Appearance.fs(12)
                    elide: Text.ElideMiddle
                    // A permissions string and a byte count both read as
                    // data rather than prose, so they get the same
                    // tabular figures the rest of the shell uses.
                    horizontalAlignment: Text.AlignLeft
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Appearance.rule }

        Item {
            width: parent.width
            height: 44

            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 74
                height: 32
                radius: Appearance.rSm
                color: closeArea.containsMouse ? Appearance.accent : Appearance.surface

                StyledText {
                    anchors.centerIn: parent
                    text: "Close"
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.DemiBold
                    color: closeArea.containsMouse ? Appearance.onAccent : Appearance.ink
                }

                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: props.app.propertiesFor = null
                }
            }
        }
    }
}
