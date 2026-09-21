import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../icons"
import "../../config" as Config

// Start menu / Launchpad hybrid. A full-screen transparent layer (so
// clicking anywhere else closes it) with the actual menu positioned next
// to the dock — no background blur/dim, matching the mockup's "Windows
// Start menu, not macOS Spotlight" direction.
//
// Pinned row = Config.Apps.pinned + Config.Commands.items (bespoke icons,
// matching the dock). Search / "All apps" = real installed apps from
// Quickshell.DesktopEntries, not mockup demo data.
PanelWindow {
    id: launcher

    visible: Config.UiState.launcherOpen

    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    color: "transparent"
    exclusiveZone: 0

    WlrLayershell.namespace: "quickshell:panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    readonly property bool isLeft: Config.Appearance.dockPosition === "left"
    readonly property real panelWidth: 452
    readonly property real contentHeight: 360
    readonly property real dockOffset: Config.Appearance.dockEdgeGap + Config.Appearance.dockPanelBreadth + 12

    property string query: ""
    property bool showAll: false
    readonly property bool showingList: query.length > 0 || showAll

    readonly property var pinnedItems: Config.Apps.pinned.map(a => ({
        type: "app", key: a.key, label: a.label, icon: a.icon, exec: a.exec
    })).concat(Config.Commands.items.map(c => ({
        type: "command", key: c.key, label: c.label, icon: c.icon, exec: []
    })))

    readonly property string queryLower: query.trim().toLowerCase()
    readonly property var searchPool: queryLower.length === 0
        ? DesktopEntries.applications.values
        : DesktopEntries.applications.values.filter(
            e => ((e.name || "") + " " + (e.comment || "")).toLowerCase().includes(queryLower)
          )

    function runItem(item) {
        if (item.type === "command") {
            runCommand(item.key);
        } else if (item.exec && item.exec.length > 0) {
            Quickshell.execDetached(item.exec);
        }
        close();
    }

    function runCommand(key) {
        if (key === "toggleTheme") Config.Appearance.dark = !Config.Appearance.dark;
        else if (key === "lock") Quickshell.execDetached(["hyprlock"]);
        else if (key === "reload") Quickshell.execDetached(["sh", "-c", "qs -c hyprshell kill; qs -c hyprshell &"]);
    }

    // --- Recommended row: real recently-used files, from the same
    // ~/.local/share/recently-used.xbel GTK/Qt apps already write to —
    // not the mockup's fabricated Bar.qml/theme.json demo entries.
    property string homeDir: ""
    readonly property var recentItems: parseRecentXbel(recentFile.text())

    function parseRecentXbel(xml) {
        if (!xml) return [];
        const out = [];
        const bookmarkRe = /<bookmark\s+([^>]*)>/g;
        let m;
        while ((m = bookmarkRe.exec(xml)) !== null) {
            const attrs = m[1];
            const hrefM = /href="([^"]*)"/.exec(attrs);
            const modM = /modified="([^"]*)"/.exec(attrs);
            if (!hrefM || hrefM[1].indexOf("file://") !== 0) continue;
            const path = decodeURIComponent(hrefM[1].slice("file://".length));
            out.push({ name: path.split("/").pop(), path: path, modified: modM ? modM[1] : "" });
        }
        out.sort((a, b) => (a.modified < b.modified ? 1 : -1));
        return out.slice(0, 4);
    }

    function relativeTime(iso) {
        const then = Date.parse(iso);
        if (isNaN(then)) return "";
        const minutes = Math.round((Date.now() - then) / 60000);
        if (minutes < 1) return "just now";
        if (minutes < 60) return minutes + " min ago";
        const hours = Math.round(minutes / 60);
        if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago");
        const days = Math.round(hours / 24);
        if (days === 1) return "yesterday";
        if (days < 7) return days + " days ago";
        return new Date(then).toLocaleDateString();
    }

    function iconForFile(name) {
        const ext = (name.split(".").pop() || "").toLowerCase();
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"].indexOf(ext) >= 0 ? "image" : "file";
    }

    function runTop() {
        if (showingList) {
            if (searchPool.length > 0) {
                searchPool[0].execute();
                close();
            } else if (query.trim().length > 0) {
                Quickshell.execDetached(["sh", "-c", query]);
                close();
            }
        } else if (pinnedItems.length > 0) {
            runItem(pinnedItems[0]);
        }
    }

    function close() {
        Config.UiState.launcherOpen = false;
        query = "";
        showAll = false;
    }

    onVisibleChanged: if (visible) searchInput.forceActiveFocus()

    // Full-screen click-away catcher — no scrim/blur, the desktop stays sharp.
    MouseArea {
        anchors.fill: parent
        onClicked: launcher.close()
    }

    Rectangle {
        id: panel
        width: launcher.panelWidth
        implicitHeight: column.implicitHeight
        radius: Config.Appearance.rPanel
        color: Config.Appearance.panel
        border.width: 1
        border.color: Config.Appearance.edge
        clip: true

        anchors.bottom: launcher.isLeft ? undefined : parent.bottom
        anchors.bottomMargin: launcher.isLeft ? 0 : launcher.dockOffset
        anchors.horizontalCenter: launcher.isLeft ? undefined : parent.horizontalCenter
        anchors.left: launcher.isLeft ? parent.left : undefined
        anchors.leftMargin: launcher.isLeft ? launcher.dockOffset : 0
        anchors.verticalCenter: launcher.isLeft ? parent.verticalCenter : undefined

        // Absorbs clicks on the panel itself so they don't fall through
        // to the full-screen close-catcher behind it.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: column
            width: parent.width

            // Signature index bar, shared across the shell's popovers.
            // Inset by the panel's own corner radius: `clip: true` on the
            // panel only clips to its rectangular bounds, not the rounded
            // shape, so anything flush against a corner (like this, full
            // width at y:0) would render past where the panel visually
            // curves away instead of following the curve.
            Row {
                x: Config.Appearance.rPanel
                width: parent.width - Config.Appearance.rPanel * 2
                height: 2
                Rectangle { width: 40; height: 2; color: Config.Appearance.accent }
                Rectangle { width: parent.width - 40; height: 2; color: Config.Appearance.seam }
            }

            Item {
                width: parent.width
                height: 50

                Row {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8

                    Rectangle {
                        id: searchField
                        width: parent.width - escChip.width - parent.spacing
                        height: 32
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.hover
                        border.width: searchInput.activeFocus ? 2 : 1
                        border.color: searchInput.activeFocus ? Config.Appearance.accent : Config.Appearance.edge
                        Behavior on border.color { ColorAnimation { duration: 120 } }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 11
                            anchors.rightMargin: 11
                            spacing: 8

                            MonoIcon {
                                name: "search"
                                size: 15
                                inkColor: searchInput.activeFocus ? Config.Appearance.accent : Config.Appearance.ink3
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Item {
                                width: parent.width - 15 - 8
                                height: parent.height

                                TextInput {
                                    id: searchInput
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    color: Config.Appearance.ink
                                    font.pixelSize: 13
                                    font.family: "Inter"
                                    clip: true
                                    onTextChanged: { launcher.query = text; launcher.showAll = false; }
                                    Keys.onEscapePressed: launcher.close()
                                    Keys.onReturnPressed: launcher.runTop()
                                }
                                Text {
                                    visible: searchInput.text.length === 0
                                    text: "Search apps and commands"
                                    color: Config.Appearance.ink3
                                    font.pixelSize: 13
                                    font.family: "Inter"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: escChip
                        width: escLabel.implicitWidth + 16
                        height: 24
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.hover
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            id: escLabel
                            anchors.centerIn: parent
                            text: "ESC"
                            color: Config.Appearance.ink3
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            font.family: "Inter"
                        }
                    }
                }
            }

            // --- Pinned grid ---------------------------------------------------
            Item {
                width: parent.width
                height: launcher.contentHeight
                visible: !launcher.showingList

                Column {
                    width: parent.width
                    anchors.top: parent.top

                    Item {
                        width: parent.width - 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 32

                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            Rectangle { width: 14; height: 2; color: Config.Appearance.accent; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                                text: "PINNED"
                                color: Config.Appearance.ink2
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1
                                font.family: "Inter"
                            }
                        }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: allAppsRow.implicitWidth + 20
                            height: 25
                            radius: Config.Appearance.rSm
                            color: allAppsHover.hovered ? Config.Appearance.accent : Config.Appearance.hover
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Row {
                                id: allAppsRow
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    text: "All apps"
                                    color: allAppsHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink2
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    font.family: "Inter"
                                }
                                MonoIcon {
                                    name: "chevronRight"
                                    size: 12
                                    inkColor: allAppsHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink2
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            HoverHandler { id: allAppsHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: { launcher.showAll = true; launcher.query = ""; } }
                        }
                    }

                    Grid {
                        width: parent.width - 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        columns: 4
                        topPadding: 4

                        Repeater {
                            model: launcher.pinnedItems

                            Item {
                                id: pinTile
                                required property var modelData
                                width: (parent.width) / 4
                                height: 64

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    radius: Config.Appearance.rSm
                                    color: pinHover.hovered ? Config.Appearance.sel : "transparent"
                                    border.width: pinHover.hovered ? 1 : 0
                                    border.color: Config.Appearance.seam
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 6

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: 30
                                        height: 30
                                        radius: Config.Appearance.rSm
                                        color: Config.Appearance.hover
                                        MonoIcon {
                                            anchors.centerIn: parent
                                            name: pinTile.modelData.icon
                                            size: 16
                                            inkColor: Config.Appearance.ink
                                            accentColor: Config.Appearance.accent
                                        }
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: pinTile.width - 4
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: pinTile.modelData.label
                                        color: Config.Appearance.ink
                                        font.pixelSize: 11
                                        font.family: "Inter"
                                    }
                                }

                                HoverHandler { id: pinHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: launcher.runItem(pinTile.modelData) }
                            }
                        }
                    }

                    // Real recently-used files (~/.local/share/recently-used.xbel),
                    // not the mockup's fabricated demo entries. Hidden entirely
                    // when there's nothing real to show.
                    Item {
                        width: parent.width - 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: launcher.recentItems.length > 0
                        height: visible ? (11 + 30 + Math.ceil(launcher.recentItems.length / 2) * 40) : 0

                        Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

                        Item {
                            y: 11
                            width: parent.width
                            height: 26

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Rectangle { width: 14; height: 2; color: Config.Appearance.accent; anchors.verticalCenter: parent.verticalCenter }
                                Text {
                                    text: "RECOMMENDED"
                                    color: Config.Appearance.ink2
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    font.letterSpacing: 1
                                    font.family: "Inter"
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: "recent"
                                color: Config.Appearance.ink3
                                font.pixelSize: 11
                                font.family: "Inter"
                            }
                        }

                        Grid {
                            y: 41
                            width: parent.width
                            columns: 2
                            columnSpacing: 4
                            rowSpacing: 1

                            Repeater {
                                model: launcher.recentItems

                                Item {
                                    id: recentTile
                                    required property var modelData
                                    width: (parent.width - 4) / 2
                                    height: 39

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Config.Appearance.rSm
                                        color: recentHover.hovered ? Config.Appearance.sel : "transparent"
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: 7
                                        spacing: 8

                                        Rectangle {
                                            width: 22
                                            height: 22
                                            radius: Config.Appearance.rSm
                                            color: Config.Appearance.hover
                                            border.width: 1
                                            border.color: Config.Appearance.rule
                                            anchors.verticalCenter: parent.verticalCenter
                                            MonoIcon {
                                                anchors.centerIn: parent
                                                name: recentTile.modelData.icon
                                                size: 12
                                                inkColor: Config.Appearance.ink2
                                                accentColor: Config.Appearance.accent
                                            }
                                        }

                                        Column {
                                            width: parent.width - 22 - 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text {
                                                text: recentTile.modelData.name
                                                color: Config.Appearance.ink
                                                font.pixelSize: 11
                                                font.family: "Inter"
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }
                                            Text {
                                                text: launcher.relativeTime(recentTile.modelData.modified)
                                                color: Config.Appearance.ink3
                                                font.pixelSize: 10
                                                font.family: "Inter"
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }
                                        }
                                    }

                                    HoverHandler { id: recentHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            Quickshell.execDetached(["xdg-open", recentTile.modelData.path]);
                                            launcher.close();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // --- Search results / all apps -------------------------------------
            Item {
                width: parent.width
                height: launcher.contentHeight
                visible: launcher.showingList

                Item {
                    width: parent.width - 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 30

                    Text {
                        anchors.left: parent.left
                        text: launcher.query.length > 0 ? "Results" : "All apps"
                        color: Config.Appearance.ink
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        font.family: "Inter"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        visible: launcher.showAll && launcher.query.length === 0
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: backRow.implicitWidth + 20
                        height: 28
                        radius: Config.Appearance.rSm
                        color: backHover.hovered ? Config.Appearance.sel : Config.Appearance.hover

                        Row {
                            id: backRow
                            anchors.centerIn: parent
                            spacing: 7
                            MonoIcon { name: "chevronLeft"; size: 13; inkColor: Config.Appearance.ink2; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: "Back to pinned"; color: Config.Appearance.ink2; font.pixelSize: 11; font.weight: Font.DemiBold; font.family: "Inter" }
                        }

                        HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { launcher.showAll = false; launcher.query = ""; } }
                    }
                }

                ListView {
                    id: resultsList
                    anchors.top: parent.top
                    anchors.topMargin: 30
                    anchors.bottom: parent.bottom
                    width: parent.width - 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    clip: true
                    spacing: 1
                    model: launcher.searchPool
                    visible: launcher.searchPool.length > 0

                    delegate: Item {
                        id: resultRow
                        required property var modelData
                        required property int index
                        width: resultsList.width
                        height: 43

                        readonly property bool isTopResult: index === 0

                        Rectangle {
                            anchors.fill: parent
                            radius: Config.Appearance.rSm
                            color: resultRow.isTopResult ? Config.Appearance.accent : (rowHover.hovered ? Config.Appearance.hover : "transparent")
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 11

                            Rectangle {
                                width: 27
                                height: 27
                                radius: Config.Appearance.rSm
                                color: resultRow.isTopResult ? Qt.rgba(1, 1, 1, 0.22) : Config.Appearance.hover
                                anchors.verticalCenter: parent.verticalCenter

                                Image {
                                    id: appIcon
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    source: resultRow.modelData.icon ? Quickshell.iconPath(resultRow.modelData.icon, "") : ""
                                    visible: status === Image.Ready
                                }
                                Text {
                                    visible: appIcon.status !== Image.Ready
                                    anchors.centerIn: parent
                                    text: (resultRow.modelData.name || "?").charAt(0).toUpperCase()
                                    color: resultRow.isTopResult ? Config.Appearance.onAccent : Config.Appearance.ink2
                                    font.pixelSize: 12
                                    font.weight: Font.Bold
                                    font.family: "Inter"
                                }
                            }

                            Column {
                                width: parent.width - 27 - 11 - 40
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    text: resultRow.modelData.name || ""
                                    color: resultRow.isTopResult ? Config.Appearance.onAccent : Config.Appearance.ink
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    font.family: "Inter"
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: resultRow.modelData.comment || ""
                                    color: resultRow.isTopResult ? Config.Appearance.onAccent : Config.Appearance.ink3
                                    font.pixelSize: 10
                                    font.family: "Inter"
                                    elide: Text.ElideRight
                                    width: parent.width
                                    visible: text.length > 0
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: resultRow.isTopResult
                                text: "return"
                                color: Config.Appearance.onAccent
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                font.family: "Inter"
                            }
                        }

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                resultRow.modelData.execute();
                                launcher.close();
                            }
                        }
                    }
                }

                Text {
                    visible: launcher.searchPool.length === 0
                    anchors.top: parent.top
                    anchors.topMargin: 60
                    width: parent.width - 28
                    anchors.horizontalCenter: parent.horizontalCenter
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "No matches — press enter to run as a command"
                    color: Config.Appearance.ink3
                    font.pixelSize: 13
                    font.family: "Inter"
                }
            }

            // --- Footer ----------------------------------------------------------
            Item {
                width: parent.width
                height: 40

                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Config.Appearance.rule }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 9

                    Rectangle {
                        width: 21
                        height: 21
                        radius: 10.5
                        color: Config.Appearance.accent
                        Text {
                            anchors.centerIn: parent
                            text: (launcher.userName || "?").charAt(0).toUpperCase()
                            color: Config.Appearance.onAccent
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            font.family: "Inter"
                        }
                    }

                    Column {
                        spacing: 3
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: launcher.userName || ""
                            color: Config.Appearance.ink
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.family: "Inter"
                        }
                        Rectangle { width: 30; height: 2; color: Config.Appearance.accent }
                    }
                }
            }
        }
    }

    property string userName: ""
    Process {
        command: ["whoami"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: launcher.userName = this.text.trim()
        }
    }

    Process {
        command: ["sh", "-c", "echo $HOME"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: launcher.homeDir = this.text.trim()
        }
    }

    FileView {
        id: recentFile
        path: launcher.homeDir ? launcher.homeDir + "/.local/share/recently-used.xbel" : ""
        watchChanges: true
        onFileChanged: reload()
    }
}
