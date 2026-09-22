import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Widgets
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Start menu / Launchpad hybrid, anchored beside the dock's Start tile — the
// mockup's direction is a Windows Start menu, not a full-screen Spotlight,
// so there's no scrim and the desktop stays sharp behind it.
//
// Pinned grid  = Apps.pinned + Commands.items, drawn with the bespoke pack.
// Search / all = real installed applications from DesktopEntries, plus the
//                shell's own commands, plus a run-as-command fallback.
// Recommended  = real recently-used files from recently-used.xbel.
PanelWindow {
    id: launcher

    visible: Config.UiState.launcherOpen && !Config.UiState.locked

    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    color: "transparent"
    exclusiveZone: 0

    WlrLayershell.namespace: "quickshell:panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property bool isLeft: Config.Appearance.dockLeft
    // Geometry is a preference now — Settings → Shell → Launcher. The grid
    // reflows to the column count rather than assuming four across.
    readonly property real panelWidth: Config.Appearance.launcherWidth
    readonly property real panelHeight: Config.Appearance.launcherHeight
    readonly property int gridColumns: Math.max(3, Config.Appearance.launcherColumns)
    readonly property real gridTile: Config.Appearance.launcherTileSize
    readonly property real gridIcon: Config.Appearance.launcherIconSize
    readonly property real dockOffset: Config.Appearance.dockEdgeGap
                                       + Config.Appearance.dockPanelBreadth + 12

    property string query: ""
    property bool showAll: false
    property int selectedIndex: 0

    readonly property string queryLower: query.trim().toLowerCase()
    readonly property bool searching: queryLower.length > 0
    readonly property bool showingList: searching || showAll

    // ── pinned grid ───────────────────────────────────────────────────────
    readonly property var pinnedItems: Config.Apps.pinned
        .filter(a => a.key !== "appSettings")
        .map(a => ({ kind: "app", key: a.key, label: a.label, icon: a.icon,
                     cat: a.match.source, exec: a.exec }))
        .concat(Config.Commands.items.map(c => ({
            kind: "command", key: c.key, label: c.label, icon: c.icon, cat: c.cat, exec: []
        })))

    readonly property int perPage: gridColumns * 3
    readonly property int pageCount: Math.max(1, Math.ceil(pinnedItems.length / perPage))
    property int page: 0
    readonly property var pageItems: pinnedItems.slice(page * perPage, (page + 1) * perPage)

    // ── search ────────────────────────────────────────────────────────────
    readonly property var appResults: {
        // Nothing to search while the launcher is shut, and building it anyway
        // means instantiating a delegate per installed application at startup.
        if (!visible) return [];
        const apps = DesktopEntries.applications.values.filter(e => e && !e.noDisplay);
        const pool = apps.map(e => ({
            kind: "desktop", entry: e, label: e.name || "",
            icon: "", appIcon: Config.Apps.themeIcon(e.icon),
            cat: e.genericName || e.comment || (e.categories && e.categories.length > 0
                 ? e.categories[0] : "Application")
        }));
        const cmds = Config.Commands.items.map(c => ({
            kind: "command", key: c.key, label: c.label, icon: c.icon, appIcon: "", cat: c.cat
        }));
        const all = pool.concat(cmds);
        if (!searching) {
            all.sort((a, b) => a.label.localeCompare(b.label));
            return all;
        }
        // Rank: prefix match beats word-start beats substring, and the
        // label beats the description.
        const q = queryLower;
        const scored = [];
        for (const item of all) {
            const label = item.label.toLowerCase();
            const cat = (item.cat || "").toLowerCase();
            let score = -1;
            if (label.startsWith(q)) score = 0;
            else if (label.indexOf(" " + q) >= 0) score = 1;
            else if (label.indexOf(q) >= 0) score = 2;
            else if (cat.indexOf(q) >= 0) score = 3;
            if (score >= 0) scored.push({ item: item, score: score });
        }
        scored.sort((a, b) => (a.score - b.score) || a.item.label.localeCompare(b.item.label));
        return scored.map(s => s.item);
    }

    readonly property string listTitle: Config.UiState.appPickerFor !== ""
        ? "Pick an app — it replaces the tile you right-clicked"
        : (searching
            ? (appResults.length + (appResults.length === 1 ? " result" : " results"))
            : "All apps")

    // ── recently used ─────────────────────────────────────────────────────
    FileView {
        id: recentFile
        path: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share"))
              + "/recently-used.xbel"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    readonly property var recentItems: parseRecent(recentFile.text())

    function parseRecent(xml) {
        if (!xml) return [];
        const out = [];
        const re = /<bookmark\s+([^>]*)>/g;
        let m;
        while ((m = re.exec(xml)) !== null) {
            const attrs = m[1];
            const href = /href="([^"]*)"/.exec(attrs);
            const mod = /modified="([^"]*)"/.exec(attrs);
            if (!href || href[1].indexOf("file://") !== 0) continue;
            const path = decodeURIComponent(href[1].slice(7));
            out.push({
                name: path.split("/").pop(),
                path: path,
                modified: mod ? mod[1] : ""
            });
        }
        out.sort((a, b) => (a.modified < b.modified ? 1 : -1));
        return out.slice(0, 4);
    }

    function relativeTime(iso) {
        const then = Date.parse(iso);
        if (isNaN(then)) return "";
        const mins = Math.round((Date.now() - then) / 60000);
        if (mins < 1) return "just now";
        if (mins < 60) return mins + " min ago";
        const hours = Math.round(mins / 60);
        if (hours < 24) return hours === 1 ? "1 hour ago" : hours + " hours ago";
        const days = Math.round(hours / 24);
        if (days === 1) return "yesterday";
        if (days < 7) return days + " days ago";
        return Qt.formatDate(new Date(then), "d MMM");
    }

    function iconForFile(name) {
        const ext = (name.split(".").pop() || "").toLowerCase();
        if (["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "avif"].indexOf(ext) >= 0) return "image";
        if (["json", "toml", "yaml", "yml", "conf", "ini"].indexOf(ext) >= 0) return "palette";
        if (["zip", "tar", "gz", "xz", "zst", "7z"].indexOf(ext) >= 0) return "pkg";
        return "file";
    }

    // ── running ───────────────────────────────────────────────────────────
    function run(item) {
        if (!item) return;
        // In picker mode the launcher is being used to fill a dock slot, so
        // an entry is a choice rather than something to start.
        if (Config.UiState.appPickerFor !== "") { assignToSlot(item); return; }
        if (item.kind === "command") runCommand(item.key);
        else if (item.kind === "desktop" && item.entry) item.entry.execute();
        else if (item.exec && item.exec.length > 0) Quickshell.execDetached(item.exec);
        close();
    }

    // A .desktop entry knows its own name, icon and command; the window class
    // it will produce is a guess, and startupClass is the entry's own
    // declaration of it where one exists, which is the case that matters for
    // apps whose class doesn't match their binary.
    function assignToSlot(item) {
        const key = Config.UiState.appPickerFor;
        if (key === "") return;
        let exec = item.exec || [];
        let cls = "";
        let icon = item.icon || "square";
        if (item.kind === "desktop" && item.entry) {
            const e = item.entry;
            // StartupWMClass when the entry declares one — that is the whole
            // point of the key, and it is the only reliable answer for apps
            // whose window class doesn't match their binary. Otherwise the
            // entry id with its .desktop suffix taken off.
            cls = e.startupClass || e.id || "";
            if (cls.endsWith(".desktop")) cls = cls.slice(0, -8);
            // `command` is the Exec line already parsed into argv with the
            // %f/%U field codes removed, so it can be run directly.
            if (e.command && e.command.length > 0) exec = e.command.slice();
            icon = Config.Apps.iconFor(cls || e.name);
        } else if (exec.length > 0) {
            cls = exec[0];
            icon = Config.Apps.iconFor(cls);
        }
        Config.Apps.assign(key, item.label, exec, icon, cls);
        Config.UiState.appPickerFor = "";
        close();
    }

    function runCommand(key) {
        switch (key) {
        case "theme":     Config.Appearance.toggleTheme(); break;
        case "overview":  Config.UiState.toggleOverview(); return;   // keep it open
        case "settings":  Config.UiState.openSettings(); return;
        case "displays":  Config.UiState.openSettings("Display"); return;
        case "sound":     Config.UiState.openSettings("Sound"); return;
        case "network":   Config.UiState.openSettings("Network"); return;
        case "bluetooth": Config.UiState.openSettings("Bluetooth"); return;
        case "keybinds":  Config.UiState.openSettings("Keybinds"); return;
        case "wallpaper": Config.UiState.openSettings("Appearance"); return;
        case "lock":      Config.UiState.lock(); return;
        case "reload":    Services.Session.reloadShell(); break;
        case "logout":    Services.Session.logout(); break;
        case "suspend":   Services.Session.suspend(); break;
        case "poweroff":  Services.Session.powerOff(); break;
        case "capture":
            Quickshell.execDetached(["sh", "-c",
                "sleep 0.2; f=\"$HOME/Pictures/$(date +%Y-%m-%d-%H%M%S).png\"; "
                + "mkdir -p \"$HOME/Pictures\"; grim -g \"$(slurp)\" \"$f\" && "
                + "(wl-copy < \"$f\" 2>/dev/null; notify-send -a Screenshot 'Region saved' \"$f\")"]);
            break;
        }
    }

    function runSelection() {
        if (showingList) {
            if (appResults.length > 0) {
                run(appResults[Math.max(0, Math.min(appResults.length - 1, selectedIndex))]);
            } else if (query.trim().length > 0) {
                // No match: treat what was typed as a command line, which is
                // what the mockup's empty state promises.
                Quickshell.execDetached(["sh", "-c", query.trim()]);
                close();
            }
        } else if (pageItems.length > 0) {
            run(pageItems[Math.max(0, Math.min(pageItems.length - 1, selectedIndex))]);
        }
    }

    function close() {
        Config.UiState.launcherOpen = false;
    }

    onVisibleChanged: {
        if (visible) {
            query = "";
            showAll = false;
            page = 0;
            selectedIndex = 0;
            searchInput.forceActiveFocus();
        }
    }

    onQueryChanged: selectedIndex = 0;
    onShowAllChanged: selectedIndex = 0;

    // Click-away catcher — no scrim, so the desktop behind stays sharp.
    MouseArea {
        anchors.fill: parent
        onClicked: launcher.close()
    }

    // ── panel ─────────────────────────────────────────────────────────────
    PanelSurface {
        id: panel

        width: launcher.panelWidth
        // The height you set, not "whatever the content happens to need".
        //
        // This used to be min(setting, content), which meant the slider did
        // nothing whenever the content was shorter — which it almost always
        // is. Raising it looked broken because it was: the panel was already
        // as tall as its contents and the setting only ever capped it.
        //
        // Clamped to the screen so a large value can't push it off the top.
        height: Math.max(body.implicitHeight,
                         Math.min(launcher.panelHeight,
                                  launcher.height - launcher.dockOffset - 24))

        // Anchored to the dock's Start tile: above it when the dock is at
        // the bottom, beside it when the dock is on the left. Clamped so it
        // can't run off the screen on a narrow monitor.
        x: launcher.isLeft
           ? launcher.dockOffset
           : Math.max(12, Math.min(launcher.width - width - 12,
                Math.round(launcher.width / 2 - width / 2)))
        y: launcher.isLeft
           ? Math.max(Config.Appearance.barHeight + 12,
                Math.min(launcher.height - height - 12,
                         Math.round(launcher.height / 2 - height / 2)))
           : launcher.height - height - launcher.dockOffset

        // Swallow clicks so they don't reach the catcher behind.
        MouseArea { anchors.fill: parent }

        Column {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top

            // ── search ────────────────────────────────────────────────────
            Item {
                width: parent.width
                height: 50

                Rectangle {
                    id: searchBox
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: escChip.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    height: 32
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.hover
                    border.width: searchInput.activeFocus ? 2 : 1
                    border.color: searchInput.activeFocus
                                  ? Config.Appearance.accent : Config.Appearance.edge
                    Behavior on border.color { ColorAnimation { duration: 140 } }

                    MonoIcon {
                        id: searchIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        name: "search"
                        size: 15
                        inkColor: searchInput.activeFocus
                                  ? Config.Appearance.accent : Config.Appearance.ink3
                        monochrome: true
                    }

                    TextInput {
                        id: searchInput
                        anchors.left: searchIcon.right
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true

                        text: launcher.query
                        onTextChanged: launcher.query = text
                        color: Config.Appearance.ink
                        font.family: Config.Appearance.fontFamily
                        font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize)
                        selectByMouse: true
                        selectionColor: Config.Appearance.accent
                        selectedTextColor: Config.Appearance.onAccent

                        Keys.onEscapePressed: {
                            if (launcher.query !== "") { launcher.query = ""; text = ""; }
                            else if (launcher.showAll) launcher.showAll = false;
                            else launcher.close();
                        }
                        Keys.onReturnPressed: launcher.runSelection()
                        Keys.onEnterPressed: launcher.runSelection()
                        Keys.onDownPressed: launcher.moveSelection(launcher.showingList ? 1 : 4)
                        Keys.onUpPressed: launcher.moveSelection(launcher.showingList ? -1 : -4)
                        Keys.onLeftPressed: event => {
                            if (launcher.showingList) { event.accepted = false; return; }
                            launcher.moveSelection(-1);
                        }
                        Keys.onRightPressed: event => {
                            if (launcher.showingList) { event.accepted = false; return; }
                            launcher.moveSelection(1);
                        }
                        Keys.onTabPressed: launcher.moveSelection(1)

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            visible: searchInput.text === ""
                            // Picker mode says so plainly, because the
                            // launcher otherwise looks exactly like it does
                            // when it is going to start what you click.
                            text: Config.UiState.appPickerFor !== ""
                                  ? "Choose an application for this dock slot"
                                  : "Search apps and commands"
                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize)
                            font.weight: Font.Normal
                            color: Config.Appearance.ink3
                        }
                    }
                }

                Rectangle {
                    id: escChip
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: escLabel.implicitWidth + 16
                    height: 26
                    radius: Config.Appearance.rSm
                    color: escHover.hovered ? Config.Appearance.sel : Config.Appearance.hover

                    StyledText {
                        id: escLabel
                        anchors.centerIn: parent
                        text: "ESC"
                        font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize - 1)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink3
                    }

                    HoverHandler { id: escHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: launcher.close() }
                }
            }

            // ── pinned grid ───────────────────────────────────────────────
            Column {
                width: parent.width
                visible: !launcher.showingList

                // Section header
                Item {
                    width: parent.width
                    height: 32

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 2
                            color: Config.Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Pinned"
                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 0.85
                            color: Config.Appearance.ink2
                        }
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: allRow.implicitWidth + 20
                        height: 25
                        radius: Config.Appearance.rSm
                        color: allHover.hovered ? Config.Appearance.accent : Config.Appearance.hover
                        Behavior on color { ColorAnimation { duration: 140 } }

                        Row {
                            id: allRow
                            anchors.centerIn: parent
                            spacing: 6
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "All apps"
                                font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                                font.weight: Font.DemiBold
                                color: allHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink2
                            }
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevronRight"
                                size: 12
                                inkColor: allHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink2
                                monochrome: true
                            }
                        }

                        HoverHandler { id: allHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: launcher.showAll = true }
                    }
                }

                Grid {
                    x: 10
                    width: parent.width - 20
                    columns: launcher.gridColumns
                    spacing: 2

                    Repeater {
                        model: launcher.pageItems

                        Item {
                            id: gridItem
                            required property var modelData
                            required property int index

                            readonly property bool selected: launcher.selectedIndex === index

                            width: (parent.width
                                    - parent.spacing * (launcher.gridColumns - 1))
                                   / launcher.gridColumns
                            height: launcher.gridTile

                            Rectangle {
                                anchors.fill: parent
                                radius: Config.Appearance.rSm
                                color: gridItem.selected || gridHover.hovered
                                       ? Config.Appearance.sel : "transparent"
                                border.width: gridItem.selected ? 1 : 0
                                border.color: Config.Appearance.seam
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: 6

                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    // Follows the icon-size setting, with the
                                    // plate sized around it.
                                    width: Math.round(launcher.gridIcon * 1.15)
                                    height: width
                                    radius: Config.Appearance.rSm
                                    color: Config.Appearance.hover

                                    MonoIcon {
                                        anchors.centerIn: parent
                                        name: gridItem.modelData.icon
                                        size: Math.round(launcher.gridIcon * 0.62)
                                        inkColor: Config.Appearance.ink
                                        accentColor: Config.Appearance.accent
                                    }
                                }

                                StyledText {
                                    width: gridItem.width - 8
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    text: gridItem.modelData.label
                                    font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                                }
                            }

                            HoverHandler {
                                id: gridHover
                                cursorShape: Qt.PointingHandCursor
                                onHoveredChanged: if (hovered) launcher.selectedIndex = gridItem.index;
                            }
                            TapHandler { onTapped: launcher.run(gridItem.modelData) }
                            // Right-clicking a pinned tile here opens the same
                            // menu the dock's tiles use, so a slot can be
                            // re-pointed or unpinned from either place.
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    if (gridItem.modelData.kind !== "app") return;
                                    const p = gridItem.mapToItem(null,
                                                  gridItem.width / 2, 0);
                                    Config.UiState.openAppMenu(
                                        p.x, p.y, gridItem.modelData.key, "",
                                        gridItem.modelData.label,
                                        gridItem.modelData.icon);
                                }
                            }
                        }
                    }
                }

                // Page dots
                Item {
                    width: parent.width
                    height: launcher.pageCount > 1 ? 20 : 8

                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        visible: launcher.pageCount > 1

                        Repeater {
                            model: launcher.pageCount

                            Rectangle {
                                required property int index
                                width: launcher.page === index ? 16 : 5
                                height: 5
                                radius: 3
                                color: launcher.page === index
                                       ? Config.Appearance.accent : Config.Appearance.div
                                Behavior on width { NumberAnimation { duration: 160 } }

                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: { launcher.page = index; launcher.selectedIndex = 0; }
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

                // Recommended
                Column {
                    width: parent.width
                    visible: launcher.recentItems.length > 0

                    Item {
                        width: parent.width
                        height: 32

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 14
                                height: 2
                                color: Config.Appearance.accent
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Recommended"
                                font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                                font.weight: Font.DemiBold
                                font.capitalization: Font.AllUppercase
                                font.letterSpacing: 0.85
                                color: Config.Appearance.ink2
                            }
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: "recent"
                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                            color: Config.Appearance.ink3
                        }
                    }

                    Grid {
                        x: 10
                        width: parent.width - 20
                        columns: 2
                        spacing: 1
                        bottomPadding: 6

                        Repeater {
                            model: launcher.recentItems

                            Item {
                                id: recentItem
                                required property var modelData

                                width: (parent.width - parent.spacing) / 2
                                height: 36

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Config.Appearance.rSm
                                    color: recentHover.hovered ? Config.Appearance.sel : "transparent"
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                }

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 7
                                    anchors.right: parent.right
                                    anchors.rightMargin: 7
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 22
                                        height: 22
                                        radius: Config.Appearance.rSm
                                        color: Config.Appearance.hover
                                        border.width: 1
                                        border.color: Config.Appearance.rule

                                        MonoIcon {
                                            anchors.centerIn: parent
                                            name: launcher.iconForFile(recentItem.modelData.name)
                                            size: 12
                                            inkColor: Config.Appearance.ink2
                                            accentColor: Config.Appearance.accent
                                        }
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 30
                                        spacing: 1

                                        StyledText {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: recentItem.modelData.name
                                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                                        }
                                        StyledText {
                                            width: parent.width
                                            elide: Text.ElideRight
                                            text: launcher.relativeTime(recentItem.modelData.modified)
                                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize - 1)
                                            font.weight: Font.Normal
                                            color: Config.Appearance.ink3
                                        }
                                    }
                                }

                                HoverHandler { id: recentHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: {
                                        Quickshell.execDetached(
                                            ["xdg-open", recentItem.modelData.path]);
                                        launcher.close();
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── results list ──────────────────────────────────────────────
            Column {
                width: parent.width
                visible: launcher.showingList

                Item {
                    width: parent.width
                    height: 40

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: launcher.listTitle
                        font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize)
                        font.weight: Font.DemiBold
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: launcher.showAll && !launcher.searching
                        width: backRow.implicitWidth + 22
                        height: 28
                        radius: Config.Appearance.rSm
                        color: backHover.hovered ? Config.Appearance.sel : Config.Appearance.hover

                        Row {
                            id: backRow
                            anchors.centerIn: parent
                            spacing: 7
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevronLeft"
                                size: 13
                                inkColor: Config.Appearance.ink2
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Back to pinned"
                                font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                                font.weight: Font.DemiBold
                                color: Config.Appearance.ink2
                            }
                        }

                        HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: launcher.showAll = false }
                    }
                }

                ListView {
                    id: results
                    x: 8
                    width: parent.width - 16
                    // Grows with the panel: a taller launcher should show more
                    // results, not the same nine with empty space under them.
                    // 356 was a fixed cap that made the height setting look
                    // like it did nothing while searching.
                    height: Math.min(Math.max(140, launcher.panelHeight - 204),
                                     Math.max(64, contentHeight))
                    clip: true
                    spacing: 1
                    boundsBehavior: Flickable.StopAtBounds
                    model: launcher.appResults
                    currentIndex: launcher.selectedIndex
                    highlightMoveDuration: 120
                    // Keep the keyboard selection in view as it moves.
                    highlightRangeMode: ListView.ApplyRange
                    preferredHighlightBegin: 40
                    preferredHighlightEnd: height - 40

                    delegate: Item {
                        id: resultRow
                        required property var modelData
                        required property int index

                        readonly property bool selected: launcher.selectedIndex === index

                        width: results.width
                        height: 43

                        Rectangle {
                            anchors.fill: parent
                            radius: Config.Appearance.rSm
                            color: resultRow.selected ? Config.Appearance.accent
                                 : (resultHover.hovered ? Config.Appearance.hover : "transparent")
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.right: hint.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 11

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 27
                                height: 27
                                radius: Config.Appearance.rSm
                                color: resultRow.selected
                                       ? Qt.rgba(1, 1, 1, 0.22) : Config.Appearance.hover

                                // Real theme icon for installed apps, pack
                                // glyph for the shell's own commands.
                                IconImage {
                                    anchors.centerIn: parent
                                    width: 15
                                    height: 15
                                    visible: source !== ""
                                    source: resultRow.modelData.appIcon || ""
                                }

                                MonoIcon {
                                    anchors.centerIn: parent
                                    visible: (resultRow.modelData.appIcon || "") === ""
                                    name: resultRow.modelData.icon || "square"
                                    size: 14
                                    inkColor: resultRow.selected
                                              ? Config.Appearance.onAccent : Config.Appearance.ink
                                    accentColor: resultRow.selected
                                                 ? Config.Appearance.onAccent : Config.Appearance.accent
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 38
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: resultRow.modelData.label
                                    font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize - 1)
                                    font.weight: Font.DemiBold
                                    color: resultRow.selected
                                           ? Config.Appearance.onAccent : Config.Appearance.ink
                                }
                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: resultRow.modelData.cat || ""
                                    font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize - 1)
                                    font.weight: Font.Normal
                                    opacity: resultRow.selected ? 0.8 : 1
                                    color: resultRow.selected
                                           ? Config.Appearance.onAccent : Config.Appearance.ink3
                                }
                            }
                        }

                        StyledText {
                            id: hint
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: resultRow.selected ? "return" : ""
                            font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherMetaSize)
                            font.weight: Font.DemiBold
                            color: Config.Appearance.onAccent
                        }

                        HoverHandler {
                            id: resultHover
                            cursorShape: Qt.PointingHandCursor
                            onHoveredChanged: if (hovered) launcher.selectedIndex = resultRow.index;
                        }
                        TapHandler { onTapped: launcher.run(resultRow.modelData) }
                    }
                }

                // Empty state — what the mockup promises when nothing matches.
                StyledText {
                    visible: launcher.appResults.length === 0
                    width: parent.width
                    leftPadding: 16
                    rightPadding: 16
                    topPadding: 14
                    bottomPadding: 22
                    wrapMode: Text.WordWrap
                    text: "No matches — press enter to run \u201C" + launcher.query.trim()
                          + "\u201D as a command"
                    font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize)
                    color: Config.Appearance.ink3
                }
            }

            // ── footer ────────────────────────────────────────────────────
            Rectangle {
                width: parent.width
                height: 40
                color: Config.Appearance.hover

                Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

                Rectangle {
                    anchors.left: parent.left
                    anchors.leftMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    width: userRow.implicitWidth + 14
                    height: 30
                    radius: Config.Appearance.rSm
                    color: userHover.hovered ? Config.Appearance.sel : "transparent"

                    Row {
                        id: userRow
                        anchors.left: parent.left
                        anchors.leftMargin: 3
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 9

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 21
                            height: 21
                            radius: 11
                            color: Config.Appearance.accent

                            MonoIcon {
                                anchors.centerIn: parent
                                name: "user"
                                size: 11
                                inkColor: Config.Appearance.onAccent
                                monochrome: true
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            StyledText {
                                text: Services.SysInfo.user
                                font.pixelSize: Config.Appearance.fs(Config.Appearance.launcherTitleSize - 1)
                                font.weight: Font.DemiBold
                            }
                            Rectangle {
                                width: parent.width
                                height: 2
                                color: Config.Appearance.accent
                            }
                        }
                    }

                    HoverHandler { id: userHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { launcher.close(); Config.UiState.togglePower(); } }
                }

                // Power shortcut, mirroring the bar's own.
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: Config.Appearance.rSm
                    color: powerHover.hovered ? Config.Appearance.accent : "transparent"

                    MonoIcon {
                        anchors.centerIn: parent
                        name: "power"
                        size: 15
                        inkColor: powerHover.hovered
                                  ? Config.Appearance.onAccent : Config.Appearance.ink2
                        monochrome: true
                    }

                    HoverHandler { id: powerHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { launcher.close(); Config.UiState.togglePower(); } }
                }
            }
        }
    }

    // ── keyboard navigation ───────────────────────────────────────────────
    function moveSelection(delta) {
        const count = showingList ? appResults.length : pageItems.length;
        if (count === 0) return;
        let next = selectedIndex + delta;

        if (!showingList) {
            // Stepping off the end of a page turns to the next one.
            if (next < 0 && page > 0) {
                page--;
                next = Math.max(0, pageItems.length + next);
            } else if (next >= count && page < pageCount - 1) {
                page++;
                next = Math.min(pageItems.length - 1, next - count);
            }
        }
        selectedIndex = Math.max(0, Math.min(count - 1, next));
    }
}
