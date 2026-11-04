import QtQuick
import QtQml
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"

// Settings → Display → HDR calibration → Calibrate: a step-by-step setup on
// the display being calibrated, like Windows' HDR Calibration app. Black
// level, shadows, SDR brightness, peak brightness and colour, each shown
// with its own pattern and changed live; Save keeps them, Cancel or Esc
// puts the display back exactly as it was.
//
// The shell draws in SDR, which Hyprland maps into HDR with exactly the
// settings calibrated here, so every pattern shows their effect directly.
// Peak brightness is the exception: it shapes HDR video and games, which
// the shell can't draw, so that step explains rather than shows.
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
    readonly property bool oled: caps.minLum !== undefined && caps.minLum > 0 && caps.minLum < 0.05
    readonly property var ipc: {
        const m = (Services.Compositor.monitors || []).find(x => x && x.name === cal.output);
        return m ? (m.lastIpcObject || ({})) : ({});
    }

    // The entry as it was, for Cancel, and the values as they are now.
    property var had: ({})
    property var cur: ({})
    readonly property var keys: ["sdr_min_luminance", "sdr_eotf", "sdr_max_luminance",
                                 "max_luminance", "sdrsaturation", "sdrbrightness"]

    property int step: 0
    readonly property var titles: ["Calibrate HDR", "Black level", "Shadows",
                                   "SDR brightness", "Peak brightness", "Colour", "All set"]
    readonly property int last: titles.length - 1

    // Linear light → the sRGB-encoded value that shows it: 0.01 is 1% of white.
    function enc(l) { return l <= 0.0031308 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055; }
    function grey(l) { const g = enc(l); return Qt.rgba(g, g, g, 1); }
    function pick(a, b) { return a !== undefined && a !== null ? a : b; }

    Component.onCompleted: {
        const map = Services.Devices.displayMap();
        cal.had = Object.assign({}, map[cal.output] || ({}));
        const h = cal.had;
        // Starting from what's saved, or else from what suits this panel
        // (Set up for this display's values): each step is then a check
        // more than a search.
        const start = {
            sdr_min_luminance: pick(h.sdr_min_luminance,
                cal.oled || caps.minLum === undefined ? 0.005 : Math.max(0.005, Math.round(caps.minLum * 1000) / 1000)),
            sdr_eotf: pick(h.sdr_eotf, "gamma22"),
            sdr_max_luminance: pick(h.sdr_max_luminance, 203),
            sdrsaturation: pick(h.sdrsaturation, 1),
            sdrbrightness: pick(h.sdrbrightness, 1)
        };
        const peak = pick(h.max_luminance, caps.maxLum > 0 ? Math.round(caps.maxLum) : undefined);
        if (peak !== undefined) start.max_luminance = peak;
        cal.cur = start;
        Services.Devices.previewColour(cal.output, start);
    }

    function stage(k, v) {
        const n = Object.assign({}, cal.cur);
        n[k] = v;
        cal.cur = n;
        applyLater.restart();
    }
    // A slider sends a value per pixel dragged; the monitor is set once it
    // settles.
    Timer {
        id: applyLater
        interval: 250
        onTriggered: Services.Devices.previewColour(cal.output, cal.cur)
    }

    property bool finished: false
    function save() {
        if (cal.finished) return;
        cal.finished = true;
        applyLater.stop();
        Services.Devices.previewColour(cal.output, cal.cur);
        Services.Compositor.refreshMonitors();
        cal.done();
    }
    function cancel() {
        if (cal.finished) return;
        cal.finished = true;
        applyLater.stop();
        Services.Devices.restoreColour(cal.output, cal.had, cal.keys);
        cal.done();
    }

    // Closed some other way (Settings shut while it was up): as Cancel.
    Component.onDestruction: if (!cal.finished) cal.cancel()

    readonly property color dim: Qt.rgba(0.5, 0.5, 0.5, 1)
    readonly property color text: Qt.rgba(0.78, 0.78, 0.78, 1)

    // Discrete stops for the black level, in nits.
    readonly property var blackStops: [0, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3]
    function blackIndex() {
        const v = Number(cal.cur.sdr_min_luminance);
        let best = 0;
        for (let i = 0; i < blackStops.length; i++)
            if (Math.abs(blackStops[i] - v) < Math.abs(blackStops[best] - v)) best = i;
        return best;
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: cal.cancel()
        Keys.onLeftPressed: if (cal.step > 0) cal.step--
        Keys.onRightPressed: if (cal.step < cal.last) cal.step++
        Keys.onReturnPressed: cal.step < cal.last ? cal.step++ : cal.save()

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 1000)
            spacing: 28

            // ── heading ───────────────────────────────────────────────────
            Column {
                width: parent.width
                spacing: 8
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: (cal.step > 0 && cal.step < cal.last ? cal.step + " of " + (cal.last - 1) + "  ·  " : "")
                          + cal.titles[cal.step]
                    font.pixelSize: 26
                    font.weight: Font.DemiBold
                    color: cal.text
                }
                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.pixelSize: 15
                    color: cal.dim
                    text: [
                        "Five short steps, each changing the display live as you adjust it. "
                        + "Best done in the light you usually work in, with the display at the brightness you normally use. "
                        + "Esc at any point puts everything back as it was.",
                        "Move the slider to the lowest setting at which the 1% square is still visible against the background. "
                        + "Lower makes blacks deeper; too low and the darkest squares disappear into the background."
                        + (cal.oled ? " An OLED can go very low." : ""),
                        "Pick the curve where the dark steps look like dark grey rather than milky, and each one is still "
                        + "distinguishable from the next. Gamma 2.2 is what most SDR content and Windows use.",
                        "How bright ordinary windows are: set it so this white page looks like a comfortable white, "
                        + "not dull and not glaring. Around 200 nits suits most rooms; more for a bright one.",
                        "The brightest the display can go. Hyprland fits HDR highlights in videos and games to it: "
                        + "lower it if bright detail (clouds, lights) turns flat white, raise it if HDR looks dim. "
                        + "These patterns can't show it, as the shell itself draws in SDR.",
                        "How saturated ordinary colours are. Skin tones and the sky should look natural, not neon "
                        + "and not faded.",
                        "Save keeps these for this display, applied whenever HDR is on. Each one is also in "
                        + "Settings → Display → HDR calibration, and Calibrate runs this again."
                    ][cal.step]
                }
            }

            // ── step 0: what this display says it is ──────────────────────
            Column {
                visible: cal.step === 0
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.pixelSize: 15
                    color: cal.text
                    text: cal.output + (cal.oled ? " · OLED" : "")
                }
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.pixelSize: 14
                    color: cal.dim
                    text: (cal.caps.maxLum > 0 ? "Peak " + Math.round(cal.caps.maxLum) + " nits" : "Peak brightness not reported")
                          + (cal.caps.minLum > 0 ? "  ·  black " + cal.caps.minLum + " nits" : "")
                          + "  (from its EDID)"
                }
            }

            // ── step 1: black level ───────────────────────────────────────
            Row {
                visible: cal.step === 1
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20
                Repeater {
                    model: [0, 0.0025, 0.005, 0.01, 0.02, 0.04]
                    Column {
                        required property real modelData
                        spacing: 10
                        Rectangle {
                            width: 120
                            height: 120
                            color: cal.grey(modelData)
                        }
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: (modelData * 100) + "%"
                            font.pixelSize: 13
                            color: Qt.rgba(0.4, 0.4, 0.4, 1)
                        }
                    }
                }
            }

            // ── step 2: shadows ───────────────────────────────────────────
            Row {
                visible: cal.step === 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 0
                Repeater {
                    // Even steps of the encoded value, as SDR content has them.
                    model: 16
                    Rectangle {
                        required property int index
                        width: 56
                        height: 150
                        readonly property real v: index * 0.03
                        color: Qt.rgba(v, v, v, 1)
                    }
                }
            }

            // ── step 3: SDR brightness ────────────────────────────────────
            Rectangle {
                visible: cal.step === 3
                anchors.horizontalCenter: parent.horizontalCenter
                width: 560
                height: 250
                radius: 12
                color: "white"
                Column {
                    anchors.fill: parent
                    anchors.margins: 28
                    spacing: 12
                    StyledText {
                        text: "A page of ordinary text"
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                        color: "#1d1d1d"
                    }
                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: 15
                        color: "#333333"
                        text: "Documents, web pages and most apps are SDR. With HDR on, Hyprland shows their white "
                              + "at the brightness set below, and HDR highlights go above it."
                    }
                    Row {
                        spacing: 8
                        Repeater {
                            model: ["#e8e8e8", "#c0c0c0", "#8a8a8a", "#555555", "#2a2a2a"]
                            Rectangle {
                                required property string modelData
                                width: 88
                                height: 44
                                radius: 6
                                color: modelData
                            }
                        }
                    }
                }
            }

            // ── step 4: peak brightness ───────────────────────────────────
            Row {
                visible: cal.step === 4
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 18
                Repeater {
                    model: [0.25, 0.5, 0.75, 1]
                    Rectangle {
                        required property real modelData
                        width: 120
                        height: 120
                        radius: 60
                        color: cal.grey(modelData)
                    }
                }
            }

            // ── step 5: colour ────────────────────────────────────────────
            Grid {
                visible: cal.step === 5
                anchors.horizontalCenter: parent.horizontalCenter
                columns: 6
                spacing: 12
                Repeater {
                    model: ["#f1c27d", "#e0ac69", "#c68642", "#8d5524", "#87ceeb", "#4f7942",
                            "#d62828", "#2a9d3f", "#1d4ed8", "#f2c94c", "#22b8cf", "#c2185b"]
                    Rectangle {
                        required property string modelData
                        width: 104
                        height: 80
                        radius: 8
                        color: modelData
                    }
                }
            }

            // ── step 6: summary ───────────────────────────────────────────
            Column {
                visible: cal.step === cal.last
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Repeater {
                    model: [
                        "Black level  " + cal.cur.sdr_min_luminance + " nits",
                        "Shadows  " + ({ gamma22: "Gamma 2.2", srgb: "sRGB", "default": "Hyprland's default" })[cal.cur.sdr_eotf],
                        "SDR brightness  " + cal.cur.sdr_max_luminance + " nits",
                        "Peak brightness  " + (cal.cur.max_luminance !== undefined ? cal.cur.max_luminance + " nits" : "the display's own"),
                        "Colour  " + Math.round(cal.cur.sdrsaturation * 100) + "%"
                    ]
                    StyledText {
                        required property string modelData
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData
                        font.pixelSize: 15
                        color: cal.text
                    }
                }
            }

            // ── the control for this step ─────────────────────────────────
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 520
                spacing: 10
                visible: cal.step >= 1 && cal.step <= 5 && cal.step !== 2

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.pixelSize: 15
                    color: cal.text
                    text: cal.step === 1 ? cal.cur.sdr_min_luminance + " nits"
                        : cal.step === 3 ? cal.cur.sdr_max_luminance + " nits"
                        : cal.step === 4 ? (cal.cur.max_luminance !== undefined ? cal.cur.max_luminance + " nits" : "Not set: the display's own")
                        : cal.step === 5 ? Math.round(cal.cur.sdrsaturation * 100) + "%" : ""
                }
                FillSlider {
                    width: parent.width
                    trough: 14
                    trackColor: Qt.rgba(0.16, 0.16, 0.16, 1)
                    value: cal.step === 1 ? cal.blackIndex() / (cal.blackStops.length - 1)
                         : cal.step === 3 ? (cal.cur.sdr_max_luminance - 80) / 400
                         : cal.step === 4 ? ((cal.cur.max_luminance !== undefined ? cal.cur.max_luminance : 1000) - 200) / 1800
                         : cal.step === 5 ? (cal.cur.sdrsaturation - 0.7) / 0.6 : 0
                    onMoved: v => {
                        if (cal.step === 1)
                            cal.stage("sdr_min_luminance", cal.blackStops[Math.round(v * (cal.blackStops.length - 1))]);
                        else if (cal.step === 3)
                            cal.stage("sdr_max_luminance", 80 + Math.round(v * 40) * 10);
                        else if (cal.step === 4)
                            cal.stage("max_luminance", 200 + Math.round(v * 36) * 50);
                        else if (cal.step === 5)
                            cal.stage("sdrsaturation", Math.round((0.7 + v * 0.6) * 20) / 20);
                    }
                }
                CalButton {
                    visible: cal.step === 4 && cal.caps.maxLum > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    label: "Use the display's own (" + Math.round(cal.caps.maxLum || 0) + " nits)"
                    onClicked: cal.stage("max_luminance", Math.round(cal.caps.maxLum))
                }
            }

            Row {
                visible: cal.step === 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12
                Repeater {
                    model: [{ label: "Gamma 2.2", value: "gamma22" }, { label: "sRGB", value: "srgb" },
                            { label: "Hyprland's default", value: "default" }]
                    CalButton {
                        required property var modelData
                        label: modelData.label
                        primary: cal.cur.sdr_eotf === modelData.value
                        onClicked: cal.stage("sdr_eotf", modelData.value)
                    }
                }
            }

            // ── navigation ────────────────────────────────────────────────
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12
                topPadding: 12
                CalButton {
                    label: "Cancel"
                    onClicked: cal.cancel()
                }
                CalButton {
                    visible: cal.step > 0
                    label: "Back"
                    onClicked: cal.step--
                }
                CalButton {
                    primary: true
                    label: cal.step === 0 ? "Start" : cal.step === cal.last - 1 ? "Finish"
                         : cal.step === cal.last ? "Save" : "Next"
                    onClicked: cal.step < cal.last ? cal.step++ : cal.save()
                }
            }
        }
    }
}
