import QtQuick
import QtQuick.Window
import Hyprshell
import Hyprshell.Backend

// The viewer: a title bar, the picture, a filmstrip of the folder, and an
// info panel.
//
// Looking:   ← →, Page Up/Down, Space and Backspace step through the folder;
//            Home and End go to the ends; the arrows at the sides and the
//            filmstrip do the same.
// Zooming:   the wheel, Ctrl+wheel, a pinch, + and −, 0 to fit, 1 for one
//            picture pixel per screen pixel; double-click to look closer or
//            to fit again. Zoomed in, drag (or two fingers) to move about.
// The rest:  R and Shift+R turn it (only on screen for now), F or F11 is
//            full screen, I the info panel, Ctrl+C copies the picture,
//            Delete moves it to the bin, Ctrl+O opens another.
Rectangle {
    id: root

    required property var host

    color: host.fullscreen ? "#0d0c0c" : Appearance.sheet
    Behavior on color { ColorAnimation { duration: 180 } }

    // ── the folder ───────────────────────────────────────────────────────
    property var files: []
    property int index: -1
    readonly property string current: index >= 0 && index < files.length ? files[index] : ""
    readonly property var currentInfo: current !== "" ? Gallery.info(current) : ({})
    readonly property string currentName: currentInfo.name || ""
    property bool infoOpen: false
    property real lastMove: 0

    function openPath(path) {
        if (!path) return;
        const list = Gallery.siblings(path);
        if (list.length === 0) { toast.say("No pictures there"); return; }
        files = list;
        const i = list.indexOf(path);
        show(i >= 0 ? i : 0, 0);
    }
    Component.onCompleted: {
        if (Gallery.startFiles.length > 1) { files = Gallery.startFiles.filter(f => Gallery.isImage(f)); show(0, 0); }
        else if (Gallery.startFiles.length === 1) openPath(Gallery.startFiles[0]);
    }
    Connections {
        target: Gallery
        function onPicked(path) { if (path) root.openPath(path); }
    }

    // ── two slots, crossfaded ────────────────────────────────────────────
    // The next picture loads into the slot not on show; once it is ready it
    // slides in over the old one, so stepping through a folder never shows
    // an empty frame between two pictures.
    property int front: 0
    readonly property var cur: front === 0 ? slotA : slotB
    readonly property var back: front === 0 ? slotB : slotA

    function show(i, dir) {
        if (files.length === 0) { index = -1; return; }
        i = Math.max(0, Math.min(files.length - 1, i));
        index = i;
        back.prepare();
        back.dir = dir;
        back.path = files[i];
    }
    function step(d) {
        if (files.length < 2) return;
        show((index + d + files.length) % files.length, d);
    }
    function swapIn(slot) {
        if (slot !== back) return;
        front = front === 0 ? 1 : 0;
        cur.enter();
        back.leave();
    }

    // How big a picture can be shown whole.
    function fitFor(slot) {
        const w = slot.rotated ? slot.natH : slot.natW;
        const h = slot.rotated ? slot.natW : slot.natH;
        if (w <= 0 || h <= 0) return 1;
        return Math.min(actual(), stage.width / w, stage.height / h);
    }
    // One picture pixel per screen pixel.
    function actual() { return 1 / Math.max(1, root.host.screen ? root.host.screen.devicePixelRatio : 1); }
    readonly property real zoomPercent: cur.mag / actual() * 100

    function zoomTo(z, sx, sy, glide) {
        const s = cur;
        const fit = fitFor(s);
        z = Math.max(fit, Math.min(actual() * 16, z));
        const cx = stage.width / 2, cy = stage.height / 2;
        const px = sx === undefined ? cx : sx, py = sy === undefined ? cy : sy;
        const k = z / s.mag;
        s.glide = !!glide;
        const nx = px - cx - (px - cx - s.panX) * k;
        const ny = py - cy - (py - cy - s.panY) * k;
        s.fitted = Math.abs(z - fit) < 1e-4;
        s.zoom = z;
        s.setPan(nx, ny);
    }
    function zoomBy(f, sx, sy, glide) { zoomTo(cur.mag * f, sx, sy, glide); }
    function fit() { cur.glide = true; cur.fitted = true; cur.setPan(0, 0); }
    function actualSize(sx, sy) { zoomTo(actual(), sx, sy, true); }
    function turn(d) { cur.glide = true; cur.rot += d; if (cur.fitted) cur.setPan(0, 0); }

    function trashCurrent() {
        if (current === "") return;
        const name = currentName;
        if (!Gallery.trash(current)) { toast.say("Couldn't move it to the bin"); return; }
        const list = files.slice();
        list.splice(index, 1);
        const at = Math.min(index, list.length - 1);
        files = list;
        if (list.length === 0) { index = -1; slotA.prepare(); slotB.prepare(); }
        else show(at, 1);
        toast.say("Moved “" + name + "” to the bin");
    }

    // ── keys ─────────────────────────────────────────────────────────────
    focus: true
    Keys.onPressed: event => {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        switch (event.key) {
        case Qt.Key_Right: case Qt.Key_PageDown: case Qt.Key_Space: case Qt.Key_Down:
            root.step(1); break;
        case Qt.Key_Left: case Qt.Key_PageUp: case Qt.Key_Backspace: case Qt.Key_Up:
            root.step(-1); break;
        case Qt.Key_Home: root.show(0, -1); break;
        case Qt.Key_End: root.show(root.files.length - 1, 1); break;
        case Qt.Key_Plus: case Qt.Key_Equal: root.zoomBy(1.25, undefined, undefined, true); break;
        case Qt.Key_Minus: root.zoomBy(0.8, undefined, undefined, true); break;
        case Qt.Key_0: root.fit(); break;
        case Qt.Key_1: root.actualSize(); break;
        case Qt.Key_R: root.turn(shift ? -90 : 90); break;
        case Qt.Key_F: case Qt.Key_F11: root.host.toggleFullscreen(); break;
        case Qt.Key_I: root.infoOpen = !root.infoOpen; break;
        case Qt.Key_Delete: root.trashCurrent(); break;
        case Qt.Key_Escape:
            if (root.host.fullscreen) root.host.toggleFullscreen();
            else if (!root.cur.fitted) root.fit();
            else root.host.close();
            break;
        case Qt.Key_C: if (ctrl && root.current) { if (Gallery.copyImage(root.current)) toast.say("Picture copied"); } else return; break;
        case Qt.Key_O: if (ctrl) Gallery.pick(root.current ? root.currentInfo.folder : ""); else return; break;
        case Qt.Key_W: case Qt.Key_Q: if (ctrl) root.host.close(); else return; break;
        default: return;
        }
        event.accepted = true;
    }

    // ── title bar ────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        y: root.host.fullscreen ? -height : 0
        height: 46
        z: 10
        Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

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
                root.host.startSystemMove();
            }
            onDoubleClicked: root.host.toggleMaximised()
        }

        Row {
            id: titleLeft
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: tools.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 16; radius: 2
                color: root.host.active ? Appearance.accent : Appearance.ink3
            }
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "image"; size: 20
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, titleLeft.width - 80)
                elide: Text.ElideMiddle
                text: root.current !== "" ? root.currentName : "Images"
                font.pixelSize: Appearance.fs(14)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.files.length > 1
                text: (root.index + 1) + " of " + root.files.length
                font.pixelSize: Appearance.fs(12)
                font.features: { "tnum": 1 }
                color: Appearance.ink3
            }
        }

        Row {
            id: tools
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            ToolButton { icon: "minus"; enabled: root.current !== ""; onClicked: root.zoomBy(0.8, undefined, undefined, true) }
            Rectangle {
                width: zoomText.implicitWidth + 18; height: 32
                anchors.verticalCenter: parent.verticalCenter
                radius: Appearance.rSm
                color: zoomArea.containsMouse ? Appearance.hover : "transparent"
                StyledText {
                    id: zoomText
                    anchors.centerIn: parent
                    text: root.current === "" ? "—" : root.cur.fitted ? "Fit" : Math.round(root.zoomPercent) + "%"
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: Appearance.ink2
                }
                MouseArea {
                    id: zoomArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cur.fitted ? root.actualSize() : root.fit()
                }
            }
            ToolButton { icon: "plus"; enabled: root.current !== ""; onClicked: root.zoomBy(1.25, undefined, undefined, true) }
            Item { width: 8; height: 1 }
            ToolButton { icon: "rotateCw"; mirrored: true; enabled: root.current !== ""; onClicked: root.turn(-90) }
            ToolButton { icon: "rotateCw"; enabled: root.current !== ""; onClicked: root.turn(90) }
            Item { width: 8; height: 1 }
            ToolButton { icon: "file"; enabled: root.current !== ""
                         onClicked: if (Gallery.copyImage(root.current)) toast.say("Picture copied") }
            ToolButton { icon: "folder"; enabled: root.current !== ""; onClicked: Gallery.showInFolder(root.current) }
            ToolButton { icon: "monitor"; enabled: root.current !== ""
                         onClicked: toast.say(Gallery.setWallpaper(root.current) ? "Set as the wallpaper" : "The shell isn't running") }
            ToolButton { icon: "info"; checked: root.infoOpen; enabled: root.current !== ""; onClicked: root.infoOpen = !root.infoOpen }
            ToolButton { icon: "trash"; danger: true; enabled: root.current !== ""; onClicked: root.trashCurrent() }
            Item { width: 8; height: 1 }
            ToolButton { icon: "eye"; onClicked: root.host.toggleFullscreen() }
            Item { width: 6; height: 1 }
            Repeater {
                model: [
                    { glyph: "minus",  danger: false, act: () => root.host.minimise() },
                    { glyph: "square", danger: false, act: () => root.host.toggleMaximised() },
                    { glyph: "x",      danger: true,  act: () => root.host.close() }
                ]
                ToolButton {
                    required property var modelData
                    icon: modelData.glyph
                    danger: modelData.danger
                    onClicked: modelData.act()
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    // ── the picture ──────────────────────────────────────────────────────
    Item {
        id: stage
        anchors.left: parent.left
        anchors.right: info.left
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        clip: true

        component Slot: Item {
            id: slot
            property string path: ""
            property int dir: 0
            property bool fitted: true
            property real zoom: 1
            property real panX: 0
            property real panY: 0
            property real rot: 0
            property bool glide: false
            property real slide: 0
            readonly property bool animated: path !== "" && !!Gallery.info(path).animated
            readonly property var pic: loader.item
            readonly property real natW: pic ? pic.implicitWidth : 0
            readonly property real natH: pic ? pic.implicitHeight : 0
            readonly property bool rotated: Math.round(rot / 90) % 2 !== 0
            readonly property bool ready: !!pic && pic.status === Image.Ready
            readonly property bool failed: !!pic && pic.status === Image.Error
            readonly property real mag: fitted ? root.fitFor(slot) : zoom

            anchors.fill: parent
            opacity: 0

            function reset() { glide = false; fitted = true; zoom = 1; panX = 0; panY = 0; rot = 0; }
            // Ready for the next picture: whatever it was doing is over,
            // and the old one is let go so the new one loads afresh.
            function prepare() { enterAnim.stop(); leaveAnim.stop(); opacity = 0; path = ""; reset(); }
            function setPan(x, y) {
                const w = (rotated ? natH : natW) * zoomTarget(), h = (rotated ? natW : natH) * zoomTarget();
                const mx = Math.max(0, (w - stage.width) / 2), my = Math.max(0, (h - stage.height) / 2);
                panX = Math.max(-mx, Math.min(mx, x));
                panY = Math.max(-my, Math.min(my, y));
            }
            function zoomTarget() { return fitted ? root.fitFor(slot) : zoom; }
            function enter() {
                leaveAnim.stop();
                slide = dir * 36;
                enterAnim.restart();
            }
            function leave() { enterAnim.stop(); leaveAnim.restart(); }
            onReadyChanged: if (ready && slot === root.back) root.swapIn(slot)
            onFailedChanged: if (failed && slot === root.back) root.swapIn(slot)

            ParallelAnimation {
                id: enterAnim
                NumberAnimation { target: slot; property: "opacity"; to: 1; duration: 140 }
                NumberAnimation { target: slot; property: "slide"; to: 0; duration: 420; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 0.9 }
            }
            ParallelAnimation {
                id: leaveAnim
                NumberAnimation { target: slot; property: "opacity"; to: 0; duration: 160 }
                NumberAnimation { target: slot; property: "slide"; to: -slot.dir * 24; duration: 200; easing.type: Easing.OutCubic }
                onFinished: { slot.path = ""; slot.reset(); }
            }

            Item {
                id: frame
                width: slot.natW * slot.mag
                height: slot.natH * slot.mag
                x: (slot.width - width) / 2 + slot.panX + slot.slide
                y: (slot.height - height) / 2 + slot.panY
                rotation: slot.rot
                Behavior on width { enabled: slot.glide; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on height { enabled: slot.glide; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on x { enabled: slot.glide; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on y { enabled: slot.glide; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on rotation { NumberAnimation { duration: 380; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 0.9 } }

                Loader {
                    id: loader
                    anchors.fill: parent
                    active: slot.path !== ""
                    sourceComponent: slot.animated ? moving : still
                }
                Component {
                    id: still
                    Image {
                        source: slot.path !== "" ? Gallery.fileUrl(slot.path) : ""
                        asynchronous: true
                        autoTransform: true
                        cache: false
                        smooth: true
                        mipmap: true
                        fillMode: Image.Stretch
                    }
                }
                Component {
                    id: moving
                    AnimatedImage {
                        source: slot.path !== "" ? Gallery.fileUrl(slot.path) : ""
                        asynchronous: true
                        cache: false
                        smooth: true
                        mipmap: true
                        playing: slot === root.cur
                        fillMode: Image.Stretch
                    }
                }
            }
        }

        Slot { id: slotA }
        Slot { id: slotB }

        StyledText {
            anchors.centerIn: parent
            visible: root.cur.failed
            text: "This picture can't be opened"
            font.pixelSize: Appearance.fs(14)
            color: Appearance.ink3
        }

        // Wheel to zoom, drag to move, double-click to look closer.
        MouseArea {
            id: surface
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: root.current === "" ? Qt.ArrowCursor
                       : root.cur.fitted ? Qt.ArrowCursor : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
            property real lx: 0
            property real ly: 0
            property real swipe: 0
            onPositionChanged: mouse => {
                root.lastMove = Date.now();
                if (!pressed) return;
                root.cur.glide = false;
                root.cur.setPan(root.cur.panX + mouse.x - lx, root.cur.panY + mouse.y - ly);
                lx = mouse.x; ly = mouse.y;
            }
            onPressed: mouse => { lx = mouse.x; ly = mouse.y; }
            onDoubleClicked: mouse => {
                if (root.current === "") { Gallery.pick(""); return; }
                if (root.cur.fitted) {
                    const fit = root.fitFor(root.cur);
                    root.zoomTo(fit < root.actual() * 0.999 ? root.actual() : fit * 2, mouse.x, mouse.y, true);
                } else root.fit();
            }
            onWheel: wheel => {
                if (root.current === "") return;
                const trackpad = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0;
                const ctrl = (wheel.modifiers & Qt.ControlModifier) !== 0;
                if (trackpad && !ctrl) {
                    // Two fingers move about a zoomed picture; on a whole
                    // one, a sideways swipe turns the page.
                    if (!root.cur.fitted) {
                        root.cur.glide = false;
                        root.cur.setPan(root.cur.panX + wheel.pixelDelta.x, root.cur.panY + wheel.pixelDelta.y);
                    } else {
                        swipe += wheel.pixelDelta.x;
                        if (Math.abs(swipe) > 140) { root.step(swipe > 0 ? -1 : 1); swipe = 0; }
                        if (wheel.phase === Qt.ScrollEnd) swipe = 0;
                    }
                    return;
                }
                const f = Math.pow(1.0018, wheel.angleDelta.y);
                root.zoomBy(f, wheel.x, wheel.y, !trackpad);
            }
        }
        PinchHandler {
            target: null
            property real last: 1
            onActiveChanged: last = 1
            onActiveScaleChanged: {
                if (root.current === "") return;
                root.zoomBy(activeScale / last, centroid.position.x, centroid.position.y, false);
                last = activeScale;
            }
        }
        DropArea {
            anchors.fill: parent
            onDropped: drop => {
                if (!drop.hasUrls) return;
                const u = drop.urls[0].toString();
                root.openPath(decodeURIComponent(u.replace(/^file:\/\//, "")));
            }
        }

        // ← and → at the sides, while the pointer is about.
        readonly property bool chromeShown: surface.containsMouse && Date.now() - root.lastMove < 2200
        Repeater {
            model: root.files.length > 1 ? [-1, 1] : []
            Rectangle {
                id: side
                required property int modelData
                anchors.verticalCenter: parent.verticalCenter
                x: modelData < 0 ? 16 : parent.width - width - 16
                width: 44; height: 44; radius: 22
                color: sideArea.containsMouse ? Qt.rgba(0, 0, 0, 0.55) : Qt.rgba(0, 0, 0, 0.35)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.12)
                opacity: sideArea.containsMouse || stage.chromeShown ? 1 : 0
                scale: sideArea.pressed ? 0.9 : 1
                Behavior on opacity { NumberAnimation { duration: 160 } }
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2 } }
                MonoIcon {
                    anchors.centerIn: parent
                    name: side.modelData < 0 ? "chevronLeft" : "chevronRight"
                    size: 20; monochrome: true
                    inkColor: "white"
                }
                MouseArea {
                    id: sideArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.step(side.modelData)
                }
            }
        }
        Timer { interval: 600; repeat: true; running: surface.containsMouse; onTriggered: root.lastMoveChanged() }

        // ── nothing open ─────────────────────────────────────────────────
        Column {
            anchors.centerIn: parent
            visible: root.current === ""
            spacing: 14
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 76; height: 76; radius: 38
                color: Appearance.hover
                MonoIcon { anchors.centerIn: parent; name: "image"; size: 34; inkColor: Appearance.ink2; accentColor: Appearance.accent }
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No picture open"
                font.pixelSize: Appearance.fs(17)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Open one, or drop it here"
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink3
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: openText.implicitWidth + 32; height: 36
                radius: 18
                color: openArea.containsMouse ? Qt.darker(Appearance.accent, 1.08) : Appearance.accent
                scale: openArea.pressed ? 0.94 : 1
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2 } }
                StyledText {
                    id: openText
                    anchors.centerIn: parent
                    text: "Open…"
                    font.pixelSize: Appearance.fs(13)
                    font.weight: Font.DemiBold
                    color: Appearance.inkOnAccent
                }
                MouseArea {
                    id: openArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Gallery.pick("")
                }
            }
        }

        // ── the filmstrip ────────────────────────────────────────────────
        Rectangle {
            id: strip
            readonly property bool wanted: root.files.length > 1
                && (!root.host.fullscreen || stripHover.hovered || stage.chromeShown)
            anchors.horizontalCenter: parent.horizontalCenter
            y: wanted ? parent.height - height - 14 : parent.height + 8
            width: Math.min(parent.width - 40, thumbs.contentWidth + 16)
            height: 68
            radius: 18
            color: root.host.fullscreen ? Qt.rgba(0.08, 0.08, 0.08, 0.8) : Appearance.dialog
            border.width: 1
            border.color: Appearance.edge
            Behavior on y { NumberAnimation { duration: 380; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 1.1 } }
            HoverHandler { id: stripHover }

            ListView {
                id: thumbs
                anchors.fill: parent
                anchors.margins: 8
                orientation: ListView.Horizontal
                spacing: 6
                clip: true
                model: root.files
                currentIndex: root.index
                highlightMoveDuration: 260
                preferredHighlightBegin: width / 2 - 26
                preferredHighlightEnd: width / 2 + 26
                highlightRangeMode: ListView.ApplyRange
                boundsBehavior: Flickable.StopAtBounds
                delegate: Rectangle {
                    id: thumb
                    required property string modelData
                    required property int index
                    readonly property bool on: index === root.index
                    width: 52; height: 52
                    radius: 10
                    color: Appearance.hover
                    border.width: on ? 2 : 0
                    border.color: Appearance.accent
                    scale: on ? 1 : (thumbArea.containsMouse ? 0.97 : 0.9)
                    opacity: on ? 1 : 0.75
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                    Image {
                        anchors.fill: parent
                        anchors.margins: thumb.on ? 3 : 0
                        source: Gallery.fileUrl(thumb.modelData)
                        sourceSize: Qt.size(104, 104)
                        asynchronous: true
                        autoTransform: true
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        layer.enabled: true
                        layer.smooth: true
                    }
                    MouseArea {
                        id: thumbArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.show(thumb.index, thumb.index > root.index ? 1 : -1)
                    }
                }
            }
        }
    }

    // ── info ─────────────────────────────────────────────────────────────
    Rectangle {
        id: info
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: root.infoOpen && root.current !== "" ? 280 : 0
        clip: true
        color: "transparent"
        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        Rectangle { width: 1; height: parent.height; color: Appearance.rule }

        Column {
            x: 20; y: 18
            width: 240
            spacing: 14
            StyledText {
                text: "Info"
                font.pixelSize: Appearance.fs(15)
                font.weight: Font.Bold
            }
            Repeater {
                model: {
                    const i = root.currentInfo;
                    if (!i.name) return [];
                    const kb = i.bytes / 1024;
                    const size = kb < 1024 ? Math.round(kb) + " KB" : (kb / 1024).toFixed(1) + " MB";
                    const mp = i.width * i.height / 1e6;
                    return [
                        { k: "Name", v: i.name },
                        { k: "Dimensions", v: i.width + " × " + i.height + (mp >= 0.1 ? "  ·  " + mp.toFixed(1) + " MP" : "") },
                        { k: "Size", v: size },
                        { k: "Type", v: (i.format || "?") + (i.animated ? ", animated" : "") },
                        { k: "Modified", v: Qt.formatDateTime(new Date(i.modified), "d MMM yyyy, HH:mm") },
                        { k: "Folder", v: i.folder, copy: true }
                    ];
                }
                Column {
                    id: row
                    required property var modelData
                    width: 240
                    spacing: 3
                    StyledText {
                        text: row.modelData.k
                        font.pixelSize: Appearance.fs(11)
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.6
                        color: Appearance.ink3
                    }
                    StyledText {
                        width: 240
                        wrapMode: Text.WrapAnywhere
                        text: row.modelData.v
                        font.pixelSize: Appearance.fs(13)
                        color: row.modelData.copy && copyArea.containsMouse ? Appearance.accent : Appearance.ink
                        MouseArea {
                            id: copyArea
                            anchors.fill: parent
                            enabled: !!row.modelData.copy
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { Gallery.copyText(root.current); toast.say("Path copied"); }
                        }
                    }
                }
            }
        }
    }

    // ── a word about what just happened ──────────────────────────────────
    Rectangle {
        id: toast
        property string text: ""
        function say(t) { text = t; shown = true; hide.restart(); }
        property bool shown: false
        anchors.horizontalCenter: stage.horizontalCenter
        y: shown ? root.height - height - (strip.wanted ? 96 : 24) : root.height + 10
        width: toastText.implicitWidth + 28
        height: 34
        radius: 17
        color: Appearance.dialog
        border.width: 1
        border.color: Appearance.edge
        z: 20
        Behavior on y { NumberAnimation { duration: 380; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 1.0 } }
        StyledText {
            id: toastText
            anchors.centerIn: parent
            text: toast.text
            font.pixelSize: Appearance.fs(12.5)
            font.weight: Font.DemiBold
        }
        Timer { id: hide; interval: 2200; onTriggered: toast.shown = false }
    }
}
