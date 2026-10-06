import QtQuick
import Quickshell
import Quickshell.Io
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// A screenshot, marked up: pen, arrow, box, highlighter, pixelate (for
// what should not be shared), text, and crop. Copy puts the result on the
// clipboard; Save writes it over the shot (Ctrl+S); Ctrl+Z undoes.
//
// Everything is kept as shapes in the image's own pixels and drawn twice:
// scaled to the window to look at, and at full size to save.
FloatingWindow {
    id: win

    required property string path
    readonly property string url: "file://" + path

    title: "Screenshot — " + path.replace(/^.*\//, "")
    color: Config.Appearance.ground
    implicitWidth: Math.max(760, Math.min(1400, img.sourceSize.width * 0.7 + 48))
    implicitHeight: Math.max(520, Math.min(940, img.sourceSize.height * 0.7 + 120))

    property string tool: "arrow"
    property color ink: Config.Appearance.accent
    property int weight: 4
    // [{ t: "pen"|"arrow"|"box"|"mark"|"pixel"|"text", pts or x,y,w,h, color, width, text }]
    property var shapes: []
    property var undone: []
    property var drawing: null
    // In image pixels; null is the whole picture.
    property var crop: null
    property bool saved: false
    property string status: ""

    readonly property real imgW: img.sourceSize.width
    readonly property real imgH: img.sourceSize.height
    readonly property real scale: imgW > 0 ? Math.min((stage.width - 32) / imgW, (stage.height - 32) / imgH, 1) : 1
    readonly property real offX: (stage.width - imgW * scale) / 2
    readonly property real offY: (stage.height - imgH * scale) / 2

    function close() { Config.UiState.shotEditorPath = ""; }
    function push(s) { shapes = shapes.concat([s]); undone = []; saved = false; view.requestPaint(); }
    function undo() {
        if (shapes.length === 0) return;
        undone = undone.concat([shapes[shapes.length - 1]]);
        shapes = shapes.slice(0, -1);
        view.requestPaint();
    }
    function redo() {
        if (undone.length === 0) return;
        shapes = shapes.concat([undone[undone.length - 1]]);
        undone = undone.slice(0, -1);
        view.requestPaint();
    }

    // ── drawing, at any scale ─────────────────────────────────────────────
    function paintShapes(ctx, k, ox, oy, list) {
        for (const s of list) {
            ctx.save();
            ctx.strokeStyle = s.color;
            ctx.fillStyle = s.color;
            ctx.lineWidth = s.width * k;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            const X = v => ox + v * k, Y = v => oy + v * k;
            if (s.t === "pen" && s.pts.length > 1) {
                ctx.beginPath();
                ctx.moveTo(X(s.pts[0][0]), Y(s.pts[0][1]));
                for (const p of s.pts) ctx.lineTo(X(p[0]), Y(p[1]));
                ctx.stroke();
            } else if (s.t === "arrow") {
                const x1 = X(s.x), y1 = Y(s.y), x2 = X(s.x + s.w), y2 = Y(s.y + s.h);
                const a = Math.atan2(y2 - y1, x2 - x1), head = Math.max(10, s.width * 3.5) * k;
                ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(x2, y2);
                ctx.lineTo(x2 - head * Math.cos(a - 0.45), y2 - head * Math.sin(a - 0.45));
                ctx.lineTo(x2 - head * Math.cos(a + 0.45), y2 - head * Math.sin(a + 0.45));
                ctx.closePath(); ctx.fill();
            } else if (s.t === "box") {
                ctx.strokeRect(X(Math.min(s.x, s.x + s.w)), Y(Math.min(s.y, s.y + s.h)), Math.abs(s.w) * k, Math.abs(s.h) * k);
            } else if (s.t === "mark") {
                ctx.globalAlpha = 0.35;
                ctx.fillRect(X(Math.min(s.x, s.x + s.w)), Y(Math.min(s.y, s.y + s.h)), Math.abs(s.w) * k, Math.abs(s.h) * k);
            } else if (s.t === "pixel") {
                pixelate(ctx, X(Math.min(s.x, s.x + s.w)), Y(Math.min(s.y, s.y + s.h)), Math.abs(s.w) * k, Math.abs(s.h) * k,
                         Math.max(4, Math.round(14 * k)));
            } else if (s.t === "text") {
                ctx.font = "600 " + Math.round(s.size * k) + "px sans-serif";
                ctx.textBaseline = "top";
                ctx.fillText(s.text, X(s.x), Y(s.y));
            }
            ctx.restore();
        }
    }
    // Blocks of the average colour of what is under them.
    function pixelate(ctx, x, y, w, h, block) {
        x = Math.round(x); y = Math.round(y); w = Math.round(w); h = Math.round(h);
        if (w < 2 || h < 2) return;
        const data = ctx.getImageData(x, y, w, h);
        const d = data.data;
        for (let by = 0; by < h; by += block) {
            for (let bx = 0; bx < w; bx += block) {
                let r = 0, g = 0, b = 0, n = 0;
                const bw = Math.min(block, w - bx), bh = Math.min(block, h - by);
                for (let j = 0; j < bh; j++) for (let i = 0; i < bw; i++) {
                    const o = ((by + j) * w + (bx + i)) * 4;
                    r += d[o]; g += d[o + 1]; b += d[o + 2]; n++;
                }
                ctx.fillStyle = Qt.rgba(r / n / 255, g / n / 255, b / n / 255, 1);
                ctx.fillRect(x + bx, y + by, bw, bh);
            }
        }
    }

    // ── saving ────────────────────────────────────────────────────────────
    // Drawn again at full size, cropped if asked, and written over the
    // shot (or to a copy for the clipboard).
    property string pendingSave: ""
    property bool copyAfter: false
    function save(alsoCopy) {
        copyAfter = !!alsoCopy;
        pendingSave = alsoCopy ? Quickshell.env("XDG_RUNTIME_DIR") + "/hyprshell-shot-copy.png" : path;
        out.width = crop ? Math.round(Math.abs(crop.w)) : imgW;
        out.height = crop ? Math.round(Math.abs(crop.h)) : imgH;
        out.requestPaint();
    }
    Canvas {
        id: out
        visible: false
        width: 1; height: 1
        renderStrategy: Canvas.Immediate
        onPaint: {
            if (win.pendingSave === "") return;
            const ctx = getContext("2d");
            const cx = win.crop ? Math.min(win.crop.x, win.crop.x + win.crop.w) : 0;
            const cy = win.crop ? Math.min(win.crop.y, win.crop.y + win.crop.h) : 0;
            ctx.clearRect(0, 0, width, height);
            ctx.drawImage(win.url, -cx, -cy, win.imgW, win.imgH);
            win.paintShapes(ctx, 1, -cx, -cy, win.shapes);
            const target = win.pendingSave;
            win.pendingSave = "";
            if (!save(target)) { win.status = "Could not write " + target; return; }
            if (win.copyAfter) {
                copyProc.command = ["sh", "-c", 'wl-copy --type image/png < "$1"', "copy", target];
                copyProc.running = true;
                win.status = "Copied to the clipboard";
            } else {
                win.saved = true;
                win.status = "Saved " + target.replace(/^.*\//, "");
                copyProc.command = ["sh", "-c", 'wl-copy --type image/png < "$1"', "copy", target];
                copyProc.running = true;
            }
        }
        Component.onCompleted: loadImage(win.url)
    }
    Process { id: copyProc }

    // ── chrome ────────────────────────────────────────────────────────────
    component Btn: Rectangle {
        id: b
        property string icon: ""
        property string label: ""
        property bool on: false
        property bool primary: false
        signal clicked
        width: label !== "" ? lbl.implicitWidth + (icon ? 40 : 24) : 34
        height: 34
        radius: Config.Appearance.rSm
        color: b.primary ? Config.Appearance.accent : b.on ? Config.Appearance.sel
             : (bh.hovered ? Config.Appearance.hover : "transparent")
        Row {
            anchors.centerIn: parent
            spacing: 6
            MonoIcon {
                visible: b.icon !== ""
                anchors.verticalCenter: parent.verticalCenter
                name: b.icon
                size: 16
                inkColor: b.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                accentColor: b.primary ? Config.Appearance.inkOnAccent : Config.Appearance.accent
            }
            StyledText {
                id: lbl
                visible: b.label !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: b.label
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: b.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
            }
        }
        HoverHandler { id: bh; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: b.clicked() }
    }

    Rectangle {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 52
        color: Config.Appearance.surface

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Repeater {
                model: [["pen", "pen", "Pen"], ["arrow", "arrowTool", "Arrow"], ["box", "square", "Box"],
                        ["mark", "highlighter", "Highlight"], ["pixel", "grid", "Pixelate"], ["text", "font", "Text"],
                        ["crop", "crop", "Crop"]]
                Btn {
                    required property var modelData
                    icon: modelData[1]
                    label: win.width > 1080 ? modelData[2] : ""
                    on: win.tool === modelData[0]
                    onClicked: win.tool = modelData[0]
                }
            }
            Rectangle { width: 1; height: 26; anchors.verticalCenter: parent.verticalCenter; color: Config.Appearance.rule }
            Item { width: 6; height: 1 }
            Repeater {
                model: [Config.Appearance.accent, "#e5484d", "#f5c518", "#30a46c", "#3e63dd", "#ffffff", "#111111"]
                Rectangle {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22; height: 22; radius: 11
                    color: modelData
                    border.width: Qt.colorEqual(win.ink, modelData) ? 3 : 1
                    border.color: Qt.colorEqual(win.ink, modelData) ? Config.Appearance.ink : Config.Appearance.edge
                    TapHandler { onTapped: win.ink = modelData }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
            }
            Item { width: 8; height: 1 }
            Repeater {
                model: [[2, "S"], [4, "M"], [8, "L"]]
                Btn {
                    required property var modelData
                    width: 30
                    label: modelData[1]
                    on: win.weight === modelData[0]
                    onClicked: win.weight = modelData[0]
                }
            }
            Item { width: 6; height: 1 }
            Btn { icon: "rotateCw"; onClicked: win.undo(); rotation: 0; transform: Scale { origin.x: 17; xScale: -1 } }
            Btn { icon: "rotateCw"; onClicked: win.redo() }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: win.status
                font.pixelSize: Config.Appearance.fs(11.5)
                color: Config.Appearance.ink3
                rightPadding: 6
            }
            Btn { icon: "clipboard"; label: "Copy"; onClicked: win.save(true) }
            Btn { icon: "download"; label: "Save"; primary: true; onClicked: win.save(false) }
            Btn { icon: "x"; onClicked: win.close() }
        }
    }

    Item {
        id: stage
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: bar.bottom
        anchors.bottom: parent.bottom
        clip: true
        focus: true

        Keys.onPressed: event => {
            const ctrl = event.modifiers & Qt.ControlModifier;
            if (ctrl && event.key === Qt.Key_Z) { (event.modifiers & Qt.ShiftModifier) ? win.redo() : win.undo(); event.accepted = true; }
            else if (ctrl && event.key === Qt.Key_Y) { win.redo(); event.accepted = true; }
            else if (ctrl && event.key === Qt.Key_S) { win.save(false); event.accepted = true; }
            else if (ctrl && event.key === Qt.Key_C) { win.save(true); event.accepted = true; }
            else if (event.key === Qt.Key_Escape) { if (textField.visible) textField.visible = false; else win.close(); event.accepted = true; }
        }

        // Only to learn the picture's size.
        Image { id: img; visible: false; source: win.url; cache: false }

        Canvas {
            id: view
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                if (win.imgW <= 0) return;
                ctx.drawImage(win.url, win.offX, win.offY, win.imgW * win.scale, win.imgH * win.scale);
                const list = win.drawing ? win.shapes.concat([win.drawing]) : win.shapes;
                win.paintShapes(ctx, win.scale, win.offX, win.offY, list);
                // Outside the crop, dimmed.
                const c = win.drawing && win.drawing.t === "crop" ? win.drawing : win.crop;
                if (c) {
                    const x = win.offX + Math.min(c.x, c.x + c.w) * win.scale, y = win.offY + Math.min(c.y, c.y + c.h) * win.scale;
                    const w = Math.abs(c.w) * win.scale, h = Math.abs(c.h) * win.scale;
                    ctx.fillStyle = Qt.rgba(0, 0, 0, 0.5);
                    ctx.fillRect(win.offX, win.offY, win.imgW * win.scale, y - win.offY);
                    ctx.fillRect(win.offX, y + h, win.imgW * win.scale, win.offY + win.imgH * win.scale - y - h);
                    ctx.fillRect(win.offX, y, x - win.offX, h);
                    ctx.fillRect(x + w, y, win.offX + win.imgW * win.scale - x - w, h);
                    ctx.strokeStyle = "white"; ctx.lineWidth = 1;
                    ctx.strokeRect(x, y, w, h);
                }
            }
            Component.onCompleted: loadImage(win.url)
            onImageLoaded: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }
        Connections { target: img; function onStatusChanged() { view.requestPaint(); } }

        MouseArea {
            anchors.fill: parent
            cursorShape: win.tool === "text" ? Qt.IBeamCursor : Qt.CrossCursor
            function ix(m) { return (m.x - win.offX) / win.scale; }
            function iy(m) { return (m.y - win.offY) / win.scale; }
            onPressed: m => {
                stage.forceActiveFocus();
                const x = ix(m), y = iy(m);
                if (win.tool === "text") {
                    textField.ix = x; textField.iy = y;
                    textField.x = m.x; textField.y = m.y;
                    textField.text = "";
                    textField.visible = true;
                    textField.forceActiveFocus();
                    return;
                }
                if (win.tool === "pen") win.drawing = { t: "pen", pts: [[x, y]], color: String(win.ink), width: win.weight };
                else win.drawing = { t: win.tool, x: x, y: y, w: 0, h: 0, color: win.tool === "mark" && Qt.colorEqual(win.ink, Config.Appearance.accent) ? "#f5c518" : String(win.ink),
                                     width: win.tool === "mark" ? 0 : win.weight };
                view.requestPaint();
            }
            onPositionChanged: m => {
                if (!win.drawing) return;
                const d = Object.assign({}, win.drawing);
                if (d.t === "pen") d.pts = d.pts.concat([[ix(m), iy(m)]]);
                else { d.w = ix(m) - d.x; d.h = iy(m) - d.y; }
                win.drawing = d;
                view.requestPaint();
            }
            onReleased: {
                const d = win.drawing;
                win.drawing = null;
                if (!d) return;
                if (d.t === "crop") {
                    win.crop = Math.abs(d.w) > 4 && Math.abs(d.h) > 4 ? d : null;
                    view.requestPaint();
                    return;
                }
                if (d.t === "pen" ? d.pts.length > 1 : (Math.abs(d.w) > 2 || Math.abs(d.h) > 2)) win.push(d);
                else view.requestPaint();
            }
        }

        // Text: typed where it was clicked, placed on Enter.
        TextInput {
            id: textField
            property real ix: 0
            property real iy: 0
            visible: false
            color: win.ink
            font.pixelSize: Math.max(10, (14 + win.weight * 3) * win.scale)
            font.weight: Font.DemiBold
            width: Math.max(80, contentWidth + 4)
            onAccepted: commit()
            onActiveFocusChanged: if (!activeFocus && visible) commit()
            function commit() {
                const t = text.trim();
                visible = false;
                if (t !== "") win.push({ t: "text", x: ix, y: iy, text: t, color: String(win.ink), size: 14 + win.weight * 3, width: 1 });
                stage.forceActiveFocus();
            }
            Rectangle { anchors.fill: parent; anchors.margins: -3; color: "transparent"; border.color: Config.Appearance.accent; border.width: 1; z: -1 }
        }
    }
}
