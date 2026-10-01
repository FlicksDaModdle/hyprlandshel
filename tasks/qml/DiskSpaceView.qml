import QtQuick
import Hyprshell
import Hyprshell.Backend

// Where the space went: each filesystem's fill, then what is taking room in
// any folder of it, as a map of rectangles sized by what they hold and a
// list beside it — click a folder to go into it.
Item {
    id: view
    property var frame: null

    readonly property var mounts: {
        const out = [];
        for (const d of Monitor.disks)
            for (const m of (d.mounts || []))
                if (!m.readOnly && m.total > 0) out.push(Object.assign({ disk: d.model }, m));
        return out;
    }
    property string path: ""
    property var entries: []        // [{ name, path, size }]
    property real total: 0
    property bool busy: false
    property var cache: ({})

    function analyze(p) {
        view.path = p;
        if (view.cache[p]) { view.entries = view.cache[p].entries; view.total = view.cache[p].total; return; }
        view.entries = [];
        view.busy = true;
        du.running = false;
        du.command = ["du", "-x", "-b", "-d", "1", "--", p];
        du.running = true;
    }
    function up() {
        if (view.path === "/" || view.path === "") { view.path = ""; return; }
        const parent = view.path.replace(/\/[^/]+\/?$/, "") || "/";
        view.analyze(parent);
    }
    Proc {
        id: du
        onFinished: (code, out) => {
            const list = [];
            let total = 0;
            for (const line of out.split("\n")) {
                const tab = line.indexOf("\t");
                if (tab < 0) continue;
                const size = parseFloat(line.slice(0, tab)), p = line.slice(tab + 1);
                if (p === view.path || p === view.path.replace(/\/$/, "")) { total = size; continue; }
                list.push({ name: p.slice(p.lastIndexOf("/") + 1), path: p, size: size });
            }
            list.sort((a, b) => b.size - a.size);
            const c = Object.assign({}, view.cache);
            c[view.path] = { entries: list, total: total };
            view.cache = c;
            view.entries = list;
            view.total = total;
            view.busy = false;
        }
    }

    // Squarified treemap: rows laid along the short side, each kept as
    // close to square as the sizes allow.
    function layout(items, x, y, w, h) {
        const out = [];
        let rest = items.filter(i => i.size > 0).slice(0, 60);
        const sum = rest.reduce((a, i) => a + i.size, 0);
        if (sum <= 0) return out;
        const scale = w * h / sum;
        let rx = x, ry = y, rw = w, rh = h;
        while (rest.length > 0) {
            const side = Math.min(rw, rh);
            let row = [], best = Infinity;
            for (let k = 0; k < rest.length; ++k) {
                const cand = rest.slice(0, k + 1);
                const area = cand.reduce((a, i) => a + i.size * scale, 0);
                const thick = area / side;
                const worst = Math.max(...cand.map(i => { const l = i.size * scale / thick; return Math.max(l / thick, thick / l); }));
                if (worst > best) break;
                best = worst;
                row = cand;
            }
            const area = row.reduce((a, i) => a + i.size * scale, 0);
            const thick = area / side;
            let off = 0;
            for (const i of row) {
                const len = i.size * scale / thick;
                if (rw >= rh) out.push(Object.assign({ x: rx, y: ry + off, w: thick, h: len }, i));
                else out.push(Object.assign({ x: rx + off, y: ry, w: len, h: thick }, i));
                off += len;
            }
            if (rw >= rh) { rx += thick; rw -= thick; } else { ry += thick; rh -= thick; }
            rest = rest.slice(row.length);
        }
        return out;
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Disk space"
        subtitle: view.path === "" ? "Each filesystem, and what fills it" : view.path + " · " + Tasks.bytes(view.total)
        ToolButton { anchors.verticalCenter: parent.verticalCenter; visible: view.path !== ""; icon: "chevronUp"; text: "Up"; onClicked: view.up() }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; visible: view.path !== ""; icon: "folderOpen"; text: "Open in Files"; onClicked: Tools.runDetached(["hyprshell-files", view.path]) }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; visible: view.path !== ""; icon: "rotateCw"; onClicked: { const c = Object.assign({}, view.cache); delete c[view.path]; view.cache = c; view.analyze(view.path); } }
    }

    // ── the filesystems ──
    Column {
        visible: view.path === ""
        anchors.top: head.bottom
        anchors.topMargin: 8
        x: 20
        width: parent.width - 40
        spacing: 10
        Repeater {
            model: view.mounts
            Card {
                required property var modelData
                width: parent.width
                height: 76
                readonly property real used: modelData.used / modelData.total
                border.color: used > 0.95 ? Appearance.accent : Appearance.rule
                MonoIcon { x: 14; y: 14; name: "disk"; size: 20; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                Column {
                    x: 46; y: 12
                    width: parent.width - 46 - 150
                    spacing: 6
                    Item {
                        width: parent.width
                        height: 18
                        StyledText { text: modelData.path + "   " + modelData.fs + " · " + modelData.disk; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold }
                        StyledText { anchors.right: parent.right; text: Tasks.bytes(modelData.free) + " free of " + Tasks.bytes(modelData.total); font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
                    }
                    Meter { width: parent.width; height: 10; value: parent.parent.used; fillColor: parent.parent.used > 0.95 ? Appearance.accent : Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, 0.7) }
                    StyledText { text: Tasks.pct(100 * parent.parent.used, 0) + " used"; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                }
                DialogButton {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Analyze"
                    primary: true
                    onTriggered: view.analyze(modelData.path)
                }
            }
        }
    }

    // ── a folder ──
    Item {
        visible: view.path !== ""
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        x: 20
        width: parent.width - 40

        Rectangle {
            id: mapArea
            width: parent.width * 0.6
            height: parent.height
            radius: 4
            color: Appearance.hover
            clip: true
            Repeater {
                model: view.busy ? [] : view.layout(view.entries, 0, 0, mapArea.width, mapArea.height)
                Rectangle {
                    required property var modelData
                    required property int index
                    x: modelData.x + 1; y: modelData.y + 1
                    width: Math.max(0, modelData.w - 2); height: Math.max(0, modelData.h - 2)
                    radius: 3
                    color: tileArea.containsMouse ? Appearance.accent
                         : Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, Math.max(0.12, 0.6 - index * 0.025))
                    StyledText {
                        anchors.fill: parent
                        anchors.margins: 6
                        visible: parent.width > 60 && parent.height > 34
                        wrapMode: Text.WrapAnywhere
                        elide: Text.ElideRight
                        text: modelData.name + "\n" + Tasks.bytes(modelData.size)
                        font.pixelSize: Appearance.fs(11)
                        color: tileArea.containsMouse ? Appearance.inkOnAccent : Appearance.ink
                    }
                    MouseArea {
                        id: tileArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.analyze(modelData.path)
                    }
                }
            }
            Column {
                anchors.centerIn: parent
                visible: view.busy
                spacing: 8
                StyledText { anchors.horizontalCenter: parent.horizontalCenter; text: "Adding up " + view.path + "…"; font.pixelSize: Appearance.fs(13); color: Appearance.ink2 }
                StyledText { anchors.horizontalCenter: parent.horizontalCenter; text: "A big folder takes a while the first time."; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
            }
        }
        Table {
            anchors.left: mapArea.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            keyField: "path"
            sortKey: "size"
            sortDesc: true
            loading: view.busy
            rows: view.entries
            emptyText: "Nothing in here."
            columns: [
                { k: "name", t: "Name", glyph: e => "folder" },
                { k: "size", t: "Size", w: 90, num: true, fmt: e => Tasks.bytes(e.size) },
                { k: "share", t: "Share", w: 64, num: true, fmt: e => view.total > 0 ? Tasks.pct(100 * e.size / view.total, 0) : "", sort: e => e.size }
            ]
            onActivated: e => view.analyze(e.path)
            onContextMenu: (e, x, y) => view.frame.menu.openAt(x, y, [
                { n: "Go into it", icon: "folderOpen", run: () => view.analyze(e.path) },
                { n: "Open in Files", icon: "folder", run: () => Tools.runDetached(["hyprshell-files", e.path]) }])
        }
    }
}
