import QtQuick
import Hyprshell

// A sortable list of rows, for every view that is a table: services,
// startup apps, connections, packages, drivers.
//
//   columns  [{ k, t, w, num, fmt: row => text, sort: row => value,
//               glyph: row => icon name, dim: row => bool, alert: row => bool }]
//            a column without `w` takes what is left.
//   rows     plain objects; `keyField` names the one that identifies a row.
Item {
    id: table

    property var columns: []
    property var rows: []
    property string keyField: "id"
    property string sortKey: ""
    property bool sortDesc: false
    property string selectedKey: ""
    property string emptyText: "Nothing to show"
    property bool loading: false
    readonly property var selected: table.sorted.find(r => String(r[table.keyField]) === table.selectedKey) || null

    signal activated(var row)
    signal contextMenu(var row, real x, real y)

    readonly property real fixed: columns.reduce((a, c) => a + (c.w || 0), 0)
    readonly property real flexW: Math.max(140, (list.width - fixed) / Math.max(1, columns.filter(c => !c.w).length))

    readonly property var sorted: {
        const c = table.columns.find(x => x.k === table.sortKey);
        const out = table.rows.slice();
        if (!c) return out;
        const val = c.sort ? c.sort : (c.fmt && !c.num ? c.fmt : (r => r[c.k]));
        out.sort((a, b) => {
            const x = val(a), y = val(b);
            let r = typeof x === "string" || typeof y === "string"
                ? String(x || "").localeCompare(String(y || ""), undefined, { sensitivity: "base" })
                : (x > y) - (x < y);
            return table.sortDesc ? -r : r;
        });
        return out;
    }

    Rectangle {
        id: header
        width: parent.width
        height: 34
        color: "transparent"
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
        Row {
            height: parent.height
            Repeater {
                model: table.columns
                Item {
                    id: hc
                    required property var modelData
                    required property int index
                    readonly property bool on: table.sortKey === modelData.k
                    width: modelData.w || table.flexW
                    height: header.height
                    Rectangle { anchors.fill: parent; color: hArea.containsMouse ? Appearance.hover : "transparent" }
                    StyledText {
                        anchors.fill: parent
                        anchors.leftMargin: hc.index === 0 ? 20 : 8
                        anchors.rightMargin: 10
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: hc.modelData.num ? Text.AlignRight : Text.AlignLeft
                        elide: Text.ElideRight
                        text: hc.modelData.t + (hc.on ? (table.sortDesc ? "  ▾" : "  ▴") : "")
                        font.pixelSize: Appearance.fs(11)
                        font.weight: hc.on ? Font.DemiBold : Font.Medium
                        color: hc.on ? Appearance.accent : Appearance.ink3
                    }
                    Rectangle { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: 1; height: parent.height - 14; color: Appearance.rule }
                    MouseArea {
                        id: hArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (table.sortKey === hc.modelData.k) table.sortDesc = !table.sortDesc;
                            else { table.sortKey = hc.modelData.k; table.sortDesc = !!hc.modelData.num; }
                        }
                    }
                }
            }
        }
    }

    SmoothScroll { target: list; anchors.fill: list; z: 5 }
    ScrollBar { target: list; anchors.top: list.top; anchors.bottom: list.bottom; anchors.right: list.right; z: 6 }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: table.sorted
        reuseItems: true
        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property string key: String(modelData[table.keyField])
            readonly property bool chosen: table.selectedKey === key
            width: list.width
            height: 30
            color: chosen ? Appearance.sel : area.containsMouse ? Appearance.hover : "transparent"
            Row {
                height: parent.height
                Repeater {
                    model: table.columns
                    Item {
                        id: cell
                        required property var modelData
                        required property int index
                        width: modelData.w || table.flexW
                        height: row.height
                        readonly property string glyphName: cell.modelData.glyph ? cell.modelData.glyph(row.modelData) : ""
                        MonoIcon {
                            id: g
                            visible: cell.glyphName !== ""
                            x: cell.index === 0 ? 18 : 8
                            anchors.verticalCenter: parent.verticalCenter
                            name: cell.glyphName
                            size: 15
                            inkColor: Appearance.ink2
                            accentColor: Appearance.accent
                        }
                        StyledText {
                            anchors.fill: parent
                            anchors.leftMargin: (cell.index === 0 ? 20 : 8) + (g.visible ? 24 : 0)
                            anchors.rightMargin: 10
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: cell.modelData.num ? Text.AlignRight : Text.AlignLeft
                            elide: Text.ElideRight
                            text: {
                                const v = cell.modelData.fmt ? cell.modelData.fmt(row.modelData) : row.modelData[cell.modelData.k];
                                return v === undefined || v === null ? "" : String(v);
                            }
                            font.pixelSize: Appearance.fs(12)
                            color: cell.modelData.alert && cell.modelData.alert(row.modelData) ? Appearance.accent
                                 : cell.modelData.dim && cell.modelData.dim(row.modelData) ? Appearance.ink3 : Appearance.ink
                        }
                    }
                }
            }
            MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                    table.selectedKey = row.key;
                    if (mouse.button === Qt.RightButton) {
                        const p = area.mapToItem(null, mouse.x, mouse.y);
                        table.contextMenu(row.modelData, p.x, p.y);
                    }
                }
                onDoubleClicked: table.activated(row.modelData)
            }
        }
        StyledText {
            anchors.centerIn: parent
            visible: list.count === 0
            text: table.loading ? "Reading…" : table.emptyText
            font.pixelSize: Appearance.fs(13)
            color: Appearance.ink3
        }
    }
}
