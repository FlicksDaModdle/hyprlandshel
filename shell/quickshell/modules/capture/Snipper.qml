import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The frozen screen: Super+Shift+S, the capture toolbar's Region and
// Window, and Text from screen (services/Capture.qml).
//
// Every output was captured the moment the key went down; each gets a
// full-screen surface showing its own still picture, dimmed, and the
// choosing happens over that — so a menu that would close, a video that
// would move on or a tooltip that would vanish all hold still, the way
// Windows' Snipping Tool does it. A toolbar at the top switches what is
// being chosen:
//
//   Rectangle   drag out an area; it is taken on release
//   Window      the window under the pointer lights up; click to take it
//   Screen      the whole screen under the pointer; click to take it
//
// The part chosen is cut from the still picture at full resolution — not
// captured again — saved, and put on the clipboard. Esc or a right click
// puts everything back as it was.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win
        required property var modelData

        readonly property var cap: Services.Capture
        readonly property var ap: Config.Appearance
        readonly property string file: cap.snip && modelData ? cap.fileFor(modelData) : ""
        readonly property bool focusedHere: Services.Compositor.isFocusedScreen(modelData)
        readonly property string mode: cap.snipMode

        screen: modelData ?? null
        visible: file !== ""
        color: "black"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "quickshell:snip"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: focusedHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Physical pixels per logical one, from the picture itself, so a
        // fractional scale comes out exact.
        readonly property real ratio: still.sourceSize.width > 0 && width > 0 ? still.sourceSize.width / width : 1

        // ── what is being chosen ─────────────────────────────────────────
        property bool dragging: false
        property real ax: 0
        property real ay: 0
        property real px: -1
        property real py: -1
        property bool taking: false
        // The rectangle shown: dragged out, or the window or screen under
        // the pointer. Width 0 when there is none.
        readonly property rect pick: {
            if (mode === "screen") return px >= 0 ? Qt.rect(0, 0, width, height) : Qt.rect(0, 0, 0, 0);
            if (mode === "window") return px >= 0 ? windowAt(px, py) : Qt.rect(0, 0, 0, 0);
            if (!dragging) return Qt.rect(0, 0, 0, 0);
            return Qt.rect(Math.min(ax, px), Math.min(ay, py), Math.abs(px - ax), Math.abs(py - ay));
        }
        readonly property bool hasPick: pick.width >= 1 && pick.height >= 1

        onVisibleChanged: {
            dragging = false; taking = false; px = -1; py = -1;
            if (visible) {
                cap.snipShown(modelData ? modelData.name : "");
                cap.trace("overlay", modelData ? modelData.name : "?", width + "x" + height, "picture",
                          still.sourceSize.width + "x" + still.sourceSize.height, "ratio", ratio.toFixed(3));
                keys.forceActiveFocus(); bar.shown = false; barIn.restart();
            }
        }
        Timer { id: barIn; interval: 16; onTriggered: bar.shown = true }

        // The windows on this screen, in its own coordinates, smallest
        // first, so a dialog over its parent wins.
        readonly property var boxes: {
            const C = Services.Compositor;
            const s = modelData;
            if (!s) return [];
            const mon = (C.monitors || []).find(m => m.name === s.name);
            const ws = mon && mon.activeWorkspace ? mon.activeWorkspace.id : C.focusedId;
            return (C.clients || [])
                .filter(c => c.w > 0 && c.h > 0 && (c.workspace === ws || c.pinned))
                .map(c => Qt.rect(c.x - s.x, c.y - s.y, c.w, c.h))
                .filter(r => r.x + r.width > 0 && r.y + r.height > 0 && r.x < win.width && r.y < win.height)
                .sort((a, b) => a.width * a.height - b.width * b.height);
        }
        function windowAt(x, y) {
            for (const r of boxes) {
                if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height) {
                    const x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
                    return Qt.rect(x0, y0, Math.min(win.width, r.x + r.width) - x0, Math.min(win.height, r.y + r.height) - y0);
                }
            }
            return Qt.rect(0, 0, 0, 0);
        }

        // The pointer let go: take what is chosen. The choice is copied
        // first — `pick` read later is the live property, and it empties
        // the moment dragging stops.
        function finish() {
            const r = Qt.rect(pick.x, pick.y, pick.width, pick.height);
            if (mode === "region") {
                dragging = false;
                if (r.width >= 3 && r.height >= 3) take(r);
                else cap.trace("too small to take", r.width + "x" + r.height);
            } else if (hasPick) take(r);
        }

        // Cut `r` (logical) out of the still picture and save it.
        function take(r) {
            cap.trace("take asked", Math.round(r.x) + "," + Math.round(r.y), Math.round(r.width) + "x" + Math.round(r.height), "ratio", ratio);
            if (taking || r.width < 2 || r.height < 2) { cap.trace("take ignored", taking, r.width + "x" + r.height); return; }
            try { cut(r); }
            catch (e) { cap.trace("take failed", e); cap.snipFailed("Could not cut the picture: " + e); }
        }
        // The choice in the picture's own pixels, kept inside it: rounding
        // each edge at a fractional scale could otherwise ask for a pixel
        // past the last one.
        function pixels(r) {
            const W = still.sourceSize.width, H = still.sourceSize.height;
            const x0 = Math.max(0, Math.min(W - 1, Math.round(r.x * ratio)));
            const y0 = Math.max(0, Math.min(H - 1, Math.round(r.y * ratio)));
            const x1 = Math.max(x0 + 1, Math.min(W, Math.round((r.x + r.width) * ratio)));
            const y1 = Math.max(y0 + 1, Math.min(H, Math.round((r.y + r.height) * ratio)));
            return Qt.rect(x0, y0, x1 - x0, y1 - y0);
        }
        function cut(r) {
            if (cutImg.status !== Image.Ready || still.sourceSize.width <= 0) {
                win.cap.trace("cut: picture not ready", cutImg.status, still.status);
                win.cap.snipFailed("The frozen screen wasn't ready yet — try again");
                return;
            }
            taking = true;
            const pr = pixels(r);
            cutBox.width = pr.width;
            cutBox.height = pr.height;
            cutImg.x = -pr.x;
            cutImg.y = -pr.y;
            cap.trace("take", Math.round(r.x) + "," + Math.round(r.y), Math.round(r.width) + "x" + Math.round(r.height),
                      "-> pixels", pr.x + "," + pr.y, pr.width + "x" + pr.height);
            cutWatch.restart();
            // A frame for the new geometry, then the grab.
            Qt.callLater(() => {
                const target = win.cap.snipTarget();
                const ok = cutBox.grabToImage(res => {
                    win.cap.trace("grabbed", res.image ? "image" : "nothing", "saving to", target);
                    cutWatch.stop();
                    if (res.saveToFile(target)) win.cap.snipSaved(target);
                    else win.cap.snipFailed("Could not write " + target);
                }, Qt.size(pr.width, pr.height));
                win.cap.trace("grab started", ok);
                if (!ok) { cutWatch.stop(); win.cap.snipFailed("Could not cut the picture"); }
            });
        }
        // A cut that never comes back must not leave the screen frozen.
        Timer {
            id: cutWatch
            interval: 4000
            onTriggered: if (win.taking) win.cap.snipFailed("The picture could not be cut out (timed out)")
        }

        // The cut: the same picture — the same decoded pixels, from Qt's
        // cache, not read from disk again — at one item unit to a pixel,
        // shifted so the choice sits at the corner of a box its size, and
        // grabbed from there. Behind everything; never seen.
        Item {
            id: cutBox
            z: -10
            clip: true
            width: 1
            height: 1
            Image {
                id: cutImg
                source: still.source
                asynchronous: false
                cache: true
                smooth: false
                width: still.sourceSize.width
                height: still.sourceSize.height
            }
        }

        // ── the still picture ────────────────────────────────────────────
        Image {
            id: still
            anchors.fill: parent
            source: win.file !== "" ? "file://" + win.file : ""
            asynchronous: false
            // Cached, so the cut below reuses these pixels instead of
            // reading the file again (each freeze has its own file name).
            cache: true
            smooth: true
            fillMode: Image.Stretch
        }

        // Dimmed everywhere but the choice.
        readonly property color shade: Qt.rgba(0, 0, 0, 0.42)
        Rectangle { visible: !win.hasPick; anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.3) }
        Rectangle { visible: win.hasPick; x: 0; y: 0; width: parent.width; height: win.pick.y; color: win.shade }
        Rectangle { visible: win.hasPick; x: 0; y: win.pick.y + win.pick.height; width: parent.width; height: parent.height - y; color: win.shade }
        Rectangle { visible: win.hasPick; x: 0; y: win.pick.y; width: win.pick.x; height: win.pick.height; color: win.shade }
        Rectangle { visible: win.hasPick; x: win.pick.x + win.pick.width; y: win.pick.y; width: parent.width - x; height: win.pick.height; color: win.shade }

        // The choice: a hairline in the accent, with a soft outer glow so
        // it reads over light and dark alike.
        Rectangle {
            visible: win.hasPick
            x: hx.value
            y: hy.value
            width: hw.value
            height: hh.value
            color: "transparent"
            radius: win.mode === "region" ? 2 : 0
            border.width: 2
            border.color: win.ap.accent
            // Dragging out a region it follows the pointer exactly; picking
            // a window or a screen it glides from one to the next.
            Spring { id: hx; to: win.pick.x - 1; response: 240; bounce: 0.5; enabled: win.mode !== "region" }
            Spring { id: hy; to: win.pick.y - 1; response: 240; bounce: 0.5; enabled: win.mode !== "region" }
            Spring { id: hw; to: win.pick.width + 2; response: 240; bounce: 0.5; enabled: win.mode !== "region" }
            Spring { id: hh; to: win.pick.height + 2; response: 240; bounce: 0.5; enabled: win.mode !== "region" }
        }
        // Its size, in real pixels, beside it.
        Rectangle {
            visible: win.hasPick && win.mode === "region"
            readonly property bool below: win.pick.y + win.pick.height + height + 10 < win.height
            x: Math.max(6, Math.min(win.width - width - 6, win.pick.x))
            y: below ? win.pick.y + win.pick.height + 8 : Math.max(6, win.pick.y - height - 8)
            width: sizeText.implicitWidth + 16
            height: 24
            radius: 12
            color: Qt.rgba(0, 0, 0, 0.7)
            StyledText {
                id: sizeText
                anchors.centerIn: parent
                text: Math.round(win.pick.width * win.ratio) + " × " + Math.round(win.pick.height * win.ratio)
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: "white"
            }
        }
        // Crosshair guides while nothing is dragged yet.
        Rectangle {
            visible: win.mode === "region" && !win.dragging && win.px >= 0
            x: win.px; y: 0; width: 1; height: parent.height
            color: Qt.rgba(1, 1, 1, 0.35)
        }
        Rectangle {
            visible: win.mode === "region" && !win.dragging && win.px >= 0
            x: 0; y: win.py; width: parent.width; height: 1
            color: Qt.rgba(1, 1, 1, 0.35)
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: win.mode === "region" ? Qt.CrossCursor : Qt.PointingHandCursor
            onPositionChanged: mouse => { win.px = mouse.x; win.py = mouse.y; }
            onExited: if (!win.dragging) { win.px = -1; win.py = -1; }
            onPressed: mouse => {
                win.cap.trace("press", "button", mouse.button, "buttons", mouse.buttons, Math.round(mouse.x) + "," + Math.round(mouse.y), "mode", win.mode);
                if (mouse.button === Qt.RightButton) { win.cap.cancelSnip("right click"); return; }
                win.px = mouse.x; win.py = mouse.y;
                if (win.mode === "region") { win.ax = mouse.x; win.ay = mouse.y; win.dragging = true; }
            }
            onReleased: mouse => {
                win.cap.trace("release", "button", mouse.button, "buttons", mouse.buttons, Math.round(mouse.x) + "," + Math.round(mouse.y),
                              "pick", Math.round(win.pick.width) + "x" + Math.round(win.pick.height));
                // Only a right click (handled on press) is not a choice. A
                // trackpad's tap-and-drag can report another button, or none,
                // on release, so anything else that ends a drag takes it.
                if (mouse.button !== Qt.RightButton) win.finish();
            }
        }

        // ── the toolbar ──────────────────────────────────────────────────
        Rectangle {
            id: bar
            property bool shown: false
            anchors.horizontalCenter: parent.horizontalCenter
            y: 18
            width: barRow.implicitWidth + 12
            height: 48
            radius: 24
            color: win.ap.sheet
            border.width: 1
            border.color: win.ap.edge
            visible: win.focusedHere || barHover.hovered
            opacity: opacitySpring.value
            scale: scaleSpring.value
            transformOrigin: Item.Top
            Spring { id: opacitySpring; to: bar.shown ? 1 : 0; response: 140; bounce: 0 }
            Spring { id: scaleSpring; to: bar.shown ? 1 : 0.9; response: 340 }
            HoverHandler { id: barHover }

            Row {
                id: barRow
                anchors.centerIn: parent
                spacing: 4

                Repeater {
                    model: [
                        { m: "region", icon: "crop", label: "Rectangle", key: "R" },
                        { m: "window", icon: "square", label: "Window", key: "W" },
                        { m: "screen", icon: "monitor", label: "Screen", key: "S" }
                    ]
                    Rectangle {
                        id: modeBtn
                        required property var modelData
                        readonly property bool on: win.mode === modelData.m
                        width: modeRow.implicitWidth + 24
                        height: 36
                        radius: 18
                        color: tint1.value
                        ColorSpring { id: tint1; to: modeBtn.on ? win.ap.accent : (modeHover.hovered ? win.ap.sel : "transparent") }
                        scale: scaleSpring2.value
                        Spring { id: scaleSpring2; to: modeTap.pressed ? 0.92 : 1; response: 260 }
                        Row {
                            id: modeRow
                            anchors.centerIn: parent
                            spacing: 7
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: modeBtn.modelData.icon
                                size: 16
                                monochrome: true
                                inkColor: modeBtn.on ? win.ap.inkOnAccent : win.ap.ink
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modeBtn.modelData.label
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                color: modeBtn.on ? win.ap.inkOnAccent : win.ap.ink
                            }
                        }
                        HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { id: modeTap; onTapped: win.cap.snipMode = modeBtn.modelData.m }
                    }
                }

                Rectangle { width: 1; height: 24; anchors.verticalCenter: parent.verticalCenter; color: win.ap.rule }

                Rectangle {
                    id: closeBtn
                    width: 36; height: 36; radius: 18
                    color: closeHover.hovered ? win.ap.sel : "transparent"
                    MonoIcon { anchors.centerIn: parent; name: "x"; size: 16; monochrome: true; inkColor: win.ap.ink2 }
                    HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: win.cap.cancelSnip("close button") }
                }
            }
        }
        // What to do, under the toolbar, in a word.
        StyledText {
            visible: win.focusedHere
            anchors.horizontalCenter: parent.horizontalCenter
            y: bar.y + bar.height + 10
            opacity: bar.opacity * 0.9
            text: (win.cap.snip && win.cap.snip.kind === "ocr" ? "Text: " : "")
                  + (win.mode === "region" ? "Drag over what you want"
                    : win.mode === "window" ? "Click a window" : "Click a screen")
                  + " · Esc to cancel"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: "white"
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.5)
        }

        Item {
            id: keys
            focus: true
            Keys.onEscapePressed: win.cap.cancelSnip("Esc")
            Keys.onPressed: event => {
                if (event.key === Qt.Key_R) win.cap.snipMode = "region";
                else if (event.key === Qt.Key_W) win.cap.snipMode = "window";
                else if (event.key === Qt.Key_S) win.cap.snipMode = "screen";
                else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && win.mode === "screen")
                    win.take(Qt.rect(0, 0, win.width, win.height));
                else return;
                event.accepted = true;
            }
        }
    }
}
