import QtQuick
import Quickshell
import Quickshell.Widgets
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The notification center: everything the server is still holding, with the
// do-not-disturb and Clear controls from the mockup's header.
//
// Rows carry the sender's real actions as buttons, so "Upgrade" / "Later" in
// the mockup become whatever the sending application actually offered.
//
// History (when kept — Settings → Notifications): everything shown before,
// dismissed or not, by day, with a search over app, title and text.
PanelSurface {
    id: root

    readonly property var groups: Services.Notifications.grouped
    readonly property bool empty: Services.Notifications.count === 0
    readonly property var hist: Services.NotifHistory
    readonly property bool historyOffered: hist.on
    // "now" or "history"; back to now each time the center opens.
    property string view: "now"
    readonly property bool inHistory: view === "history" && historyOffered
    property bool confirmClear: false

    Connections {
        target: Config.UiState
        function onNotificationsOpenChanged() {
            if (!Config.UiState.notificationsOpen) {
                root.view = "now";
                histSearch.text = "";
            }
        }
    }
    Binding { target: root.hist; property: "active"; value: root.inHistory && Config.UiState.notificationsOpen }
    // The search field needs the keyboard while History is up.
    Binding {
        target: Config.UiState
        property: "panelWantsKeyboard"
        value: true
        when: root.inHistory && Config.UiState.notificationsOpen
    }
    onInHistoryChanged: {
        root.confirmClear = false;
        if (inHistory) histSearch.forceActiveFocus();
    }
    Timer { id: confirmTimeout; interval: 3000; onTriggered: root.confirmClear = false }

    implicitWidth: 396
    implicitHeight: root.inHistory
        ? Math.min(560, header.height + searchBox.height + 10 + Math.max(70, histColumn.implicitHeight + 14))
        : Math.min(560, header.height + Math.max(70, listColumn.implicitHeight + 14))

    // ── header ────────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 52

        // The title, and beside it History when there is one to show:
        // two words to choose between rather than a control of their own.
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 14

            Repeater {
                model: root.historyOffered ? [["now", "Notifications"], ["history", "History"]] : [["now", "Notifications"]]
                StyledText {
                    id: tab
                    required property var modelData
                    readonly property bool current: (root.inHistory ? "history" : "now") === modelData[0]
                    text: modelData[1]
                    font.pixelSize: Config.Appearance.fs(13)
                    font.weight: Font.DemiBold
                    color: current || !root.historyOffered ? Config.Appearance.ink
                         : (tabHover.hovered ? Config.Appearance.ink2 : Config.Appearance.ink3)
                    HoverHandler { id: tabHover; enabled: root.historyOffered; cursorShape: Qt.PointingHandCursor }
                    TapHandler { enabled: root.historyOffered; onTapped: root.view = tab.modelData[0] }
                }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: dndRow.implicitWidth + 20
                height: 28
                radius: 9
                color: Services.Focus.quiet ? Config.Appearance.accent
                     : (dndHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
                Behavior on color { ColorAnimation { duration: Config.Appearance.anim(140) } }

                Row {
                    id: dndRow
                    anchors.centerIn: parent
                    spacing: 7
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "moon"
                        size: 13
                        inkColor: Services.Focus.quiet ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                        monochrome: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Services.Focus.scheduled && !Config.Appearance.dnd ? (Services.Focus.current.schedule.name || "Focus") : "Do not disturb"
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        color: Services.Focus.quiet ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                    }
                }

                HoverHandler { id: dndHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Services.Notifications.toggleDnd() }
            }

            // In History, Clear asks once more: what it forgets cannot be
            // brought back.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.inHistory ? root.hist.total > 0 : !root.empty
                width: clearLabel.implicitWidth + 20
                height: 28
                radius: 9
                color: root.confirmClear ? "#d93a2b"
                     : (clearHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
                Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }

                StyledText {
                    id: clearLabel
                    anchors.centerIn: parent
                    text: root.confirmClear ? "Forget all " + root.hist.total + "?" : "Clear"
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.DemiBold
                    color: root.confirmClear ? "white" : Config.Appearance.ink2
                }

                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        if (!root.inHistory) {
                            Services.Notifications.clearAll();
                        } else if (!root.confirmClear) {
                            root.confirmClear = true;
                            confirmTimeout.restart();
                        } else {
                            root.confirmClear = false;
                            root.hist.clear();
                        }
                    }
                }
            }
        }
    }

    // ── list ──────────────────────────────────────────────────────────────
    Flickable {
        id: notificationCenterScroll1
        KineticScroll { flick: notificationCenterScroll1 }
        visible: !root.inHistory
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        contentHeight: listColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: listColumn
            x: 12
            width: parent.width - 24
            spacing: 6

            Repeater {
                model: root.groups

                Column {
                    id: group
                    required property var modelData
                    width: listColumn.width
                    spacing: 6

                    // Group heading, only when grouping by app and the group
                    // actually stacks.
                    StyledText {
                        visible: Config.Appearance.grouping === "App" && group.modelData.entries.length > 1
                        text: group.modelData.app + " · " + group.modelData.entries.length
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.8
                        color: Config.Appearance.ink3
                        topPadding: 4
                    }

                    Repeater {
                        model: group.modelData.entries
                        NotificationRow {
                            required property var modelData
                            width: listColumn.width
                            notification: modelData
                        }
                    }
                }
            }

            Rectangle {
                visible: root.empty
                width: listColumn.width
                height: 74
                radius: Config.Appearance.rCard
                color: Config.Appearance.hover

                StyledText {
                    anchors.centerIn: parent
                    text: Services.Focus.quiet ? Services.Focus.reason + " — banners are quiet" : "No notifications"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
        }
    }

    // ── history ───────────────────────────────────────────────────────────
    Rectangle {
        id: searchBox
        visible: root.inHistory
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        height: 32
        radius: Config.Appearance.rPill
        color: Config.Appearance.sel
        border.width: 1
        border.color: histSearch.activeFocus ? Config.Appearance.accent : Config.Appearance.edge

        MonoIcon {
            id: histSearchIcon
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: 14
            inkColor: histSearch.activeFocus ? Config.Appearance.accent : Config.Appearance.ink3
            monochrome: true
        }
        TextInput {
            id: histSearch
            anchors.left: histSearchIcon.right
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
            onTextChanged: root.hist.query = text
            Keys.onEscapePressed: {
                if (text !== "") text = "";
                else Config.UiState.notificationsOpen = false;
            }

            StyledText {
                anchors.fill: parent
                visible: histSearch.text === ""
                verticalAlignment: Text.AlignVCenter
                text: "Search " + root.hist.total + " kept"
                font.pixelSize: Config.Appearance.fs(12)
                color: Config.Appearance.ink3
            }
        }
    }

    Flickable {
        id: notificationCenterScroll0
        KineticScroll { flick: notificationCenterScroll0 }
        visible: root.inHistory
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: searchBox.bottom
        anchors.topMargin: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        contentHeight: histColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: histColumn
            x: 12
            width: parent.width - 24
            spacing: 4

            Repeater {
                model: root.inHistory ? root.hist.byDay : []

                Column {
                    id: day
                    required property var modelData
                    required property int index
                    width: histColumn.width
                    spacing: 4

                    StyledText {
                        text: day.modelData.day
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.8
                        color: Config.Appearance.ink3
                        topPadding: day.index === 0 ? 0 : 8
                        bottomPadding: 2
                    }

                    Repeater {
                        model: day.modelData.entries

                        Rectangle {
                            id: entry
                            required property var modelData
                            readonly property var e: modelData
                            readonly property string themed: Config.Apps.themeIcon(e.icon)
                            width: histColumn.width
                            height: entryCol.implicitHeight + 18
                            radius: Config.Appearance.rCard
                            color: entryHover.hovered ? Config.Appearance.sel : Config.Appearance.hover

                            HoverHandler { id: entryHover }

                            // Critical ones keep their rail here too.
                            Rectangle {
                                visible: entry.e.urgency === 2
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.margins: 6
                                width: 2
                                radius: 1
                                color: Config.Appearance.accent
                            }

                            Rectangle {
                                id: plate
                                x: 12; y: 9
                                width: 26
                                height: 26
                                radius: 8
                                color: Config.Appearance.sel
                                IconImage {
                                    anchors.centerIn: parent
                                    width: 15
                                    height: 15
                                    visible: entry.themed !== ""
                                    source: entry.themed
                                }
                                MonoIcon {
                                    anchors.centerIn: parent
                                    visible: entry.themed === ""
                                    name: Services.Notifications.iconFor({ appName: entry.e.app })
                                    size: 13
                                    inkColor: Config.Appearance.ink
                                    accentColor: Config.Appearance.accent
                                }
                            }

                            Column {
                                id: entryCol
                                anchors.left: plate.right
                                anchors.leftMargin: 10
                                anchors.right: parent.right
                                anchors.rightMargin: 34
                                y: 9
                                spacing: 3

                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: (entry.e.app || "Notification") + " · " + root.hist.timeOf(entry.e.time)
                                    font.pixelSize: Config.Appearance.fs(11)
                                    color: Config.Appearance.ink3
                                }
                                StyledText {
                                    width: parent.width
                                    visible: text !== ""
                                    text: entry.e.summary
                                    elide: Text.ElideRight
                                    font.pixelSize: Config.Appearance.fs(12.5)
                                    font.weight: Font.DemiBold
                                }
                                StyledText {
                                    width: parent.width
                                    visible: text !== ""
                                    text: entry.e.body
                                    // Kept as plain text: the history keeps
                                    // what it read as, not its markup.
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    font.pixelSize: Config.Appearance.fs(12)
                                    color: Config.Appearance.ink2
                                }
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                y: 8
                                width: 22
                                height: 22
                                radius: 7
                                visible: entryHover.hovered
                                color: forgetHover.hovered ? Config.Appearance.sel : "transparent"
                                MonoIcon {
                                    anchors.centerIn: parent
                                    name: "x"
                                    size: 13
                                    inkColor: Config.Appearance.ink3
                                    monochrome: true
                                }
                                HoverHandler { id: forgetHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.hist.remove(entry.e.id) }
                            }
                        }
                    }
                }
            }

            Rectangle {
                visible: root.hist.entries.length === 0
                width: histColumn.width
                height: 74
                radius: Config.Appearance.rCard
                color: Config.Appearance.hover

                StyledText {
                    anchors.centerIn: parent
                    text: histSearch.text !== "" ? "Nothing matches" : "Nothing kept yet"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
        }
    }
}
