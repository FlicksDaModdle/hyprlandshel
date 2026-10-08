import QtQuick
import "../../config" as Config
import "../common"
import "../icons"
import "../icons/IconPaths.js" as IconData

// Every glyph the shell has, to put one on a dock tile.
//
// Both packs at once: the built-in set and anything in icons.json, drawn
// with the same MonoIcon the dock uses, so what you pick is exactly what
// you get — at the accent you are running, not a preview of it.
PanelSurface {
    id: root

    readonly property string key: Config.UiState.iconPickerFor
    readonly property var entry: root.key !== ""
        ? Config.Apps.pinned.find(e => e.key === root.key) : null
    readonly property string current: root.entry ? root.entry.icon : ""

    property string query: ""

    // Built-in first, in the order the pack is written — which groups
    // related glyphs, where the alphabet scatters them — then yours, in
    // the order you made them. Something you drew a minute ago is at the
    // end of the list, which is where you will look for it.
    readonly property var allNames: {
        const mine = Config.UserIcons.names;
        const builtin = IconData.names();
        // A name in both is the pack's; MonoIcon resolves it that way too,
        // so offering it twice would be offering the same drawing twice.
        return builtin.concat(mine.filter(n => !IconData.has(n)));
    }

    readonly property var shown: {
        const q = root.query.trim().toLowerCase();
        if (q === "") return root.allNames;
        return root.allNames.filter(n => n.toLowerCase().indexOf(q) >= 0);
    }

    readonly property int columns: 8
    readonly property real cell: 46

    function choose(name) {
        Config.Apps.setIcon(root.key, name);
        Config.UiState.iconPickerFor = "";
    }

    function close() { Config.UiState.iconPickerFor = ""; }

    // The panel layer holds the keyboard only while something on it can
    // be typed into, so the search field has to ask — otherwise it draws
    // a cursor that never receives a key.
    onVisibleChanged: {
        Config.UiState.panelWantsKeyboard = visible;
        if (visible) {
            root.query = "";
            search.text = "";
            search.forceActiveFocus();
        }
    }

    implicitWidth: root.columns * root.cell + 28
    implicitHeight: header.height + grid.height + 30

    Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 14
        spacing: 10
        height: implicitHeight

        Row {
            width: parent.width
            spacing: 8

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.entry ? "Icon for " + root.entry.label : "Icon"
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink
            }
        }

        Rectangle {
            width: parent.width
            height: 32
            radius: Config.Appearance.rPill
            color: Config.Appearance.sel
            border.width: 1
            border.color: search.activeFocus ? Config.Appearance.accent
                                             : Config.Appearance.edge

            MonoIcon {
                id: searchIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 14
                inkColor: search.activeFocus ? Config.Appearance.accent
                                             : Config.Appearance.ink3
                monochrome: true
            }

            TextInput {
                id: search
                anchors.left: searchIcon.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                color: Config.Appearance.ink
                font.family: Config.Appearance.fontFamily
                font.pixelSize: Config.Appearance.fs(12)
                selectByMouse: true
                selectionColor: Config.Appearance.accent
                selectedTextColor: Config.Appearance.inkOnAccent
                onTextChanged: root.query = text
                Keys.onEscapePressed: root.close()
                Keys.onReturnPressed: if (root.shown.length > 0) root.choose(root.shown[0])

                StyledText {
                    anchors.fill: parent
                    visible: search.text === ""
                    verticalAlignment: Text.AlignVCenter
                    text: "Search icons"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
        }
    }

    Flickable {
        id: grid
        KineticScroll { flick: grid }
        anchors.top: header.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        // Tall enough for six rows; more than that and it scrolls.
        height: Math.min(6 * root.cell, Math.max(root.cell, tiles.height))
        contentHeight: tiles.height
        clip: true
        interactive: contentHeight > height

        Grid {
            id: tiles
            width: parent.width
            columns: root.columns

            Repeater {
                model: root.shown

                Rectangle {
                    id: tile
                    required property string modelData
                    width: root.cell
                    height: root.cell
                    radius: Config.Appearance.rSm
                    color: tile.modelData === root.current
                           ? Config.Appearance.sel
                           : (tileHover.hovered ? Config.Appearance.hover : "transparent")

                    // The one it already has, marked rather than just
                    // filled: the fill alone is the same shade as a hover,
                    // so on the way to a new icon the old one stopped
                    // being findable.
                    Rectangle {
                        visible: tile.modelData === root.current
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: 1
                        border.color: Config.Appearance.accent
                    }

                    MonoIcon {
                        anchors.centerIn: parent
                        name: tile.modelData
                        size: 22
                        inkColor: Config.Appearance.ink2
                        accentColor: Config.Appearance.accent
                    }

                    HoverHandler { id: tileHover; cursorShape: Qt.PointingHandCursor }
                    // A MouseArea, not a TapHandler: the catcher behind
                    // this panel takes the exclusive grab at press and
                    // cancels a tap before it fires. Same trap as the
                    // terminal's context menu.
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.choose(tile.modelData)
                    }
                }
            }
        }
    }

    StyledText {
        anchors.centerIn: grid
        visible: root.shown.length === 0
        text: "No icon called that"
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
}
