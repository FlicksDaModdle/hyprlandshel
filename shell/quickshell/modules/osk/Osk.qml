import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"
import "Keys.js" as Keys

// The on-screen keyboard.
//
// A strip along the bottom of the screen that types into whatever window
// has the focus — which means it must never take the focus itself.
// `keyboardFocus: None` is the whole reason this works: a layer surface
// that held the keyboard would make the application behind it inactive,
// and there would be nothing left to type into.
//
// It reserves no space either. A keyboard that pushed every window up
// would reflow the thing you are typing into each time it appeared,
// which is worse than covering the bottom of it.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: osk
        required property var modelData

        screen: modelData ?? null
        readonly property bool hasScreen: !!modelData

        visible: hasScreen && Config.UiState.oskOpen && !Config.UiState.locked
        color: "transparent"

        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        WlrLayershell.namespace: "quickshell:osk"
        WlrLayershell.layer: WlrLayer.Overlay
        // Never. See above — the application being typed into has to stay
        // the focused one.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // ── size ──────────────────────────────────────────────────────
        //
        // A share of the screen rather than a fixed height, so it is the
        // same keyboard on a laptop panel and on a monitor, and capped so
        // it does not become a wall on a tall screen.
        readonly property real maxWidth: Math.min(osk.screen ? osk.screen.width - 32 : 1100, 1180)
        readonly property real units: Keys.widestRow()
        readonly property real gap: 5
        readonly property real pad: 12
        readonly property real keyW:
            Math.max(26, (maxWidth - pad * 2 - (units - 1) * gap) / units)
        readonly property real keyH: Math.max(30, Math.min(48, keyW * 0.92))

        implicitHeight: pad * 2 + Keys.ROWS.length * keyH
                        + (Keys.ROWS.length - 1) * gap + 26

        readonly property bool shifted:
            Services.Keyboard.isHeld("shift") !== Services.Keyboard.isHeld("caps")

        PanelSurface {
            id: sheet
            anchors.fill: parent
            anchors.margins: 8
            anchors.bottomMargin: Config.Appearance.dockLeft ? 8 : 8
            seamLead: 40

            // ── the strip across the top ──────────────────────────────
            Item {
                id: bar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 26

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: "KEYBOARD"
                    font.pixelSize: Config.Appearance.fs(10)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                    color: Config.Appearance.ink3
                }

                // Said once, where it matters: without wtype this types
                // letters and not much else, and a key that quietly does
                // nothing is the worst way to find that out.
                StyledText {
                    anchors.centerIn: parent
                    visible: Services.Keyboard.limited || Services.Keyboard.broken
                    text: Services.Keyboard.broken
                          ? "Nothing here can type — install wtype"
                          : "Symbols need wtype; install it for the full keyboard"
                    font.pixelSize: Config.Appearance.fs(10)
                    color: Config.Appearance.accent
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    radius: Config.Appearance.rSm
                    color: closeHover.hovered ? Config.Appearance.hover : "transparent"

                    MonoIcon {
                        anchors.centerIn: parent
                        name: "x"
                        size: 12
                        monochrome: true
                        inkColor: Config.Appearance.ink3
                    }

                    HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Config.UiState.oskOpen = false }
                }
            }

            // ── the keys ──────────────────────────────────────────────
            Column {
                anchors.top: bar.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: osk.gap

                Repeater {
                    model: Keys.ROWS

                    Row {
                        id: keyRow
                        required property var modelData
                        spacing: osk.gap

                        Repeater {
                            model: keyRow.modelData

                            Rectangle {
                                id: cap
                                required property var modelData

                                readonly property var act:
                                    Keys.actionFor(cap.modelData, osk.shifted)
                                readonly property bool isMod: !!(cap.act && cap.act.mod)
                                readonly property bool lit:
                                    cap.isMod && Services.Keyboard.isHeld(cap.act.mod)

                                width: (cap.modelData.w || 1) * osk.keyW
                                       + ((cap.modelData.w || 1) - 1) * osk.gap
                                height: osk.keyH
                                radius: Config.Appearance.rSm

                                color: cap.lit ? Config.Appearance.accent
                                     : capArea.pressed ? Config.Appearance.sel
                                     : capHover.hovered ? Config.Appearance.hover
                                     : Config.Appearance.surface

                                StyledText {
                                    anchors.centerIn: parent
                                    text: Keys.labelFor(cap.modelData, osk.shifted)
                                    font.pixelSize: Config.Appearance.fs(
                                        cap.modelData.c !== undefined
                                        && cap.modelData.label === undefined ? 14 : 11)
                                    font.weight: cap.isMod ? Font.DemiBold : Font.Medium
                                    color: cap.lit ? Config.Appearance.inkOnAccent
                                         : cap.isMod ? Config.Appearance.ink2
                                         : Config.Appearance.ink
                                }

                                HoverHandler { id: capHover }

                                // A MouseArea rather than a TapHandler: a
                                // keyboard is held down, and auto-repeat
                                // needs a press and a release rather than
                                // a tap.
                                MouseArea {
                                    id: capArea
                                    anchors.fill: parent

                                    function fire() {
                                        const a = cap.act;
                                        if (!a) return;
                                        if (a.mod) { Services.Keyboard.hold(a.mod); return; }
                                        if (a.key) { Services.Keyboard.sendKey(a.key); return; }
                                        if (a.text) Services.Keyboard.sendText(a.text);
                                    }

                                    onPressed: {
                                        fire();
                                        // Modifiers do not repeat; holding
                                        // shift down is what latching is
                                        // instead of.
                                        if (!cap.isMod) repeat.restart();
                                    }
                                    onReleased: { repeat.stop(); fast.stop(); }
                                    onCanceled: { repeat.stop(); fast.stop(); }
                                }

                                // Held down, a key repeats — after a pause,
                                // then quickly, the way a real one does.
                                Timer {
                                    id: repeat
                                    interval: 420
                                    onTriggered: fast.start()
                                }
                                Timer {
                                    id: fast
                                    interval: 45
                                    repeat: true
                                    onTriggered: capArea.fire()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
