import QtQuick
import QtQuick.Shapes
import Quickshell
import "../modules/icons"
import "../modules/icons/IconPaths.js" as IconData

// Every glyph in the pack, drawn on your hardware, with its name under it.
//
// Run it when an icon is missing somewhere in the shell:
//
//     qs -p ~/.config/quickshell/hyprshell/tools/iconsheet.qml
//
// Each glyph is drawn twice — left with Qt's default Shape renderer, right
// with the analytic one — because the difference between them is a driver
// matter and cannot be reproduced anywhere but on the machine that shows
// it. A name whose left square is filled and whose right one is empty is a
// glyph the curve renderer drops on this GPU; turn "Sharper icon edges"
// off in Settings → Appearance and report the names.
FloatingWindow {
    id: sheet
    title: "Hyprshell icon sheet"
    implicitWidth: 1000
    implicitHeight: 720
    color: "#1b1918"

    readonly property var names: {
        const seen = [], out = [];
        for (const k in IconData.icons) {
            if (seen.indexOf(IconData.icons[k]) >= 0) continue;
            seen.push(IconData.icons[k]);
            out.push(k);
        }
        return out.sort();
    }

    Text {
        id: caption
        x: 16; y: 12
        width: parent.width - 32
        wrapMode: Text.Wrap
        color: "#8d8a89"
        font.pixelSize: 12
        font.family: "Inter"
        text: sheet.names.length + " glyphs. Left of each pair is Qt's default "
              + "renderer, right is the analytic one. An empty right-hand "
              + "square is a glyph your driver drops."
    }

    Flickable {
        anchors.fill: parent
        anchors.topMargin: caption.height + 22
        contentHeight: grid.height + 24
        clip: true

        Grid {
            id: grid
            x: 12
            width: parent.width - 24
            columns: Math.max(1, Math.floor(width / 104))

            Repeater {
                model: sheet.names

                Item {
                    id: cell
                    required property var modelData
                    width: 104
                    height: 76

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 8
                        spacing: 6

                        Repeater {
                            model: [Shape.GeometryRenderer, Shape.CurveRenderer]

                            Rectangle {
                                id: plate
                                required property var modelData
                                width: 38; height: 38; radius: 9
                                color: "#2a2726"
                                border.width: 1; border.color: "#3a3635"

                                Sample {
                                    anchors.centerIn: parent
                                    name: cell.modelData
                                    size: 22
                                    renderer: plate.modelData
                                }
                            }
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 8
                        width: parent.width - 6
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: cell.modelData
                        color: "#8d8a89"
                        font.pixelSize: 10
                        font.family: "Inter"
                    }
                }
            }
        }
    }
}
