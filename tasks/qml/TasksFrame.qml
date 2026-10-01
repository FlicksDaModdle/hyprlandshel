import QtQuick
import Hyprshell
import Hyprshell.Backend
import "Diagnose.js" as Diagnose

// The task manager's chrome: title bar with search, the side rail of views,
// and the view itself.
PanelSurface {
    id: frame

    required property var host

    showSeam: false
    showEdge: false
    radius: 0
    color: Appearance.sheet

    // Overlays every view can use: the context menu and the toast.
    property alias menu: contextMenu
    property alias toast: toastItem

    readonly property var mainViews: [
        { id: "summary",     label: "Summary",       icon: "layoutDashboard" },
        { id: "processes",   label: "Processes",     icon: "list" },
        { id: "performance", label: "Performance",   icon: "cpu" },
        { id: "history",     label: "App history",   icon: "rotateCw" },
        { id: "startup",     label: "Startup apps",  icon: "power" },
        { id: "users",       label: "Users",         icon: "user" },
        { id: "services",    label: "Services",      icon: "grid" },
        { id: "sysinfo",     label: "System info",   icon: "info" }
    ]
    readonly property var moreViews: [
        { id: "power",       label: "Power & frequency", icon: "zap" },
        { id: "connections", label: "Connections",   icon: "globe" },
        { id: "installed",   label: "Installed apps",icon: "package" },
        { id: "drivers",     label: "Drivers",       icon: "shield" },
        { id: "diskspace",   label: "Disk space",    icon: "disk" },
        { id: "benchmarks",  label: "Benchmarks",    icon: "play" },
        { id: "recorder",    label: "Flight recorder", icon: "film" }
    ]
    readonly property var allViews: mainViews.concat(moreViews).concat([{ id: "settings", label: "Settings", icon: "settings" }])
    readonly property var viewFiles: ({
        summary: "SummaryView.qml", processes: "ProcessesView.qml", performance: "PerformanceView.qml",
        history: "HistoryView.qml", startup: "StartupView.qml", users: "UsersView.qml",
        services: "ServicesView.qml", sysinfo: "SysInfoView.qml", power: "PowerView.qml",
        connections: "ConnectionsView.qml", installed: "InstalledView.qml", drivers: "DriversView.qml",
        diskspace: "DiskSpaceView.qml", benchmarks: "BenchmarksView.qml", recorder: "RecorderView.qml",
        settings: "SettingsView.qml"
    })
    // Which views the search box applies to, and what it searches there.
    readonly property var searchHints: ({
        processes: "Search by name, PID, user or command", services: "Search services",
        startup: "Search startup apps", installed: "Search installed apps",
        connections: "Search by process, address or port", drivers: "Search devices and modules",
        history: "Search apps", users: "Search users"
    })
    readonly property bool searchable: frame.searchHints[Tasks.view] !== undefined

    focus: true
    Keys.onPressed: event => {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (ctrl && event.key === Qt.Key_F && frame.searchable) { search.focusIn(); event.accepted = true; return; }
        if (ctrl && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const v = frame.allViews[event.key - Qt.Key_1];
            if (v) Tasks.view = v.id;
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_F5) { Monitor.refresh(); event.accepted = true; return; }
        // Typing anywhere searches, as it does in Windows' Task Manager.
        if (frame.searchable && !ctrl && event.text.length === 1 && event.text.trim() !== "" && event.key !== Qt.Key_Delete) {
            search.focusIn();
            search.text = event.text;
            Tasks.search = event.text;
            event.accepted = true;
        }
    }

    // ── title bar ─────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 46

        MouseArea {
            anchors.fill: parent
            property real pressX: 0
            property real pressY: 0
            property bool moving: false
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moving = false; }
            onPositionChanged: mouse => {
                if (!pressed || moving) return;
                if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4) return;
                moving = true;
                frame.host.startSystemMove();
            }
            onDoubleClicked: frame.host.toggleMaximised()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 16; radius: 2
                color: frame.host.active ? Appearance.accent : Appearance.ink3
            }
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "cpu"
                size: 20
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Task Manager"
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: (frame.allViews.find(v => v.id === Tasks.view) || {}).label || ""
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }
        }

        SearchField {
            id: search
            visible: frame.searchable
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 520)
            placeholder: frame.searchHints[Tasks.view] || "Search"
            onEdited: t => Tasks.search = t
        }
        Connections {
            target: Tasks
            function onViewChanged() { search.text = ""; Tasks.search = ""; }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            // Pause: the numbers hold still to be read.
            ToolButton {
                anchors.verticalCenter: parent.verticalCenter
                icon: Monitor.paused ? "play" : "pause"
                checked: Monitor.paused
                onClicked: Monitor.paused = !Monitor.paused
            }
            Item { width: 8; height: 1 }
            Repeater {
                model: [
                    { glyph: "minus",  danger: false, act: () => frame.host.minimise() },
                    { glyph: "square", danger: false, act: () => frame.host.toggleMaximised() },
                    { glyph: "x",      danger: true,  act: () => frame.host.close() }
                ]
                Rectangle {
                    id: winBtn
                    required property var modelData
                    width: 30; height: 30
                    radius: Appearance.rSm
                    color: !btnArea.containsMouse ? "transparent" : (modelData.danger ? Appearance.accent : Appearance.hover)
                    MonoIcon {
                        anchors.centerIn: parent
                        name: winBtn.modelData.glyph
                        size: 17
                        inkColor: btnArea.containsMouse && winBtn.modelData.danger ? Appearance.inkOnAccent : Appearance.ink2
                        monochrome: true
                    }
                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: winBtn.modelData.act()
                    }
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── side rail ─────────────────────────────────────────────────────────
    Item {
        id: rail
        anchors.left: parent.left
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        width: Tasks.settings.navCollapsed ? 58 : 214
        clip: true
        Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        SmoothScroll { target: railFlick; anchors.fill: railFlick; z: 5 }
        Flickable {
            id: railFlick
            anchors.fill: parent
            anchors.bottomMargin: 46
            contentHeight: railCol.implicitHeight + 16
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            Column {
                id: railCol
                y: 8
                width: rail.width
                Repeater {
                    model: frame.mainViews
                    NavRow {
                        required property var modelData
                        width: railCol.width
                        viewId: modelData.id
                        icon: modelData.icon
                        label: modelData.label
                        collapsed: Tasks.settings.navCollapsed
                        badge: modelData.id === "summary" && summaryBadge.count > 0 ? String(summaryBadge.count) : ""
                        onPicked: Tasks.view = modelData.id
                    }
                }
                Item {
                    width: railCol.width
                    height: 30
                    StyledText {
                        visible: !Tasks.settings.navCollapsed
                        x: 22
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 6
                        text: "MORE"
                        font.pixelSize: Appearance.fs(10.5)
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1
                        color: Appearance.ink3
                    }
                    Rectangle {
                        visible: Tasks.settings.navCollapsed
                        anchors.centerIn: parent
                        width: 24; height: 1
                        color: Appearance.rule
                    }
                }
                Repeater {
                    model: frame.moreViews
                    NavRow {
                        required property var modelData
                        width: railCol.width
                        viewId: modelData.id
                        icon: modelData.icon
                        label: modelData.label
                        collapsed: Tasks.settings.navCollapsed
                        onPicked: Tasks.view = modelData.id
                    }
                }
            }
        }
        Column {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            width: parent.width
            NavRow {
                width: parent.width
                viewId: "settings"
                icon: "settings"
                label: "Settings"
                collapsed: Tasks.settings.navCollapsed
                onPicked: Tasks.view = "settings"
            }
        }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Appearance.rule }
    }
    // Folds the rail to its glyphs.
    MouseArea {
        anchors.left: rail.right
        anchors.leftMargin: -3
        anchors.top: rail.top
        anchors.bottom: rail.bottom
        width: 6
        cursorShape: Qt.SizeHorCursor
        onClicked: Tasks.set("navCollapsed", !Tasks.settings.navCollapsed)
    }

    // The Summary's count of things worth a look, on its rail entry.
    QtObject {
        id: summaryBadge
        readonly property int count: Diagnose.findings(Monitor, Monitor.processes).filter(f => f.level >= 2).length
    }

    // ── the view ──────────────────────────────────────────────────────────
    Loader {
        id: viewLoader
        anchors.left: rail.right
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        source: frame.viewFiles[Tasks.view] || ""
        asynchronous: false
        onLoaded: if (item && item.frame !== undefined) item.frame = frame
    }

    // ── overlays ──────────────────────────────────────────────────────────
    ContextMenu { id: contextMenu }
    Toast {
        id: toastItem
        anchors.horizontalCenter: viewLoader.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
    }
}
