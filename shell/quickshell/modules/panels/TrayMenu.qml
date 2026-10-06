import QtQuick
import Quickshell
import Quickshell.Widgets
import "../../config" as Config
import "../common"
import "../icons"

// A tray icon's menu, drawn by the shell instead of handed to the app's
// toolkit — so Discord's, Steam's, nm-applet's and every other menu reads
// like the shell's own: the same surface, rows, hover and type as the
// desktop menu. The entries are the app's own (DBusMenu, through
// Quickshell's QsMenuOpener); only the drawing is ours.
//
// Submenus open beside their row on hover, and flip to the other side at
// the screen's edge. Checkboxes and radio items show their state; disabled
// entries are greyed and do nothing. Keyboard: arrows, Enter, Escape.
//
// Fills the panel layer; each open level is a panel inside it, so a
// submenu is not clipped by the menu it came from.
Item {
    id: root

    required property real screenWidth
    required property real screenHeight
    // Where the first level hangs: under the icon, below the bar.
    required property real anchorX
    required property real topY

    readonly property var item: Config.UiState.trayMenuItem
    readonly property bool open: Config.UiState.trayMenuOpen && !!item && !!item.menu

    // The open levels, outermost first: { handle, x, y, from } — `from` is
    // the row index in the level before that opened it.
    property var levels: []
    // Keyboard position: which level, which row.
    property int focusLevel: 0
    property int focusRow: -1

    function close() { Config.UiState.trayMenuOpen = false; }

    function reset() {
        if (!open) { levels = []; return; }
        levels = [{ handle: item.menu, x: -1, y: topY, from: -1 }];
        focusLevel = 0;
        focusRow = -1;
        keys.forceActiveFocus();
    }
    onOpenChanged: reset()
    onItemChanged: if (open) reset()

    // Open (or switch to) the submenu of `entry`, a row of level `li`.
    function openSub(li, rowIndex, entry, rowItem, levelItem) {
        const cur = levels[li + 1];
        if (cur && cur.handle === entry) return;
        const kept = levels.slice(0, li + 1);
        const p = rowItem.mapToItem(root, 0, 0);
        kept.push({ handle: entry, x: -1, y: p.y - 6, from: rowIndex,
                    parentX: levelItem.x, parentW: levelItem.width });
        levels = kept;
    }
    function closeAfter(li) {
        if (levels.length > li + 1) levels = levels.slice(0, li + 1);
    }

    // DBusMenu marks access keys with "_" ("_Open", "Save _As"); "__" is a
    // real underscore.
    function label(t) {
        return (t || "").replace(/__/g, "\u0001").replace(/_/g, "").replace(/\u0001/g, "_");
    }

    // The panel layer takes the keyboard only while something asks.
    Binding {
        target: Config.UiState
        property: "panelWantsKeyboard"
        value: true
        when: root.open
    }

    Item {
        id: keys
        focus: root.open
        Keys.onEscapePressed: root.close()
        Keys.onPressed: event => {
            const lv = levelRepeater.itemAt(root.focusLevel);
            if (!lv) return;
            const n = lv.count;
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                const step = event.key === Qt.Key_Down ? 1 : -1;
                let i = root.focusRow;
                for (let k = 0; k < n; k++) {
                    i = (i + step + n) % n;
                    if (lv.selectable(i)) break;
                }
                root.focusRow = i;
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                if (lv.hasSub(root.focusRow)) {
                    lv.openRow(root.focusRow);
                    root.focusLevel++;
                    root.focusRow = -1;
                }
                event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                if (root.focusLevel > 0) {
                    root.focusRow = root.levels[root.focusLevel].from;
                    root.closeAfter(root.focusLevel - 1);
                    root.focusLevel--;
                }
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                if (root.focusRow >= 0) {
                    if (lv.hasSub(root.focusRow)) {
                        lv.openRow(root.focusRow);
                        root.focusLevel++;
                        root.focusRow = -1;
                    } else lv.activateRow(root.focusRow);
                }
                event.accepted = true;
            }
        }
    }

    Repeater {
        id: levelRepeater
        model: root.open ? root.levels : []

        PanelSurface {
            id: level
            required property var modelData
            required property int index
            readonly property int li: index

            showSeam: false

            QsMenuOpener { id: opener; menu: level.modelData.handle }
            readonly property var entries: opener.children ? opener.children.values : []
            readonly property int count: entries.length

            // As wide as its longest entry, within reason. Measured with
            // this level's own metrics, and not as a binding: a binding
            // that sets the text it then reads re-runs for every level
            // whenever any of them measures.
            TextMetrics { id: measure; font.family: Config.Appearance.fontFamily; font.pixelSize: Config.Appearance.fs(12) }
            property real textWidth: 0
            function remeasure() {
                let w = 0;
                for (const e of entries) {
                    if (!e || e.isSeparator) continue;
                    measure.text = root.label(e.text);
                    w = Math.max(w, measure.advanceWidth);
                }
                textWidth = w;
            }
            onEntriesChanged: remeasure()
            Component.onCompleted: remeasure()
            readonly property bool anyIcon: entries.some(e => e && !e.isSeparator && (e.icon !== "" || e.buttonType !== 0))
            width: Math.round(Math.max(190, Math.min(380, textWidth + (anyIcon ? 36 : 12) + 22 + 30)))
            implicitHeight: col.implicitHeight + 12

            // The first level under its icon; a submenu beside its row, or
            // on the other side when that would leave the screen.
            x: {
                if (modelData.x >= 0) return modelData.x;
                if (li === 0)
                    return Math.max(8, Math.min(root.anchorX - width / 2, root.screenWidth - width - 8));
                const right = modelData.parentX + modelData.parentW - 4;
                const left = modelData.parentX - width + 4;
                if (right + width <= root.screenWidth - 8) return right;
                if (left >= 8) return left;
                // Room on neither side (a narrow screen): the roomier one,
                // kept on screen.
                return root.screenWidth - right >= modelData.parentX
                    ? Math.max(8, root.screenWidth - width - 8) : 8;
            }
            y: Math.max(8, Math.min(modelData.y, root.screenHeight - height - 8))

            function selectable(i) {
                const e = entries[i];
                return !!e && !e.isSeparator && e.enabled;
            }
            function hasSub(i) {
                const e = entries[i];
                return !!e && !e.isSeparator && e.enabled && e.hasChildren;
            }
            function openRow(i) {
                const r = rows.itemAt(i);
                if (r) root.openSub(li, i, entries[i], r, level);
            }
            function activateRow(i) {
                const e = entries[i];
                if (!e || e.isSeparator || !e.enabled) return;
                if (e.hasChildren) { openRow(i); return; }
                e.triggered();
                root.close();
            }

            Column {
                id: col
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6

                Repeater {
                    id: rows
                    model: level.entries

                    Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property var e: modelData
                        readonly property bool sep: !!e && e.isSeparator
                        readonly property bool on: !!e && e.enabled
                        readonly property bool lit: !sep && on
                            && (rowHover.hovered || (root.focusLevel === level.li && root.focusRow === index)
                                || (!!root.levels[level.li + 1] && root.levels[level.li + 1].from === index))
                        readonly property bool check: !!e && e.buttonType === 1
                        readonly property bool radio: !!e && e.buttonType === 2
                        readonly property bool checked: !!e && e.checkState === Qt.Checked

                        width: col.width
                        height: sep ? 9 : 34

                        Rectangle {
                            visible: row.sep
                            anchors.verticalCenter: parent.verticalCenter
                            x: 8
                            width: parent.width - 16
                            height: 1
                            color: Config.Appearance.rule
                        }

                        Rectangle {
                            visible: !row.sep
                            anchors.fill: parent
                            radius: Config.Appearance.rPill
                            color: row.lit ? Config.Appearance.accent : "transparent"
                            Behavior on color { ColorAnimation { duration: Config.Appearance.anim(90) } }
                        }

                        // The glyph column: the app's icon, or a check box
                        // or radio dot.
                        Item {
                            id: lead
                            visible: !row.sep && level.anyIcon
                            x: 10
                            width: 16
                            height: 16
                            anchors.verticalCenter: parent.verticalCenter

                            IconImage {
                                anchors.fill: parent
                                visible: !row.check && !row.radio && !!row.e && row.e.icon !== ""
                                source: row.e && !row.check && !row.radio ? row.e.icon : ""
                                opacity: row.on ? 1 : 0.4
                            }
                            Rectangle {
                                visible: row.check
                                anchors.centerIn: parent
                                width: 14
                                height: 14
                                radius: 4
                                color: row.checked ? (row.lit ? Config.Appearance.inkOnAccent : Config.Appearance.accent) : "transparent"
                                border.width: row.checked ? 0 : 1.5
                                border.color: row.lit ? Config.Appearance.inkOnAccent : Config.Appearance.ink3
                                opacity: row.on ? 1 : 0.4
                                MonoIcon {
                                    anchors.centerIn: parent
                                    visible: row.checked
                                    name: "check"
                                    size: 11
                                    inkColor: row.lit ? Config.Appearance.accent : Config.Appearance.inkOnAccent
                                    monochrome: true
                                }
                            }
                            Rectangle {
                                visible: row.radio
                                anchors.centerIn: parent
                                width: 14
                                height: 14
                                radius: 7
                                color: "transparent"
                                border.width: 1.5
                                border.color: row.lit ? Config.Appearance.inkOnAccent
                                            : (row.checked ? Config.Appearance.accent : Config.Appearance.ink3)
                                opacity: row.on ? 1 : 0.4
                                Rectangle {
                                    visible: row.checked
                                    anchors.centerIn: parent
                                    width: 6
                                    height: 6
                                    radius: 3
                                    color: row.lit ? Config.Appearance.inkOnAccent : Config.Appearance.accent
                                }
                            }
                        }

                        StyledText {
                            visible: !row.sep
                            anchors.left: parent.left
                            anchors.leftMargin: level.anyIcon ? 36 : 12
                            anchors.right: chevron.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.e ? root.label(row.e.text) : ""
                            elide: Text.ElideRight
                            font.pixelSize: Config.Appearance.fs(12)
                            color: row.lit ? Config.Appearance.inkOnAccent
                                 : (row.on ? Config.Appearance.ink : Config.Appearance.ink3)
                        }

                        MonoIcon {
                            id: chevron
                            visible: !row.sep && !!row.e && row.e.hasChildren
                            anchors.right: parent.right
                            anchors.rightMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevronRight"
                            size: 12
                            inkColor: row.lit ? Config.Appearance.inkOnAccent : Config.Appearance.ink3
                            monochrome: true
                        }

                        HoverHandler {
                            id: rowHover
                            enabled: !row.sep
                            cursorShape: row.on ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onHoveredChanged: {
                                if (!hovered) return;
                                root.focusLevel = level.li;
                                root.focusRow = row.index;
                                hoverOpen.restart();
                            }
                        }
                        // A moment's pause before a submenu opens or the
                        // open one closes, so a diagonal move toward it
                        // across other rows does not lose it.
                        Timer {
                            id: hoverOpen
                            interval: 140
                            onTriggered: {
                                if (!rowHover.hovered) return;
                                if (level.hasSub(row.index)) level.openRow(row.index);
                                else root.closeAfter(level.li);
                            }
                        }
                        // A MouseArea, not a TapHandler: the panel layer's
                        // click-away catcher takes the grab at press and
                        // would cancel a tap.
                        MouseArea {
                            anchors.fill: parent
                            enabled: !row.sep
                            onClicked: level.activateRow(row.index)
                        }
                    }
                }
            }
        }
    }

    // The app went away, or its menu did, while open.
    Connections {
        target: root.item
        ignoreUnknownSignals: true
        function onDestroyed() { root.close(); }
    }
}
