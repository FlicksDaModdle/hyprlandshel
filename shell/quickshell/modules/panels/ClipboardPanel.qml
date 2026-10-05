import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Clipboard history (Super+Shift+V): what was copied, newest first. Pick
// one — click, or arrows and Enter — and it is on the clipboard again,
// ready to paste where you were. Delete forgets one; "Clear" forgets all.
PanelSurface {
    id: root
    // Centred on the screen, not hanging from the bar.
    showSeam: false

    readonly property var clip: Services.Clipboard
    property string query: ""
    property int current: 0

    readonly property var shown: {
        const q = root.query.trim().toLowerCase();
        const all = root.clip.entries;
        if (q === "") return all;
        return all.filter(e => e.kind === "text" && (e.preview || "").toLowerCase().indexOf(q) >= 0);
    }
    onShownChanged: current = Math.max(0, Math.min(current, shown.length - 1))

    function close() { Config.UiState.clipboardOpen = false; }
    function choose(e) {
        if (!e) return;
        root.clip.copy(e.id);
        root.close();
    }

    onVisibleChanged: {
        Config.UiState.panelWantsKeyboard = visible;
        if (visible) {
            root.query = "";
            search.text = "";
            root.current = 0;
            list.positionViewAtBeginning();
            search.forceActiveFocus();
        }
    }

    implicitWidth: 440
    implicitHeight: header.height + body.height + 34

    Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 14
        spacing: 10

        Item {
            width: parent.width
            height: 24
            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Clipboard"
                font.pixelSize: Config.Appearance.fs(11)
                font.weight: Font.DemiBold
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.9
                color: Config.Appearance.ink2
            }
            StyledText {
                anchors.right: clearAll.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: root.clip.entries.length > 0
                text: root.clip.entries.length + (root.clip.entries.length === 1 ? " item" : " items")
                font.pixelSize: Config.Appearance.fs(11)
                color: Config.Appearance.ink3
            }
            Rectangle {
                id: clearAll
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.clip.entries.length > 0
                width: clearText.implicitWidth + 18
                height: 24
                radius: height / 2
                color: clearHover.hovered ? Config.Appearance.hover : Config.Appearance.sel
                StyledText {
                    id: clearText
                    anchors.centerIn: parent
                    text: "Clear"
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.clip.clear() }
            }
        }

        Rectangle {
            width: parent.width
            height: 32
            radius: Config.Appearance.rPill
            color: Config.Appearance.sel
            border.width: 1
            border.color: search.activeFocus ? Config.Appearance.accent : Config.Appearance.edge

            MonoIcon {
                id: searchIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 14
                inkColor: search.activeFocus ? Config.Appearance.accent : Config.Appearance.ink3
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
                onTextChanged: { root.query = text; root.current = 0; }
                Keys.onEscapePressed: root.close()
                Keys.onReturnPressed: root.choose(root.shown[root.current])
                Keys.onEnterPressed: root.choose(root.shown[root.current])
                Keys.onUpPressed: { root.current = Math.max(0, root.current - 1); list.positionViewAtIndex(root.current, ListView.Contain); }
                Keys.onDownPressed: { root.current = Math.min(root.shown.length - 1, root.current + 1); list.positionViewAtIndex(root.current, ListView.Contain); }
                Keys.onDeletePressed: event => {
                    // Delete edits the search while there is one; with an
                    // empty field it forgets the selected entry.
                    if (search.text !== "" || !root.shown[root.current]) { event.accepted = false; return; }
                    root.clip.remove(root.shown[root.current].id);
                }

                StyledText {
                    anchors.fill: parent
                    visible: search.text === ""
                    verticalAlignment: Text.AlignVCenter
                    text: "Search what you copied"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
        }
    }

    Item {
        id: body
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        height: root.shown.length > 0 ? Math.min(460, list.contentHeight) : 90

        ListView {
            id: list
            anchors.fill: parent
            clip: true
            model: root.shown
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool image: row.modelData.kind === "image"
                width: ListView.view.width
                height: row.image ? 84 : Math.max(44, textCol.implicitHeight + 16)
                radius: Config.Appearance.rSm
                color: row.index === root.current ? Config.Appearance.sel
                     : (rowHover.hovered ? Config.Appearance.hover : "transparent")

                Column {
                    id: textCol
                    visible: !row.image
                    anchors.left: parent.left
                    anchors.right: forget.left
                    anchors.leftMargin: 10
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        width: parent.width
                        // Leading space and line breaks squeezed, so two
                        // lines show two lines of words.
                        text: (row.modelData.preview || "").replace(/\s+/g, " ").trim()
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.pixelSize: Config.Appearance.fs(12.5)
                        color: Config.Appearance.ink
                    }
                    StyledText {
                        text: root.clip.age(row.modelData.time)
                            + (row.modelData.lines > 1 ? " · " + row.modelData.lines + " lines" : "")
                            + (row.modelData.size > 2000 ? " · " + root.clip.sizeText(row.modelData.size) : "")
                        font.pixelSize: Config.Appearance.fs(10.5)
                        color: Config.Appearance.ink3
                    }
                }

                Row {
                    visible: row.image
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Rectangle {
                        width: 112
                        height: 68
                        radius: 6
                        color: Config.Appearance.hover
                        clip: true
                        Image {
                            anchors.fill: parent
                            anchors.margins: 2
                            source: row.image && row.modelData.path ? "file://" + row.modelData.path : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            sourceSize.width: 224
                            sourceSize.height: 136
                        }
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        StyledText {
                            text: "Image"
                            font.pixelSize: Config.Appearance.fs(12.5)
                            color: Config.Appearance.ink
                        }
                        StyledText {
                            text: root.clip.age(row.modelData.time) + " · " + root.clip.sizeText(row.modelData.size)
                            font.pixelSize: Config.Appearance.fs(10.5)
                            color: Config.Appearance.ink3
                        }
                    }
                }

                HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.choose(row.modelData)
                }

                IconButton {
                    id: forget
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    size: 26
                    iconSize: 12
                    icon: "x"
                    opacity: rowHover.hovered || row.index === root.current ? 1 : 0
                    onActivated: root.clip.remove(row.modelData.id)
                }
            }
        }

        StyledText {
            anchors.centerIn: parent
            width: parent.width - 40
            visible: root.shown.length === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: !root.clip.enabled ? "Clipboard history is off — Settings → Clipboard"
                : !root.clip.daemonHas ? "Clipboard history needs hyprshell-daemon (install.sh builds it with cargo)"
                : root.clip.error !== "" ? root.clip.error
                : root.query !== "" ? "Nothing copied matches that"
                : "Nothing copied yet"
            font.pixelSize: Config.Appearance.fs(12)
            color: Config.Appearance.ink3
        }
    }
}
