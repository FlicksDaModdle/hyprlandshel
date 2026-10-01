import QtQuick
import Hyprshell
import Hyprshell.Backend

// What is installed: pacman's packages and Flatpak's apps, with their size
// and when they arrived.
Item {
    id: view
    property var frame: null
    property string show: "apps"
    property var packages: []
    property bool loading: true
    Component.onCompleted: Tools.loadPackages()
    Connections { target: Tools; function onPackagesLoaded(list) { view.packages = list; view.loading = false; } }

    readonly property var shown: view.packages.map(p => Object.assign({ key: p.source + ":" + (p.id || p.name) }, p)).filter(p =>
        (view.show === "all" || (view.show === "apps" ? p.app : p.explicit))
        && (Tasks.search === "" || (p.name + " " + (p.description || "")).toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0))
    readonly property real totalSize: view.shown.reduce((a, p) => a + (p.size || 0), 0)

    function uninstall(p) {
        if (p.source === "flatpak") Tools.openTerminal(["flatpak", "uninstall", p.id]);
        else Tools.openTerminal(["sh", "-c", "sudo pacman -Rns " + p.name + "; echo; read -p 'Press Enter to close' _"]);
    }
    function menuFor(p) {
        return [
            { n: "Uninstall…", icon: "trash", run: () => view.uninstall(p) },
            { n: "Homepage", icon: "globe", active: !!p.url, run: () => Qt.openUrlExternally(p.url) },
            { n: "Its files", icon: "folder", active: p.source === "pacman",
              run: () => Tools.openTerminal(["sh", "-c", "pacman -Ql " + p.name + " | less"]) },
            { n: "Copy name", icon: "file", rule: true, run: () => Tools.runDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "copy", p.name]) }
        ];
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Installed apps"
        subtitle: view.loading ? "Reading the package database…" : view.shown.length + " · " + Tasks.bytes(view.totalSize)
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "Apps", value: "apps" }, { label: "Installed by you", value: "explicit" }, { label: "Everything", value: "all" }]
            value: view.show
            onPicked: v => view.show = v
        }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; icon: "trash"; text: "Uninstall"; danger: true; active: !!table.selected; onClicked: view.uninstall(table.selected) }
    }
    Table {
        id: table
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "key"
        sortKey: "size"
        sortDesc: true
        loading: view.loading
        rows: view.shown
        emptyText: view.packages.length === 0 ? "No package manager found: this reads pacman and Flatpak." : "Nothing installed matches."
        columns: [
            { k: "name", t: "Name", w: 230, glyph: p => Tasks.glyph(p.name) },
            { k: "version", t: "Version", w: 140 },
            { k: "size", t: "Size", w: 96, num: true, fmt: p => Tasks.bytes(p.size) },
            { k: "source", t: "From", w: 80, fmt: p => p.source === "flatpak" ? "Flatpak" : p.explicit ? "pacman" : "dependency", dim: p => !p.explicit },
            { k: "installed", t: "Installed", w: 150, fmt: p => p.installed ? new Date(p.installed).toLocaleDateString(Qt.locale(), "yyyy-MM-dd") : "",
              sort: p => p.installed ? new Date(p.installed).getTime() : 0 },
            { k: "description", t: "Description" }
        ]
        onContextMenu: (p, x, y) => view.frame.menu.openAt(x, y, view.menuFor(p))
    }
}
