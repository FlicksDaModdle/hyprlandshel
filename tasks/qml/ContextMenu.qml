import QtQuick
import Hyprshell

// A right-click menu, anywhere in the window: `openAt(x, y, entries)` with
// entries as [{ n, icon, run, sub: [...], rule, active, checked, danger }].
// Sits on a full-window layer (`parent` is the frame's overlay) with a
// catcher under it, and cascades submenus beside itself.
Item {
    id: menu

    property bool open: false
    property var entries: []
    property var subs: []
    property real atX: 0
    property real atY: 0
    readonly property real menuWidth: 236

    anchors.fill: parent
    visible: open
    z: 3000

    function openAt(x, y, list) {
        menu.subs = [];
        menu.entries = list;
        menu.atX = x;
        menu.atY = y;
        menu.open = true;
    }
    function close() { menu.open = false; menu.subs = []; }
    function rowHeight(e) { return e.rule === true ? 37 : 32; }
    function heightOf(list) { return list.reduce((a, e) => a + rowHeight(e), 0) + 12; }
    function isOpenSub(e) {
        const k = e.lvl || 0;
        return !!e.sub && menu.subs.length > k && menu.subs[k].from === e.n;
    }
    function hoverAt(e, item) {
        const k = e.lvl || 0;
        if (!e.sub) { if (menu.subs.length > k) menu.subs = menu.subs.slice(0, k); return; }
        if (menu.isOpenSub(e)) return;
        const p = item.mapToItem(menu, 0, 0);
        const entries = e.sub.map(x => Object.assign({}, x, { lvl: k + 1 }));
        const h = menu.heightOf(entries);
        let x = p.x + item.width + 4;
        if (x + menu.menuWidth > menu.width - 6) x = p.x - menu.menuWidth - 4;
        const y = Math.max(6, Math.min(p.y - 6, menu.height - h - 6));
        menu.subs = menu.subs.slice(0, k).concat([{ from: e.n, entries: entries, x: x, y: y }]);
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
        onWheel: wheel => { wheel.accepted = true; menu.close(); }
    }

    Component {
        id: rowComp
        Item {
            id: item
            required property var modelData
            readonly property bool active: item.modelData.active !== false
            readonly property bool lit: active && (rowHover.hovered || menu.isOpenSub(item.modelData))
            width: parent ? parent.width : 0
            height: menu.rowHeight(item.modelData)
            Rectangle {
                visible: item.modelData.rule === true
                anchors.top: parent.top
                anchors.topMargin: 2
                width: parent.width
                height: 1
                color: Appearance.rule
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 32
                radius: Appearance.rSm
                opacity: item.active ? 1 : 0.4
                color: item.lit ? (item.modelData.danger ? Appearance.accent : Appearance.accent) : "transparent"
                MonoIcon {
                    id: glyph
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: item.modelData.checked === true ? "check" : (item.modelData.icon || "")
                    visible: name !== ""
                    size: 16
                    inkColor: item.lit ? Appearance.inkOnAccent : Appearance.ink
                    accentColor: item.lit ? Appearance.inkOnAccent : Appearance.accent
                }
                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 36
                    anchors.right: parent.right
                    anchors.rightMargin: 26
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: item.modelData.n
                    font.pixelSize: Appearance.fs(12)
                    color: item.lit ? Appearance.inkOnAccent : Appearance.ink
                }
                MonoIcon {
                    visible: !!item.modelData.sub
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevronRight"
                    size: 13
                    inkColor: item.lit ? Appearance.inkOnAccent : Appearance.ink2
                    accentColor: inkColor
                }
                HoverHandler {
                    id: rowHover
                    cursorShape: item.active ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onHoveredChanged: if (hovered) menu.hoverAt(item.modelData, item)
                }
                TapHandler {
                    onTapped: {
                        if (!item.active) return;
                        if (item.modelData.sub) { menu.hoverAt(item.modelData, item); return; }
                        const run = item.modelData.run;
                        menu.close();
                        if (run) run();
                    }
                }
            }
        }
    }

    PanelSurface {
        id: mainPanel
        showSeam: false
        color: Appearance.dialog
        width: menu.menuWidth
        height: mainCol.implicitHeight + 12
        x: Math.max(6, Math.min(menu.atX, menu.width - width - 6))
        y: Math.max(6, Math.min(menu.atY, menu.height - height - 6))
        Column {
            id: mainCol
            x: 6; y: 6
            width: parent.width - 12
            Repeater { model: menu.entries; delegate: rowComp }
        }
    }
    Repeater {
        model: menu.subs
        PanelSurface {
            id: subPanel
            required property var modelData
            showSeam: false
            color: Appearance.dialog
            width: menu.menuWidth
            height: subCol.implicitHeight + 12
            x: subPanel.modelData.x
            y: subPanel.modelData.y
            Column {
                id: subCol
                x: 6; y: 6
                width: parent.width - 12
                Repeater { model: subPanel.modelData.entries; delegate: rowComp }
            }
        }
    }
}
