import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services

// Minimising and bringing back, drawn: a picture of the window
// (dock/WindowThumb.qml — hyprland-toplevel-export, so it comes out whole
// even from the hidden workspace minimised windows are kept on) shrinks
// into the app's dock tile, and grows back out of it.
//
// The window itself moves at the right moment (Compositor.minimiseNow /
// restoreNow): away once the picture covers it, back as the picture lands
// where it will be. Built only while there's one to draw (shell.qml).
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: fx
        required property var modelData
        screen: modelData ?? null

        readonly property var job: Services.Compositor.minAnim
        readonly property bool mine: !!job && !!modelData && job.screen === modelData.name
        visible: mine
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        WlrLayershell.namespace: "quickshell:minimize"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        // Where it goes: its dock tile, or the bottom of the screen.
        readonly property point spot: {
            if (!mine) return Qt.point(0, 0);
            const d = Config.UiState.docks[fx.job.screen];
            const p = d && d.spotFor ? d.spotFor(fx.job.cls) : null;
            return p ? p : Qt.point(fx.width / 2, fx.height - 24);
        }
        // 0 the window as it is, 1 in its tile.
        property real t: 0
        readonly property real e: t * t * (3 - 2 * t)
        readonly property real endW: 46
        readonly property real endH: mine ? Math.max(20, Math.min(46, 46 * job.h / Math.max(1, job.w))) : 30

        Item {
            id: pic
            visible: fx.mine
            x: fx.mine ? fx.job.x + (fx.spot.x - fx.endW / 2 - fx.job.x) * fx.e : 0
            // A little ahead on the way down, as if drawn in.
            y: fx.mine ? fx.job.y + (fx.spot.y - fx.endH / 2 - fx.job.y) * Math.pow(fx.e, 0.85) : 0
            width: fx.mine ? fx.job.w + (fx.endW - fx.job.w) * fx.e : 0
            height: fx.mine ? fx.job.h + (fx.endH - fx.job.h) * fx.e : 0
            opacity: 1 - 0.75 * fx.e * fx.e

            Loader {
                id: shot
                anchors.fill: parent
                active: fx.mine
                source: "../dock/WindowThumb.qml"
                onLoaded: { item.live = false; item.toplevel = fx.job.toplevel; }
            }
            Rectangle {
                anchors.fill: parent
                visible: !shot.item || !shot.item.ready
                radius: Config.Appearance.rWin
                color: Config.Appearance.sheet
                opacity: 0.85
            }
        }

        readonly property bool pictured: !!shot.item && shot.item.ready

        // Started once there's a picture, or after a moment without one.
        property bool started: false
        onPicturedChanged: if (pictured) fx.go()
        onMineChanged: {
            fx.started = false;
            if (!mine) return;
            fx.t = job.kind === "restore" ? 1 : 0;
            noPicture.restart();
        }
        Component.onCompleted: if (mine) { fx.t = job.kind === "restore" ? 1 : 0; noPicture.restart(); }
        Timer { id: noPicture; interval: 220; onTriggered: fx.go() }

        function go() {
            if (!fx.mine || fx.started) return;
            fx.started = true;
            noPicture.stop();
            if (fx.job.kind === "min") {
                // The picture covers it: the window goes, the picture shrinks.
                Services.Compositor.minimiseNow(fx.job.address);
                anim.from = 0; anim.to = 1;
            } else {
                anim.from = 1; anim.to = 0;
            }
            anim.restart();
        }
        NumberAnimation {
            id: anim
            target: fx
            property: "t"
            duration: 300
            easing.type: Easing.InOutCubic
            onFinished: {
                if (!fx.mine) return;
                const j = fx.job;
                if (j.kind === "restore") {
                    // Landed where the window will be: it comes back under
                    // the picture, which lets go a moment later.
                    Services.Compositor.restoreNow(j.address);
                    letGo.restart();
                } else Services.Compositor.minAnim = null;
            }
        }
        Timer { id: letGo; interval: 90; onTriggered: Services.Compositor.minAnim = null }
    }
}
