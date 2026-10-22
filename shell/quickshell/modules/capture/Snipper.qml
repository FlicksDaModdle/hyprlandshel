import QtQuick
import QtQuick.Shapes
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
        readonly property string file: cap.snip && !cap.snip.copy && modelData ? cap.fileFor(modelData) : ""
        // Frozen in the shell (services/Capture.qml, freeze): this surface
        // maps at once, still see-through, copies its own output, and
        // shows the copy. Nothing is drawn on it before then, or the copy
        // would have the dimming in it.
        readonly property bool copying: !!(cap.snip && cap.snip.copy)
        readonly property bool ready: copying ? copy.hasContent : (file !== "" && still.status === Image.Ready)
        readonly property real picW: copying ? copy.sourceSize.width : still.sourceSize.width
        readonly property real picH: copying ? copy.sourceSize.height : still.sourceSize.height
        readonly property bool focusedHere: Services.Compositor.isFocusedScreen(modelData)
        readonly property string mode: cap.snipMode

        screen: modelData ?? null
        visible: file !== "" || copying
        color: ready ? "black" : "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "quickshell:snip"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: focusedHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Physical pixels per logical one, from the picture itself, so a
        // fractional scale comes out exact.
        readonly property real ratio: picW > 0 && width > 0 ? picW / width : 1

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
            if (visible) keys.forceActiveFocus();
            bar.shown = false;
        }
        onReadyChanged: {
            if (!ready || !visible) return;
            cap.snipShown(modelData ? modelData.name : "");
            cap.trace("overlay", modelData ? modelData.name : "?", width + "x" + height, "picture",
                      picW + "x" + picH, "ratio", ratio.toFixed(3), copying ? "(copied in the shell)" : "(grim)");
            keys.forceActiveFocus(); barIn.restart();
        }
        Timer { id: barIn; interval: 16; onTriggered: bar.shown = true }

        // The windows on this screen, in its own coordinates, smallest
        // first, so a dialog over its parent wins.
        readonly property var boxes: {
            const C = Services.Compositor;
            const s = modelData;
            // Nothing to pick from while it isn't up.
            if (!s || !win.visible) return [];
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
            const W = picW, H = picH;
            const x0 = Math.max(0, Math.min(W - 1, Math.round(r.x * ratio)));
            const y0 = Math.max(0, Math.min(H - 1, Math.round(r.y * ratio)));
            const x1 = Math.max(x0 + 1, Math.min(W, Math.round((r.x + r.width) * ratio)));
            const y1 = Math.max(y0 + 1, Math.min(H, Math.round((r.y + r.height) * ratio)));
            return Qt.rect(x0, y0, x1 - x0, y1 - y0);
        }
        function cut(r) {
            if (copying) { cutCopy(r); return; }
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
        // From the shell's own copy: the chosen part of it rendered at one
        // texel to a pixel of the copy (full resolution), and grabbed.
        function cutCopy(r) {
            if (!copy.hasContent || picW <= 0) {
                win.cap.snipFailed("The frozen screen wasn't ready yet — try again");
                return;
            }
            taking = true;
            const pr = pixels(r);
            cutSrc.sourceRect = Qt.rect(pr.x / ratio, pr.y / ratio, pr.width / ratio, pr.height / ratio);
            cutSrc.textureSize = Qt.size(pr.width, pr.height);
            cutSrc.width = pr.width / ratio;
            cutSrc.height = pr.height / ratio;
            cap.trace("take (copy)", "-> pixels", pr.x + "," + pr.y, pr.width + "x" + pr.height);
            cutWatch.restart();
            Qt.callLater(() => {
                const target = win.cap.snipTarget();
                const ok = cutSrc.grabToImage(res => {
                    cutWatch.stop();
                    if (res.saveToFile(target)) win.cap.snipSaved(target);
                    else win.cap.snipFailed("Could not write " + target);
                }, Qt.size(pr.width, pr.height));
                if (!ok) { cutWatch.stop(); win.cap.snipFailed("Could not cut the picture"); }
            });
        }
        ShaderEffectSource {
            id: cutSrc
            z: -10
            width: 1
            height: 1
            sourceItem: copy
            live: true
            hideSource: false
            smooth: false
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
        // The shell's own copy of this output, taken as the surface maps
        // (and let go of when it closes).
        ScreencopyView {
            id: copy
            anchors.fill: parent
            visible: win.copying && win.ready
            captureSource: win.copying && win.visible ? win.modelData : null
            live: false
            paintCursor: !!(win.cap.snip && win.cap.snip.pointer)
            // The compositor refused or ended the copy: grim, at once.
            onStopped: if (win.copying) win.cap.copyFailed()
        }
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

        // Nothing over the picture until there is one: the shell's copy is
        // of this very surface, and must not have the dimming in it.
        Item {
            id: stage
            anchors.fill: parent
            visible: win.ready

        // The choice as drawn: dragging out a region it follows the pointer
        // exactly; picking a window or a screen it glides from one to the
        // next. Rounded as what it is: a region softly, a window as the
        // shell rounds windows, a screen not at all.
        readonly property real cx: hx.value
        readonly property real cy: hy.value
        readonly property real cw: hw.value
        readonly property real ch: hh.value
        readonly property real cr: Math.max(0, Math.min(win.mode === "region" ? 12 : win.mode === "window" ? win.ap.rWin : 0,
                                                         cw / 2, ch / 2))
        Spring { id: hx; to: win.pick.x; response: 260; bounce: 0.35; enabled: win.mode !== "region" }
        Spring { id: hy; to: win.pick.y; response: 260; bounce: 0.35; enabled: win.mode !== "region" }
        Spring { id: hw; to: win.pick.width; response: 260; bounce: 0.35; enabled: win.mode !== "region" }
        Spring { id: hh; to: win.pick.height; response: 260; bounce: 0.35; enabled: win.mode !== "region" }

        // Dimmed everywhere but the choice: one shape, the screen with the
        // choice cut out of it, so the hole has the choice's round corners.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: win.hasPick ? Qt.rgba(0, 0, 0, 0.46) : Qt.rgba(0, 0, 0, 0.32)
                strokeWidth: -1
                fillRule: ShapePath.OddEvenFill
                PathSvg {
                    path: {
                        const W = stage.width, H = stage.height;
                        let d = "M0 0 H" + W + " V" + H + " H0 Z";
                        if (!win.hasPick) return d;
                        const x = stage.cx, y = stage.cy, w = stage.cw, h = stage.ch, r = stage.cr;
                        d += " M" + (x + r) + " " + y + " H" + (x + w - r)
                           + (r > 0 ? " A" + r + " " + r + " 0 0 1 " + (x + w) + " " + (y + r) : "")
                           + " V" + (y + h - r)
                           + (r > 0 ? " A" + r + " " + r + " 0 0 1 " + (x + w - r) + " " + (y + h) : "")
                           + " H" + (x + r)
                           + (r > 0 ? " A" + r + " " + r + " 0 0 1 " + x + " " + (y + h - r) : "")
                           + " V" + (y + r)
                           + (r > 0 ? " A" + r + " " + r + " 0 0 1 " + (x + r) + " " + y : "")
                           + " Z";
                        return d;
                    }
                }
            }
        }

        // Its edge: the accent, with a soft glow around it so it reads over
        // light and dark alike.
        Rectangle {
            visible: win.hasPick
            x: stage.cx - 4
            y: stage.cy - 4
            width: stage.cw + 8
            height: stage.ch + 8
            radius: stage.cr + 4
            color: "transparent"
            border.width: 4
            border.color: Qt.rgba(win.ap.accent.r, win.ap.accent.g, win.ap.accent.b, 0.22)
        }
        Rectangle {
            visible: win.hasPick
            x: stage.cx - 1
            y: stage.cy - 1
            width: stage.cw + 2
            height: stage.ch + 2
            radius: stage.cr + 1
            color: "transparent"
            border.width: 2
            border.color: win.ap.accent
        }
        // A region's corners: round handles.
        Repeater {
            model: win.hasPick && win.mode === "region" && stage.cw > 24 && stage.ch > 24 ? 4 : 0
            Rectangle {
                required property int index
                width: 12
                height: 12
                radius: 6
                x: (index % 2 === 0 ? stage.cx : stage.cx + stage.cw) - 6
                y: (index < 2 ? stage.cy : stage.cy + stage.ch) - 6
                color: "white"
                border.width: 2.5
                border.color: win.ap.accent
            }
        }

        // Its size, in real pixels, beside it: a rounded pill of the
        // shell's glass.
        Rectangle {
            visible: win.hasPick && win.mode === "region"
            readonly property bool below: win.pick.y + win.pick.height + height + 14 < win.height
            x: Math.max(8, Math.min(win.width - width - 8, win.pick.x + (win.pick.width - width) / 2))
            y: below ? win.pick.y + win.pick.height + 12 : Math.max(8, win.pick.y - height - 12)
            width: sizeRow.implicitWidth + 22
            height: 30
            radius: 15
            color: win.ap.sheet
            border.width: 1
            border.color: win.ap.edge
            Row {
                id: sizeRow
                anchors.centerIn: parent
                spacing: 7
                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "crop"
                    size: 13
                    monochrome: true
                    inkColor: win.ap.ink2
                }
                StyledText {
                    id: sizeText
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.round(win.pick.width * win.ratio) + " × " + Math.round(win.pick.height * win.ratio)
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: win.ap.ink
                }
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
        // A soft shadow under it.
        Rectangle {
            visible: bar.visible
            x: bar.x - 2
            y: bar.y + 4
            width: bar.width + 4
            height: bar.height + 4
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.28)
            opacity: bar.opacity
            scale: bar.scale
            transformOrigin: Item.Top
        }
        Rectangle {
            id: bar
            property bool shown: false
            anchors.horizontalCenter: parent.horizontalCenter
            y: 20
            width: barRow.implicitWidth + 16
            height: 54
            radius: height / 2
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

            // The highlight behind the mode in use, sliding to the next.
            Rectangle {
                id: slider
                readonly property Item at: {
                    for (let i = 0; i < modes.count; i++) {
                        const b = modes.itemAt(i);
                        if (b && b.on) return b;
                    }
                    return null;
                }
                visible: at !== null
                x: sx.value
                y: (bar.height - height) / 2
                width: sw.value
                height: 42
                radius: height / 2
                color: win.ap.accent
                Spring { id: sx; to: slider.at ? barRow.x + slider.at.x : 0; response: 300; bounce: 0.3 }
                Spring { id: sw; to: slider.at ? slider.at.width : 0; response: 300; bounce: 0.3 }
            }

            Row {
                id: barRow
                anchors.centerIn: parent
                spacing: 4

                Repeater {
                    id: modes
                    model: [
                        { m: "region", icon: "crop", label: "Rectangle", key: "R" },
                        { m: "window", icon: "square", label: "Window", key: "W" },
                        { m: "screen", icon: "monitor", label: "Screen", key: "S" }
                    ]
                    Rectangle {
                        id: modeBtn
                        required property var modelData
                        readonly property bool on: win.mode === modelData.m
                        width: modeRow.implicitWidth + 30
                        height: 42
                        radius: height / 2
                        color: tint1.value
                        // The accent is the slider's, behind; this only lights on hover.
                        ColorSpring { id: tint1; to: !modeBtn.on && modeHover.hovered ? win.ap.hover : "transparent" }
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

                Rectangle { width: 1; height: 26; anchors.verticalCenter: parent.verticalCenter; color: win.ap.rule }

                Rectangle {
                    id: closeBtn
                    width: 42; height: 42; radius: 21
                    color: closeHover.hovered ? win.ap.sel : "transparent"
                    MonoIcon { anchors.centerIn: parent; name: "x"; size: 16; monochrome: true; inkColor: win.ap.ink2 }
                    HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: win.cap.cancelSnip("close button") }
                }
            }
        }
        // What to do, under the toolbar, in a word.
        Rectangle {
            visible: win.focusedHere && !win.dragging
            anchors.horizontalCenter: parent.horizontalCenter
            y: bar.y + bar.height + 12
            width: hint.implicitWidth + 24
            height: 28
            radius: 14
            color: Qt.rgba(0, 0, 0, 0.5)
            opacity: bar.opacity
            StyledText {
                id: hint
                anchors.centerIn: parent
                text: (win.cap.snip && win.cap.snip.kind === "ocr" ? "Text: " : "")
                      + (win.mode === "region" ? "Drag over what you want"
                        : win.mode === "window" ? "Click a window" : "Click a screen")
                      + " · Esc to cancel"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: "white"
            }
        }

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
