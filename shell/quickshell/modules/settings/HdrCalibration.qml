import QtQuick
import QtQml
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"

// Settings → Display → HDR calibration → Calibrate: Windows' HDR
// Calibration app, on the display being calibrated. Three test patterns:
// minimum luminance, maximum luminance and maximum full-frame luminance, each
// "drag the slider until the pattern isn't visible". Then colour saturation,
// and a before/after comparison. The results become the display's luminance
// figures (what HDR content is tone-mapped to) and its SDR black.
//
// How a shell that draws in SDR shows a pattern at, say, 900 nits: while a
// test runs, Hyprland is told SDR white is far brighter than any panel
// (sdr_max_luminance), with a pure 2.2 curve, a 0-nit black and no tone
// mapping of its own (max_luminance 10000). An SDR value v then leaves the
// compositor as W·v^2.2 nits, so the pattern is drawn at (L/W)^(1/2.2) and
// the background at full white, which the panel clips to its peak. Once L is
// past what the panel can do, pattern and background clip to the same light
// and the pattern disappears: as in Windows, that's the panel's limit.
// Nothing is saved until Save; Cancel or Esc shows the old values again.
PanelWindow {
    id: cal

    required property var target          // a Quickshell screen
    required property string output       // its name, e.g. eDP-1
    signal done()

    screen: target
    color: "black"
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell:hdrcalibration"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var caps: Services.Devices.edidCaps[output] || ({})

    // ── the steps ─────────────────────────────────────────────────────────
    readonly property var titles: ["HDR Calibration", "Minimum luminance", "Maximum luminance",
                                   "Maximum full frame luminance", "Color saturation", "Finish"]
    readonly property int last: titles.length - 1
    property int step: 0
    readonly property bool testing: step >= 1 && step <= 3

    // SDR white while each test runs, in nits: low for the near-black test,
    // so its tiny steps still fall on 8-bit codes; far above any panel for
    // the bright ones.
    readonly property real whiteLow: 10
    readonly property real whiteHigh: 4000

    // The results, starting from what's saved or what the EDID says.
    property real lmin: 0
    property real lmax: 1000
    property real lfull: 600
    property real sat: 1

    // The values to show again on Cancel and as "Before".
    property var before: ({})
    // What's kept besides the results (SDR content brightness and curve).
    property var keep: ({})

    function pick(a, b) { return a !== undefined && a !== null ? a : b; }

    Component.onCompleted: {
        const had = Services.Devices.displayMap()[cal.output] || ({});
        const d = Services.Devices.colourDefaults;
        const b = ({});
        for (const k in d) b[k] = pick(had[k], d[k]);
        const edid = { max_luminance: caps.maxLum > 0 ? Math.round(caps.maxLum) : undefined,
                       max_avg_luminance: caps.maxAvgLum > 0 ? Math.round(caps.maxAvgLum) : undefined,
                       min_luminance: caps.minLum > 0 ? caps.minLum : undefined };
        for (const k in edid) {
            const v = pick(had[k], edid[k]);
            if (v !== undefined) b[k] = v;
        }
        cal.before = b;
        cal.keep = { sdr_eotf: pick(had.sdr_eotf, "gamma22"),
                     sdr_max_luminance: pick(had.sdr_max_luminance, 203),
                     sdrbrightness: pick(had.sdrbrightness, 1) };
        cal.lmin = pick(had.min_luminance, caps.minLum > 0 ? caps.minLum : 0);
        cal.lmax = pick(had.max_luminance, caps.maxLum > 0 ? Math.round(caps.maxLum) : 1000);
        cal.lfull = pick(had.max_avg_luminance, caps.maxAvgLum > 0 ? Math.round(caps.maxAvgLum) : Math.round(cal.lmax * 0.6));
        cal.sat = pick(had.sdrsaturation, 1);
    }

    function testValues(white) {
        return { sdr_eotf: "gamma22", sdr_min_luminance: 0, sdr_max_luminance: white,
                 sdrbrightness: 1, sdrsaturation: 1,
                 max_luminance: 10000, max_avg_luminance: 10000, min_luminance: 0 };
    }
    function results() {
        const r = Object.assign({}, cal.keep);
        r.min_luminance = Math.round(cal.lmin * 10000) / 10000;
        // SDR black at the panel's own: 0.2 nits, Hyprland's default, is a
        // grey on an OLED, and below its floor an LCD crushes shadows.
        r.sdr_min_luminance = r.min_luminance;
        r.max_luminance = Math.round(cal.lmax);
        r.max_avg_luminance = Math.round(Math.min(cal.lfull, cal.lmax));
        r.sdrsaturation = Math.round(cal.sat * 100) / 100;
        return r;
    }

    // What the display is told for each step.
    property bool showBefore: false
    function show() {
        if (cal.finished) return;
        if (cal.step === 1) Services.Devices.showColour(cal.output, testValues(cal.whiteLow));
        else if (cal.step === 2 || cal.step === 3) Services.Devices.showColour(cal.output, testValues(cal.whiteHigh));
        else if (cal.step >= 4) Services.Devices.showColour(cal.output, cal.showBefore ? cal.before : results());
    }
    onStepChanged: { cal.showBefore = false; showSoon.restart(); }
    onShowBeforeChanged: showSoon.restart()
    // Saturation is a setting of the display, not of the pattern: sent
    // once the slider settles.
    onSatChanged: if (cal.step === 4) showSoon.restart()
    Timer { id: showSoon; interval: 200; onTriggered: cal.show() }

    property bool finished: false
    function save() {
        if (cal.finished) return;
        cal.finished = true;
        showSoon.stop();
        Services.Devices.previewColour(cal.output, results());
        cal.done();
    }
    function cancel() {
        if (cal.finished) return;
        cal.finished = true;
        showSoon.stop();
        if (cal.step > 0) Services.Devices.showColour(cal.output, cal.before);
        cal.done();
    }
    // Closed some other way (Settings shut while it was up): as Cancel.
    Component.onDestruction: if (!cal.finished) cal.cancel()

    // ── each test's slider ────────────────────────────────────────────────
    // Minimum: 0–0.5 nits on a cubic scale, fine near black where it
    // matters. Maximum and full frame: 100–2500 nits in tens.
    function value() { return cal.step === 1 ? cal.lmin : cal.step === 2 ? cal.lmax : cal.lfull; }
    function frac() {
        if (cal.step === 1) return Math.cbrt(cal.lmin / 0.5);
        if (cal.step === 4) return (cal.sat - 0.5) / 1;
        return (value() - 100) / 2400;
    }
    function setFrac(f) {
        f = Math.max(0, Math.min(1, f));
        if (cal.step === 1) cal.lmin = Math.round(0.5 * f * f * f * 10000) / 10000;
        else if (cal.step === 2) cal.lmax = 100 + Math.round(f * 240) * 10;
        else if (cal.step === 3) cal.lfull = 100 + Math.round(f * 240) * 10;
        else if (cal.step === 4) cal.sat = Math.round((0.5 + f) * 100) / 100;
    }
    function nudge(dir) {
        if (cal.step === 1) {
            // A step in the third decimal near black, coarser above.
            const s = cal.lmin < 0.02 ? 0.0005 : cal.lmin < 0.1 ? 0.002 : 0.01;
            cal.lmin = Math.max(0, Math.min(0.5, Math.round((cal.lmin + dir * s) * 10000) / 10000));
        } else if (cal.step === 2) cal.lmax = Math.max(100, Math.min(2500, cal.lmax + dir * 10));
        else if (cal.step === 3) cal.lfull = Math.max(100, Math.min(2500, cal.lfull + dir * 10));
        else if (cal.step === 4) cal.sat = Math.max(0.5, Math.min(1.5, Math.round((cal.sat + dir * 0.01) * 100) / 100));
    }

    // The pattern's grey: L nits with SDR white at W, through the 2.2 curve.
    function level(l, w) { const v = Math.pow(Math.max(0, l) / w, 1 / 2.2); return Math.min(1, v); }
    readonly property real patternGrey: cal.step === 1 ? level(cal.lmin, cal.whiteLow)
                                      : cal.step === 2 ? level(cal.lmax, cal.whiteHigh)
                                      : cal.step === 3 ? level(cal.lfull, cal.whiteHigh) : 0
    readonly property color patternColor: Qt.rgba(patternGrey, patternGrey, patternGrey, 1)
    // The ground the pattern sits on: black for the minimum, full white
    // (clipped to the panel's peak) for the others.
    readonly property color groundColor: cal.step === 1 ? "black" : "white"

    readonly property color dim: Qt.rgba(0.55, 0.55, 0.55, 1)
    readonly property color ink: Qt.rgba(0.82, 0.82, 0.82, 1)

    // ── full frame: the whole screen is the test ─────────────────────────
    Rectangle {
        anchors.fill: parent
        visible: cal.step === 3
        color: cal.groundColor
        PatternGrid {
            anchors.fill: parent
            cells: 9
            ground: cal.groundColor
            ink: cal.patternColor
        }
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: cal.cancel()
        Keys.onLeftPressed: cal.nudge(-1)
        Keys.onRightPressed: cal.nudge(1)
        Keys.onDownPressed: cal.nudge(-1)
        Keys.onUpPressed: cal.nudge(1)
        Keys.onReturnPressed: cal.step < cal.last ? cal.step++ : cal.save()
        Keys.onPressed: e => { if (e.key === Qt.Key_Backspace && cal.step > 0) { cal.step--; e.accepted = true; } }

        // The card the words and controls sit on: dark and small, so it
        // lights as little of the screen as it can.
        Rectangle {
            id: card
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: cal.step === 0 || cal.step === cal.last ? (parent.height - height) / 2 : 48
            width: Math.min(parent.width - 48, 760)
            height: body.implicitHeight + 48
            radius: 14
            color: Qt.rgba(0.06, 0.06, 0.06, 1)
            border.width: 1
            border.color: Qt.rgba(0.14, 0.14, 0.14, 1)

            Column {
                id: body
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 24
                spacing: 16

                StyledText {
                    text: (cal.step > 0 && cal.step < cal.last ? "Step " + cal.step + " of " + (cal.last - 1) + "   " : "")
                          + cal.titles[cal.step]
                    font.pixelSize: 22
                    font.weight: Font.DemiBold
                    color: cal.ink
                }
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    font.pixelSize: 14
                    color: cal.dim
                    text: [
                        "Calibrate " + cal.output + " for HDR games, video and apps. Three test patterns find how dark and "
                        + "how bright this display really goes, then you set colour saturation. Do it in the light "
                        + "you usually use the display in. Nothing changes until you save; Esc cancels.",
                        "Drag the slider until the pattern isn't visible. Arrow keys move it one step at a time.",
                        "Drag the slider until the pattern isn't visible.",
                        "Drag the slider until the pattern isn't visible.",
                        "Drag the slider until colours look the way you like: vivid but natural, skin tones not orange.",
                        cal.showBefore ? "Showing how it was before. Switch to After to see the calibrated result."
                                       : "Calibrated. Switch to Before to compare, then save to keep it for this display."
                    ][cal.step]
                }

                // The test pattern, for the two in a box.
                Rectangle {
                    visible: cal.step === 1 || cal.step === 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 300
                    height: 300
                    color: cal.groundColor
                    PatternGrid {
                        anchors.fill: parent
                        cells: 5
                        ground: cal.groundColor
                        ink: cal.patternColor
                    }
                }

                // The saturation preview.
                Grid {
                    visible: cal.step >= 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    columns: 6
                    spacing: 8
                    Repeater {
                        model: ["#f1c27d", "#e0ac69", "#c68642", "#8d5524", "#87ceeb", "#4f7942",
                                "#d62828", "#2a9d3f", "#1d4ed8", "#f2c94c", "#22b8cf", "#c2185b"]
                        Rectangle {
                            required property string modelData
                            width: 96
                            height: 64
                            radius: 6
                            color: modelData
                        }
                    }
                }
                Rectangle {
                    visible: cal.step >= 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 96 * 6 + 8 * 5
                    height: 22
                    radius: 6
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "#ff0000" }
                        GradientStop { position: 0.17; color: "#ffff00" }
                        GradientStop { position: 0.33; color: "#00ff00" }
                        GradientStop { position: 0.5; color: "#00ffff" }
                        GradientStop { position: 0.67; color: "#0000ff" }
                        GradientStop { position: 0.83; color: "#ff00ff" }
                        GradientStop { position: 1; color: "#ff0000" }
                    }
                }

                // The slider.
                Column {
                    visible: cal.step >= 1 && cal.step <= 4
                    width: parent.width
                    spacing: 8
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        font.pixelSize: 15
                        color: cal.ink
                        text: cal.step === 1 ? cal.lmin.toFixed(4).replace(/0+$/, "").replace(/\.$/, ".0") + " nits"
                            : cal.step === 4 ? Math.round(cal.sat * 100) + "%"
                            : Math.round(cal.value()) + " nits"
                    }
                    FillSlider {
                        width: parent.width
                        trough: 14
                        trackColor: Qt.rgba(0.16, 0.16, 0.16, 1)
                        value: cal.frac()
                        onMoved: v => cal.setFrac(v)
                    }
                }

                // Before / after.
                Row {
                    visible: cal.step === cal.last
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    CalButton { label: "Before"; primary: cal.showBefore; onClicked: cal.showBefore = true }
                    CalButton { label: "After"; primary: !cal.showBefore; onClicked: cal.showBefore = false }
                }

                StyledText {
                    visible: cal.step === cal.last
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 13
                    color: cal.dim
                    text: "Black " + cal.results().min_luminance + " nits · peak " + cal.results().max_luminance
                          + " nits · full screen " + cal.results().max_avg_luminance + " nits · saturation "
                          + Math.round(cal.sat * 100) + "%"
                }

                Row {
                    anchors.right: parent.right
                    spacing: 10
                    CalButton { label: "Cancel"; onClicked: cal.cancel() }
                    CalButton { visible: cal.step > 0; label: "Back"; onClicked: cal.step-- }
                    CalButton {
                        primary: true
                        label: cal.step === 0 ? "Get started" : cal.step === cal.last ? "Save" : "Next"
                        onClicked: cal.step < cal.last ? cal.step++ : cal.save()
                    }
                }
            }
        }
    }
}
