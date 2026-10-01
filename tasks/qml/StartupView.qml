import QtQuick
import Hyprshell
import Hyprshell.Backend

// What starts when you log in: XDG autostart entries, yours and the
// system's, with how much each costs at login.
Item {
    id: view
    property var frame: null
    property var entries: []
    property var impact: ({})          // unit -> cpu seconds
    property bool autostartActive: true

    function load() {
        view.entries = Tools.startupEntries();
        impactProc.running = false;
        impactProc.running = true;
        targetProc.running = false;
        targetProc.running = true;
    }
    Component.onCompleted: load()

    // How much processor each one used getting started, from systemd, which
    // runs autostart entries as app-NAME@autostart.service.
    Proc {
        id: impactProc
        command: ["systemctl", "--user", "show", "--no-pager", "app-*@autostart.service", "--property=Id,CPUUsageNSec"]
        onFinished: (code, out) => {
            const m = {};
            let id = "";
            for (const line of out.split("\n")) {
                if (line.startsWith("Id=")) id = line.slice(3);
                else if (line.startsWith("CPUUsageNSec=") && id) {
                    const v = parseFloat(line.slice(13));
                    if (!isNaN(v) && v < 1e18) m[id] = v / 1e9;
                }
            }
            view.impact = m;
        }
    }
    Proc {
        id: targetProc
        command: ["systemctl", "--user", "is-active", "xdg-desktop-autostart.target"]
        onFinished: (code, out) => view.autostartActive = out.trim() === "active"
    }

    function impactOf(e) {
        const s = view.impact[e.unit];
        if (s === undefined) return { label: e.enabled && e.thisDesktop ? "Not measured" : "", v: -1 };
        return { label: s >= 3 ? "High" : s >= 1 ? "Medium" : "Low", v: s };
    }
    readonly property var shown: view.entries.filter(e => Tasks.search === ""
        || (e.name + " " + e.exec).toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0)

    function toggle(e) {
        if (Tools.setAutostart(e.id, !e.enabled)) {
            view.frame.toast.show(e.name + (e.enabled ? " won't start at login." : " will start at login."), false);
            view.load();
        } else view.frame.toast.show("Couldn't change " + e.name + ".", true);
    }
    function menuFor(e) {
        return [
            { n: e.enabled ? "Disable" : "Enable", icon: "power", run: () => view.toggle(e) },
            { n: "Open file location", icon: "folderOpen", run: () => Tools.showInFolder(e.path) },
            { n: "Remove", icon: "x", active: !e.system, run: () => { Tools.removeAutostart(e.id); view.load(); } },
            { n: "Search online", icon: "globe", rule: true, run: () => Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent(e.name + " autostart linux")) }
        ];
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Startup apps"
        subtitle: view.entries.filter(e => e.enabled && e.thisDesktop).length + " start when you log in"
        ToolButton { anchors.verticalCenter: parent.verticalCenter; icon: "plus"; text: "Add"; onClicked: addDialog.open = true }
        ToolButton {
            anchors.verticalCenter: parent.verticalCenter
            icon: "power"
            text: table.selected && table.selected.enabled ? "Disable" : "Enable"
            active: !!table.selected
            onClicked: view.toggle(table.selected)
        }
    }
    Card {
        id: notice
        visible: !view.autostartActive
        anchors.top: head.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 16
        anchors.topMargin: 4
        height: visible ? noticeText.implicitHeight + 24 : 0
        border.color: Appearance.accent
        StyledText {
            id: noticeText
            x: 14; y: 12
            width: parent.width - 28
            wrapMode: Text.WordWrap
            text: "Hyprland isn't running these at login yet: systemd's xdg-desktop-autostart.target isn't active in this session. "
                  + "Re-run shell/install.sh — the shell's hyprland.lua starts it — and log in again."
            font.pixelSize: Appearance.fs(12)
        }
    }
    Table {
        id: table
        anchors.top: notice.visible ? notice.bottom : head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "id"
        sortKey: "name"
        rows: view.shown
        emptyText: "Nothing starts at login."
        columns: [
            { k: "name", t: "Name", w: 240, glyph: e => Tasks.glyph(e.id + " " + e.name) },
            { k: "status", t: "Status", w: 130, fmt: e => !e.thisDesktop ? "Not for this desktop" : e.enabled ? "Enabled" : "Disabled",
              dim: e => !e.enabled || !e.thisDesktop },
            { k: "impact", t: "Startup impact", w: 120, fmt: e => view.impactOf(e).label, sort: e => view.impactOf(e).v },
            { k: "system", t: "From", w: 90, fmt: e => e.system ? "System" : "You" },
            { k: "exec", t: "Command" }
        ]
        onContextMenu: (e, x, y) => view.frame.menu.openAt(x, y, view.menuFor(e))
        onActivated: e => view.toggle(e)
    }

    Modal {
        id: addDialog
        anchors.fill: parent
        title: "Start an app at login"
        boxWidth: 460
        property var apps: open ? Tools.applications() : []
        property string q: ""
        Column {
            width: parent.width
            spacing: 10
            SearchField { width: parent.width; placeholder: "Find an app"; onEdited: t => addDialog.q = t }
            ListView {
                width: parent.width
                height: 320
                clip: true
                model: addDialog.apps.filter(a => addDialog.q === "" || a.name.toLowerCase().indexOf(addDialog.q.toLowerCase()) >= 0)
                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width
                    height: 32
                    radius: Appearance.rSm
                    color: ar.containsMouse ? Appearance.hover : "transparent"
                    MonoIcon { x: 8; anchors.verticalCenter: parent.verticalCenter; name: Tasks.glyph(modelData.id + " " + modelData.name); size: 15; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                    StyledText { x: 34; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 40; elide: Text.ElideRight; text: modelData.name; font.pixelSize: Appearance.fs(12) }
                    MouseArea {
                        id: ar
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (Tools.addAutostart(modelData.id)) view.frame.toast.show(modelData.name + " will start at login.", false);
                            addDialog.open = false;
                            view.load();
                        }
                    }
                }
            }
        }
    }
}
