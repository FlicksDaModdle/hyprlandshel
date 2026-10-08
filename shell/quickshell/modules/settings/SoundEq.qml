import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../../services/EqMath.js" as EqM
import "../common"
import "../icons"

// Settings → Sound → Output: the equalizer (services/AudioFx.qml), a
// parametric one. Up to sixteen bands — bells, shelves, cuts at 12 to
// 48 dB/octave, notches, band passes — on a graph of the response they make
// together, each band set exactly in the strip under it; a preamp, with
// Auto to make room for every boost; presets to start from, and yours
// saved beside them. Everything is heard as it is changed.
Rectangle {
    id: root

    readonly property var fx: Services.AudioFx
    readonly property var prefs: Config.Appearance
    readonly property var ap: Config.Appearance
    readonly property bool on: prefs.eqEnabled
    readonly property color danger: "#d93a2b"

    property int selectedId: -1
    readonly property var sel: fx.bands.find(b => b.id === selectedId) || null
    // A band picked whenever there are bands, so the strip below always
    // has something to show.
    readonly property string idKey: fx.bands.map(b => b.id).join(",")
    onIdKeyChanged: if (!sel) selectedId = fx.bands.length ? fx.bands[0].id : -1
    Component.onCompleted: if (!sel && fx.bands.length) selectedId = fx.bands[0].id

    property bool presetsOpen: false
    property bool saving: false

    height: col.implicitHeight + 32
    radius: root.ap.r
    color: root.ap.hover
    border.width: 1
    border.color: fx.eqStatus === "error" ? danger : root.ap.rule

    Column {
        id: col
        x: 16; y: 16; width: parent.width - 32; spacing: 14

        // ── on or off ────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 40
            Rectangle {
                id: badge
                width: 40; height: 40; radius: 20
                color: root.on ? root.ap.accent : root.ap.div
                MonoIcon {
                    anchors.centerIn: parent
                    name: "sliders"; size: 19; monochrome: true
                    inkColor: root.on ? root.ap.inkOnAccent : root.ap.ink2
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: toggle.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                StyledText { text: "Parametric equalizer"; font.pixelSize: root.ap.fs(15); font.weight: Font.DemiBold }
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: !root.fx.probed ? "Checking…"
                        : !root.fx.eqAvailable ? "Needs the pipewire program, which wasn't found"
                        : !root.on ? "Off — shape the sound of everything you play"
                        : root.fx.eqStatus === "starting" ? "Starting…"
                        : root.fx.eqStatus === "error" ? "Didn't start — see below"
                        : "On, for " + (root.fx.eqPerApp ? (root.fx.eqApps.length === 1 ? "1 app" : root.fx.eqApps.length + " apps")
                                     : Services.Audio.sink ? Services.Audio.displayName(Services.Audio.sink) : "the output")
                          + " · " + root.prefs.eqPreset + " · " + root.fx.bands.filter(b => b.on).length + " bands"
                    font.pixelSize: root.ap.fs(12)
                    color: root.ap.ink3
                }
            }
            Toggle {
                id: toggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.fx.eqAvailable
                checked: root.on
                onToggled: on => root.fx.setEnabled(on)
            }
        }

        StyledText {
            visible: root.fx.eqStatus === "error" && root.on
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.fx.eqError
            font.pixelSize: root.ap.fs(12)
            color: root.danger
        }
        NetButton {
            visible: root.fx.eqStatus === "error" && root.on
            label: "Try again"
            onClicked: root.fx.retryEq()
        }

        // ── what it applies to ───────────────────────────────────────────
        Item {
            width: parent.width
            height: 32
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Applies to"
                font.pixelSize: root.ap.fs(12.5)
                font.weight: Font.Medium
                color: root.ap.ink2
            }
            Segmented {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                segmentPadding: 12
                options: [{ label: "Everything", value: "all" }, { label: "Chosen apps", value: "apps" }]
                value: root.fx.eqPerApp ? "apps" : "all"
                onSelected: v => root.fx.setScope(v)
            }
        }
        // The apps, as chips: those playing now, and those chosen before
        // that aren't. A tap puts one through the equalizer or takes it out.
        Flow {
            visible: root.fx.eqPerApp
            width: parent.width
            spacing: 6
            Repeater {
                model: {
                    const out = [];
                    const seen = {};
                    for (const s of Services.Audio.streams) {
                        const k = root.fx.appKey(s);
                        if (k === "" || seen[k]) continue;
                        seen[k] = true;
                        out.push({ key: k, label: Services.Audio.streamApp(s), hint: Services.Audio.streamHint(s), live: true });
                    }
                    for (const k of root.fx.eqApps)
                        if (!seen[k]) out.push({ key: k, label: k, hint: k, live: false });
                    return out;
                }
                Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool chosen: root.fx.isEqAppKey(modelData.key)
                    height: 30
                    width: chipRow.implicitWidth + 20
                    radius: 15
                    color: chosen ? Qt.rgba(root.ap.accent.r, root.ap.accent.g, root.ap.accent.b, 0.16)
                         : chipHover.hovered ? root.ap.sel : root.ap.ground
                    border.width: 1
                    border.color: chosen ? root.ap.accent : root.ap.rule
                    opacity: modelData.live ? 1 : 0.7
                    Behavior on color { ColorAnimation { duration: root.ap.anim(140) } }
                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 6
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: Config.Apps.iconFor(chip.modelData.hint)
                            size: 14
                            inkColor: chip.chosen ? root.ap.accent : root.ap.ink2
                            accentColor: root.ap.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: chip.modelData.label
                            font.pixelSize: root.ap.fs(12)
                            font.weight: chip.chosen ? Font.DemiBold : Font.Normal
                            color: chip.chosen ? root.ap.ink : root.ap.ink2
                        }
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: chip.chosen ? "check" : "plus"
                            size: 12; monochrome: true
                            inkColor: chip.chosen ? root.ap.accent : root.ap.ink3
                        }
                    }
                    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.fx.setEqAppKey(chip.modelData.key, !chip.chosen) }
                }
            }
        }
        StyledText {
            visible: root.fx.eqPerApp && Services.Audio.streams.length === 0 && root.fx.eqApps.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Start something playing and it shows here, to choose."
            font.pixelSize: root.ap.fs(12)
            color: root.ap.ink3
        }

        // ── presets ──────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 32
            Row {
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    id: presetBtn
                    height: 32
                    width: presetRow.implicitWidth + 24
                    radius: root.ap.rSm
                    color: root.presetsOpen ? root.ap.sel : (presetHover.hovered ? root.ap.sel : root.ap.ground)
                    border.width: 1
                    border.color: root.ap.rule
                    Row {
                        id: presetRow
                        anchors.centerIn: parent
                        spacing: 8
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Preset"
                            font.pixelSize: root.ap.fs(11.5)
                            color: root.ap.ink3
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.prefs.eqPreset
                            font.pixelSize: root.ap.fs(12.5)
                            font.weight: Font.DemiBold
                        }
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevronDown"; size: 14; monochrome: true
                            inkColor: root.ap.ink2
                            rotation: root.presetsOpen ? 180 : 0
                        }
                    }
                    HoverHandler { id: presetHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.presetsOpen = !root.presetsOpen; root.saving = false; } }
                }
                NetButton {
                    label: "Save as…"
                    onClicked: { root.saving = !root.saving; root.presetsOpen = false; if (root.saving) Qt.callLater(() => saveName.input.forceActiveFocus()); }
                }
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                NetButton { label: "Reset"; onClicked: root.fx.reset() }
            }
        }

        // Saving: a name, and the bands and preamp as they are go under it.
        Row {
            visible: root.saving
            width: parent.width
            spacing: 8
            NetField {
                id: saveName
                width: parent.width - saveBtn.width - cancelBtn.width - 16
                placeholder: "Name this preset"
                text: root.prefs.eqPreset === "Custom" ? "" : root.prefs.eqPreset
                onAccepted: saveBtn.clicked()
            }
            NetButton {
                id: saveBtn
                anchors.bottom: parent.bottom
                label: root.fx.userPresets.some(p => p.name === saveName.input.text.trim()) ? "Replace" : "Save"
                primary: true
                onClicked: if (root.fx.savePreset(saveName.input.text)) root.saving = false
            }
            NetButton { id: cancelBtn; anchors.bottom: parent.bottom; label: "Cancel"; onClicked: root.saving = false }
        }

        // The presets, by what they are for; yours last.
        Column {
            visible: root.presetsOpen
            width: parent.width
            spacing: 10
            Repeater {
                model: ["Basics", "Character", "Voice", "Device", "Tools", "Yours"]
                Column {
                    id: group
                    required property string modelData
                    readonly property var items: modelData === "Yours"
                        ? root.fx.userPresets.map(p => Object.assign({ user: true }, p))
                        : root.fx.builtinPresets.filter(p => p.group === modelData)
                    visible: items.length > 0
                    width: parent.width
                    spacing: 6
                    StyledText {
                        text: group.modelData === "Yours" ? "Saved" : group.modelData
                        font.pixelSize: root.ap.fs(11)
                        font.weight: Font.DemiBold
                        color: root.ap.ink3
                    }
                    Flow {
                        width: parent.width
                        spacing: 6
                        Repeater {
                            model: group.items
                            Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool current: root.prefs.eqPreset === modelData.name
                                height: 30
                                width: chipRow.implicitWidth + 22
                                radius: root.ap.rSm
                                color: current ? root.ap.accent : (chipHover.hovered ? root.ap.sel : root.ap.ground)
                                border.width: current ? 0 : 1
                                border.color: root.ap.rule
                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 6
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: chip.modelData.name
                                        font.pixelSize: root.ap.fs(12)
                                        font.weight: Font.DemiBold
                                        color: chip.current ? root.ap.inkOnAccent : root.ap.ink
                                    }
                                    // Yours can go.
                                    MonoIcon {
                                        visible: chip.modelData.user === true
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "x"; size: 12; monochrome: true
                                        inkColor: chip.current ? root.ap.inkOnAccent : root.ap.ink3
                                        TapHandler { onTapped: root.fx.deletePreset(chip.modelData.name) }
                                    }
                                }
                                HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: {
                                        root.fx.applyPreset(chip.modelData);
                                        root.selectedId = root.fx.bands.length ? root.fx.bands[0].id : -1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── the graph ────────────────────────────────────────────────────
        EqGraph {
            width: parent.width
            height: 260
            range: root.prefs.eqRange
            selectedId: root.selectedId
            opacity: root.on ? 1 : 0.7
            onPicked: id => root.selectedId = id
        }

        // ── the bands, in order of frequency ─────────────────────────────
        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: root.fx.bands.slice().sort((a, b) => a.freq - b.freq)
                Rectangle {
                    id: bchip
                    required property var modelData
                    readonly property bool picked: modelData.id === root.selectedId
                    readonly property color hue: {
                        const hues = ["#ff6a55", "#ffa94d", "#f2cc4d", "#6fd48c", "#4dc3e8", "#7d8cff", "#c07dff", "#ff79b0"];
                        return hues[Math.max(0, root.fx.bands.findIndex(x => x.id === modelData.id)) % hues.length];
                    }
                    height: 30
                    width: bRow.implicitWidth + 20
                    radius: root.ap.rSm
                    color: picked ? root.ap.sel : (bHover.hovered ? root.ap.sel : root.ap.ground)
                    border.width: picked ? 2 : 1
                    border.color: picked ? bchip.hue : root.ap.rule
                    opacity: modelData.on ? 1 : 0.55
                    Row {
                        id: bRow
                        anchors.centerIn: parent
                        spacing: 7
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 9; height: 9; radius: 4.5
                            color: bchip.modelData.on ? bchip.hue : "transparent"
                            border.width: 1.5
                            border.color: bchip.hue
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: EqM.typeOf(bchip.modelData.type).short + " " + EqM.fmtFreq(bchip.modelData.freq)
                                + (EqM.hasGain(bchip.modelData.type) ? "  " + EqM.fmtGain(bchip.modelData.gain) : "")
                            font.pixelSize: root.ap.fs(11.5)
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                        }
                    }
                    HoverHandler { id: bHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.selectedId = bchip.modelData.id }
                }
            }
            Rectangle {
                visible: root.fx.bands.length < EqM.MAX_BANDS
                height: 30
                width: addRow.implicitWidth + 20
                radius: root.ap.rSm
                color: addHover.hovered ? root.ap.sel : "transparent"
                border.width: 1
                border.color: root.ap.rule
                Row {
                    id: addRow
                    anchors.centerIn: parent
                    spacing: 6
                    MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "plus"; size: 13; monochrome: true; inkColor: root.ap.ink2 }
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Band"; font.pixelSize: root.ap.fs(11.5); font.weight: Font.DemiBold; color: root.ap.ink2 }
                }
                HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    // In the widest gap between the bands there are, so a
                    // new one is never on top of another.
                    onTapped: {
                        const fs = [20].concat(root.fx.bands.map(b => b.freq).sort((a, b) => a - b)).concat([20000]);
                        let best = 1000, gap = 0;
                        for (let i = 1; i < fs.length; i++) {
                            const g = Math.log(fs[i] / fs[i - 1]);
                            if (g > gap) { gap = g; best = Math.sqrt(fs[i] * fs[i - 1]); }
                        }
                        const id = root.fx.addBand(Math.max(60, Math.min(12000, best)), 0);
                        if (id >= 0) root.selectedId = id;
                    }
                }
            }
        }

        // ── the band picked ──────────────────────────────────────────────
        Rectangle {
            visible: root.sel !== null
            width: parent.width
            height: inspect.implicitHeight + 24
            radius: root.ap.rSm
            color: root.ap.ground
            border.width: 1
            border.color: root.ap.rule

            Column {
                id: inspect
                x: 12; y: 12
                width: parent.width - 24
                spacing: 12

                Item {
                    width: parent.width
                    height: 28
                    Segmented {
                        id: typeSeg
                        anchors.verticalCenter: parent.verticalCenter
                        segmentPadding: 9
                        options: EqM.TYPES.map(t => ({ label: t.short === "Bell" ? "Bell" : t.short, value: t.key }))
                        value: root.sel ? root.sel.type : "bell"
                        onSelected: v => root.fx.setBand(root.selectedId, { type: v })
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.sel && root.sel.on ? "On" : "Bypassed"
                            font.pixelSize: root.ap.fs(11.5)
                            color: root.ap.ink3
                        }
                        Toggle {
                            anchors.verticalCenter: parent.verticalCenter
                            checked: root.sel ? root.sel.on : false
                            onToggled: on => root.fx.setBand(root.selectedId, { on: on })
                        }
                        NetButton {
                            anchors.verticalCenter: parent.verticalCenter
                            label: "Remove"
                            danger: true
                            onClicked: root.fx.removeBand(root.selectedId)
                        }
                    }
                }

                Flow {
                    width: parent.width
                    spacing: 8
                    EqValue {
                        label: "FREQUENCY"
                        value: root.sel ? root.sel.freq : 1000
                        from: EqM.F_MIN; to: EqM.F_MAX
                        log: true; step: 0.03
                        unit: "Hz"
                        format: v => v >= 1000 ? (v / 1000).toFixed(v >= 10000 ? 1 : 2) + "k" : v.toFixed(v < 100 ? 1 : 0)
                        onMoved: v => root.fx.setBand(root.selectedId, { freq: v })
                    }
                    EqValue {
                        visible: root.sel !== null && EqM.hasGain(root.sel.type)
                        label: "GAIN"
                        value: root.sel ? root.sel.gain : 0
                        from: -EqM.GAIN_MAX; to: EqM.GAIN_MAX
                        step: 0.5
                        unit: "dB"
                        format: v => EqM.fmtGain(v)
                        onMoved: v => root.fx.setBand(root.selectedId, { gain: v })
                    }
                    EqValue {
                        label: root.sel && EqM.isCut(root.sel.type) ? "RESONANCE" : "Q"
                        value: root.sel ? root.sel.q : 1
                        from: EqM.Q_MIN; to: EqM.Q_MAX
                        log: true; step: 0.08
                        decimals: 2
                        onMoved: v => root.fx.setBand(root.selectedId, { q: v })
                    }
                    Column {
                        visible: root.sel !== null && EqM.isCut(root.sel.type)
                        spacing: 4
                        StyledText { text: "SLOPE"; font.pixelSize: root.ap.fs(10); font.weight: Font.DemiBold; color: root.ap.ink3 }
                        Segmented {
                            segmentPadding: 8
                            options: EqM.SLOPES.map(s => ({ label: s + " dB", value: String(s) }))
                            value: root.sel ? String(root.sel.slope) : "24"
                            onSelected: v => root.fx.setBand(root.selectedId, { slope: Number(v) })
                        }
                    }
                }
            }
        }

        // ── preamp and scale ─────────────────────────────────────────────
        Item {
            width: parent.width
            height: 34
            StyledText {
                id: preLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "Preamp"
                font.pixelSize: root.ap.fs(12.5)
                font.weight: Font.DemiBold
            }
            SoundCenterSlider {
                id: preSlider
                anchors.left: preLabel.right
                anchors.leftMargin: 12
                anchors.right: preVal.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                value: root.prefs.eqPreamp / 24
                onMoved: v => root.fx.setPreamp(Math.round(v * 24 * 2) / 2)
            }
            StyledText {
                id: preVal
                anchors.right: autoBtn.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 64
                horizontalAlignment: Text.AlignRight
                text: EqM.fmtGain(root.prefs.eqPreamp) + " dB"
                font.pixelSize: root.ap.fs(12)
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            NetButton {
                id: autoBtn
                anchors.right: rangeSeg.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                label: "Auto"
                onClicked: root.fx.autoPreamp()
            }
            Segmented {
                id: rangeSeg
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                segmentPadding: 8
                options: [{ label: "±6", value: "6" }, { label: "±12", value: "12" }, { label: "±24", value: "24" }]
                value: String(root.prefs.eqRange)
                onSelected: v => root.prefs.eqRange = Number(v)
            }
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Drag a point to move a band, scroll on it for Q, double-click it to flatten it and right-click "
                  + "to bypass it; double-click the graph to add one. Shift makes any drag finer. Red marks along "
                  + "the top are where the curve rises above 0 dB and loud passages would clip — Auto lowers the "
                  + "preamp just enough. Frequency, gain and Q are heard as they change; a new band, or a change "
                  + "of type or slope, rebuilds the equalizer, which drops the sound for a moment."
            font.pixelSize: root.ap.fs(11.5)
            color: root.ap.ink3
        }
    }
}
