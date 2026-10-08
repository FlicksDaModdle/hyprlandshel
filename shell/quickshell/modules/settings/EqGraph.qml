import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../../services/EqMath.js" as EqM
import "../common"

// The parametric equalizer's graph (Settings → Sound → Output): the
// frequency response on a log axis from 20 Hz to 20 kHz, each band's own
// shape in its colour under the sum, and a handle for each band.
//
//   drag a handle            frequency across, gain up and down (Shift: fine)
//   scroll on a handle       Q — narrower or wider
//   double-click a handle    its gain back to 0
//   right-click a handle     bypass it, or bring it back
//   double-click the graph   a new band there
//
// The curve is the one PipeWire applies (EqMath.js uses its formulas), with
// the preamp in it; anything above 0 dB would clip, and is shown so.
Item {
    id: root

    readonly property var fx: Services.AudioFx
    readonly property var ap: Config.Appearance
    property int selectedId: -1
    // ± dB the height covers.
    property real range: 12
    signal picked(int id)

    implicitHeight: 250

    // Each band's colour, by where it sits in the list: steady while it is
    // edited, distinct from its neighbours.
    readonly property var hues: ["#ff6a55", "#ffa94d", "#f2cc4d", "#6fd48c", "#4dc3e8", "#7d8cff", "#c07dff", "#ff79b0"]
    function colourOf(b) {
        const i = root.fx.bands.findIndex(x => x.id === b.id);
        return root.hues[(i < 0 ? 0 : i) % root.hues.length];
    }

    // ── geometry ──────────────────────────────────────────────────────────
    readonly property real padL: 34
    readonly property real padR: 10
    readonly property real padT: 10
    readonly property real padB: 22
    readonly property real plotW: width - padL - padR
    readonly property real plotH: height - padT - padB
    readonly property real lnMin: Math.log(EqM.F_MIN)
    readonly property real lnMax: Math.log(EqM.F_MAX)
    function xOf(f) { return padL + (Math.log(f) - lnMin) / (lnMax - lnMin) * plotW; }
    function fOf(x) { return Math.exp(lnMin + Math.max(0, Math.min(1, (x - padL) / plotW)) * (lnMax - lnMin)); }
    function yOf(db) { return padT + plotH / 2 - (db / root.range) * (plotH / 2); }
    function dbOf(y) { return -((y - padT - plotH / 2) / (plotH / 2)) * root.range; }

    // ── the picture ───────────────────────────────────────────────────────
    readonly property var freqs: EqM.logFreqs(Math.max(64, Math.round(plotW / 3)))
    readonly property string drawKey: JSON.stringify(root.fx.bands) + "|" + root.ap.eqPreamp + "|" + root.range + "|"
                                      + root.selectedId + "|" + width + "x" + height + "|" + root.ap.dark + root.ap.accent
    onDrawKeyChanged: canvas.requestPaint()

    Rectangle {
        anchors.fill: parent
        radius: root.ap.rSm
        color: root.ap.ground
        border.width: 1
        border.color: root.ap.rule
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width, h = height;
            ctx.save();
            ctx.beginPath();
            ctx.rect(root.padL, root.padT, root.plotW, root.plotH);
            ctx.clip();

            // Grid: decades bold, the rest faint; dB every quarter.
            const lines = [20, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900,
                           1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 20000];
            for (const f of lines) {
                const major = [100, 1000, 10000].indexOf(f) >= 0;
                ctx.strokeStyle = String(major ? root.ap.div : root.ap.rule);
                ctx.lineWidth = 1;
                ctx.beginPath();
                const x = Math.round(root.xOf(f)) + 0.5;
                ctx.moveTo(x, root.padT); ctx.lineTo(x, root.padT + root.plotH);
                ctx.stroke();
            }
            for (let k = -4; k <= 4; k++) {
                const y = Math.round(root.yOf(k * root.range / 4)) + 0.5;
                ctx.strokeStyle = String(k === 0 ? root.ap.div : root.ap.rule);
                ctx.lineWidth = k === 0 ? 1.2 : 1;
                ctx.beginPath();
                ctx.moveTo(root.padL, y); ctx.lineTo(root.padL + root.plotW, y);
                ctx.stroke();
            }

            const fs = root.freqs;
            const zero = root.yOf(0);
            function path(c) {
                ctx.beginPath();
                for (let i = 0; i < fs.length; i++) {
                    const x = root.xOf(fs[i]);
                    const y = Math.max(root.padT - 4, Math.min(root.padT + root.plotH + 4, root.yOf(c[i])));
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                }
            }
            // Each band's own shape, filled from 0 dB in its colour; the
            // one selected stronger, one switched off barely there.
            for (const b of root.fx.bands) {
                const c = EqM.bandCurve(b, fs);
                const sel = b.id === root.selectedId;
                const col = Qt.color(root.colourOf(b));
                path(c);
                ctx.lineTo(root.xOf(fs[fs.length - 1]), zero);
                ctx.lineTo(root.xOf(fs[0]), zero);
                ctx.closePath();
                ctx.fillStyle = Qt.rgba(col.r, col.g, col.b, !b.on ? 0.04 : sel ? 0.26 : 0.11);
                ctx.fill();
                if (sel || b.on) {
                    path(c);
                    ctx.strokeStyle = Qt.rgba(col.r, col.g, col.b, !b.on ? 0.25 : sel ? 0.95 : 0.45);
                    ctx.lineWidth = sel ? 1.6 : 1;
                    ctx.stroke();
                }
            }
            // The sum, with the preamp: what is heard.
            const total = EqM.totalCurve(root.fx.bands, root.ap.eqPreamp, fs);
            path(total);
            ctx.strokeStyle = String(root.ap.ink);
            ctx.lineWidth = 2.2;
            ctx.lineJoin = "round";
            ctx.stroke();
            // Above 0 dB, loud passages clip: marked along the top.
            ctx.fillStyle = "rgba(230, 60, 40, 0.85)";
            for (let i = 0; i < fs.length; i++) {
                if (total[i] <= 0.05) continue;
                const x = root.xOf(fs[i]);
                ctx.fillRect(x - 1.5, root.padT, 3, 3);
            }
            ctx.restore();

            // Labels: frequencies under, dB to the left.
            ctx.fillStyle = String(root.ap.ink3);
            ctx.font = Math.round(root.ap.fs(9.5)) + "px '" + root.ap.fontFamily + "'";
            ctx.textBaseline = "top";
            ctx.textAlign = "center";
            for (const f of [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
                const x = Math.max(root.padL + 8, Math.min(root.padL + root.plotW - 10, root.xOf(f)));
                ctx.fillText(EqM.fmtFreq(f), x, root.padT + root.plotH + 6);
            }
            ctx.textAlign = "right";
            ctx.textBaseline = "middle";
            for (let k = -2; k <= 2; k++) {
                const v = k * root.range / 2;
                ctx.fillText((v > 0 ? "+" : v < 0 ? "−" : "") + Math.abs(v), root.padL - 6, root.yOf(v));
            }
        }
    }

    // ── adding ────────────────────────────────────────────────────────────
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: root.picked(-1)
        onDoubleClicked: mouse => {
            if (mouse.x < root.padL || mouse.y > root.padT + root.plotH) return;
            const id = root.fx.addBand(root.fOf(mouse.x),
                                       Math.round(Math.max(-root.range, Math.min(root.range, root.dbOf(mouse.y))) * 2) / 2);
            if (id >= 0) root.picked(id);
        }
    }

    StyledText {
        anchors.centerIn: parent
        visible: root.fx.bands.length === 0
        text: "Double-click anywhere on the graph to add a band, or pick a preset"
        font.pixelSize: root.ap.fs(12)
        color: root.ap.ink3
    }

    // ── the handles ───────────────────────────────────────────────────────
    // Keyed by id, as a string, so the handles are made again only when
    // bands come or go — not on every step of a drag, which rebuilt them
    // under the pointer and dropped the drag.
    readonly property string idKey: root.fx.bands.map(b => b.id).join(",")
    Repeater {
        model: root.idKey === "" ? [] : root.idKey.split(",").map(Number)

        Item {
            id: handle
            required property var modelData
            readonly property var b: root.fx.bands.find(x => x.id === modelData)
                                     || ({ id: modelData, type: "bell", freq: 1000, gain: 0, q: 1, slope: 24, on: false })
            readonly property bool sel: b.id === root.selectedId
            readonly property bool gainy: EqM.hasGain(b.type)
            // While dragged, the handle follows the pointer; the band
            // follows it through the settings, a step behind.
            property real dragX: 0
            property real dragY: 0
            readonly property real cx: area.pressed ? dragX : root.xOf(b.freq)
            readonly property real cy: area.pressed ? dragY : root.yOf(gainy ? b.gain : 0)

            width: 22; height: 22
            x: cx - width / 2
            y: cy - height / 2
            z: sel ? 3 : 2

            Rectangle {
                anchors.centerIn: parent
                width: handle.sel ? 18 : 14
                height: width
                radius: width / 2
                color: handle.b.on ? root.colourOf(handle.b) : root.ap.ground
                border.width: handle.sel ? 2.5 : 1.5
                border.color: handle.b.on ? (handle.sel ? root.ap.ink : Qt.darker(root.colourOf(handle.b), 1.4))
                                          : root.colourOf(handle.b)
                Behavior on width { NumberAnimation { duration: root.ap.anim(90) } }
                StyledText {
                    anchors.centerIn: parent
                    text: String(root.fx.bands.indexOf(handle.b) + 1)
                    font.pixelSize: root.ap.fs(handle.sel ? 9.5 : 8.5)
                    font.weight: Font.Bold
                    color: handle.b.on ? "#1b1918" : root.colourOf(handle.b)
                }
            }

            MouseArea {
                id: area
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                preventStealing: true
                property real ox: 0
                property real oy: 0
                property real px: 0
                property real py: 0
                onPressed: mouse => {
                    root.picked(handle.b.id);
                    if (mouse.button !== Qt.LeftButton) return;
                    const p = mapToItem(root, mouse.x, mouse.y);
                    px = p.x; py = p.y;
                    ox = root.xOf(handle.b.freq); oy = root.yOf(handle.gainy ? handle.b.gain : 0);
                    handle.dragX = ox; handle.dragY = oy;
                }
                onPositionChanged: mouse => {
                    if (!pressed || !(mouse.buttons & Qt.LeftButton)) return;
                    const p = mapToItem(root, mouse.x, mouse.y);
                    const k = (mouse.modifiers & Qt.ShiftModifier) ? 0.2 : 1;
                    const nx = Math.max(root.padL, Math.min(root.padL + root.plotW, ox + (p.x - px) * k));
                    const ny = Math.max(root.padT, Math.min(root.padT + root.plotH, oy + (p.y - py) * k));
                    handle.dragX = nx;
                    handle.dragY = handle.gainy ? ny : oy;
                    const patch = { freq: root.fOf(nx) };
                    if (handle.gainy) patch.gain = Math.max(-EqM.GAIN_MAX, Math.min(EqM.GAIN_MAX, root.dbOf(ny)));
                    root.fx.setBand(handle.b.id, patch);
                }
                onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton && handle.gainy) root.fx.setBand(handle.b.id, { gain: 0 }); }
                onClicked: mouse => { if (mouse.button === Qt.RightButton) root.fx.toggleBand(handle.b.id); }
                onWheel: wheel => {
                    const step = wheel.angleDelta.y > 0 ? 1.12 : 1 / 1.12;
                    root.fx.setBand(handle.b.id, { q: Math.max(EqM.Q_MIN, Math.min(EqM.Q_MAX, handle.b.q * step)) });
                    root.picked(handle.b.id);
                }
            }

            // What it is set to, beside it while the pointer is on it.
            Rectangle {
                visible: area.containsMouse || area.pressed
                x: handle.cx > root.width - 170 ? -width - 6 : handle.width + 6
                y: handle.cy < 40 ? handle.height : -height
                width: tip.implicitWidth + 16
                height: tip.implicitHeight + 10
                radius: root.ap.rSm
                color: root.ap.menuSurface
                border.width: 1
                border.color: root.ap.edge
                StyledText {
                    id: tip
                    anchors.centerIn: parent
                    text: EqM.typeOf(handle.b.type).label + " · " + EqM.fmtFreq(handle.b.freq) + " Hz"
                        + (handle.gainy ? " · " + EqM.fmtGain(handle.b.gain) + " dB" : "")
                        + (EqM.isCut(handle.b.type) ? " · " + handle.b.slope + " dB/oct" : " · Q " + handle.b.q.toFixed(2))
                        + (handle.b.on ? "" : " · off")
                    font.pixelSize: root.ap.fs(11)
                    font.weight: Font.DemiBold
                }
            }
        }
    }
}
