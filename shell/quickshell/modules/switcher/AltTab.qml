import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services

// The Alt+Tab overlay, on the output it was opened from.
//
// It takes the keyboard while it is up, so the arrow keys, Enter, Escape
// and Delete reach it and not the window underneath. Tab itself does not:
// Hyprland's Alt+Tab bind takes that before any client sees it, and it
// arrives through services/Switcher.qml like the first press did.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win
        required property var modelData

        screen: modelData ?? null
        readonly property bool here: {
            if (!modelData || !Services.Switcher.shown) return false;
            const want = Services.Switcher.screenName;
            return want !== "" ? modelData.name === want
                               : Quickshell.screens[0] === modelData;
        }

        visible: here && !Config.UiState.locked
        color: "transparent"

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        WlrLayershell.namespace: "quickshell:switcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: here ? WlrKeyboardFocus.Exclusive
                                          : WlrKeyboardFocus.None

        readonly property real us:
            Config.Appearance.screenScale(modelData ? modelData.name : "")

        // A light dim, and a click on it is a change of mind.
        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: Config.Appearance.dark ? 0.28 : 0.16
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onClicked: Services.Switcher.cancel()
            }
        }

        SwitcherCard {
            id: card
            anchors.centerIn: parent
            entries: Services.Switcher.entries
            index: Services.Switcher.index
            style: Config.Appearance.altTabStyle
            sizePct: Config.Appearance.altTabSize
            showTags: Config.Appearance.altTabWorkspaceTags
            us: win.us
            maxWidth: Math.max(320, win.width * 0.86)

            onHoveredEntry: i => Services.Switcher.select(i)
            onPicked: i => { Services.Switcher.select(i); Services.Switcher.commit(); }
            onCloseRequested: i => Services.Switcher.closeEntry(i)
        }

        Item {
            id: keys
            focus: true

            Keys.onPressed: event => {
                const S = Services.Switcher;
                const back = (event.modifiers & Qt.ShiftModifier) !== 0;
                switch (event.key) {
                case Qt.Key_Escape:
                    S.cancel(); break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    S.commit(); break;
                // Only reaches here when Hyprland did not take it — the
                // modifier already let go in the wait-for-Enter mode.
                case Qt.Key_Tab:
                    S.step(back ? -1 : 1); break;
                case Qt.Key_Backtab:
                    S.step(-1); break;
                case Qt.Key_Left:
                case Qt.Key_Up:
                    S.step(-1); break;
                case Qt.Key_Right:
                case Qt.Key_Down:
                    S.step(1); break;
                case Qt.Key_Home:
                    S.select(0); break;
                case Qt.Key_End:
                    S.select(S.entries.length - 1); break;
                case Qt.Key_Delete:
                    S.closeEntry(S.index); break;
                default:
                    return;
                }
                event.accepted = true;
            }

            // The quick way to notice the release, once this window has the
            // keyboard. The switcher polls for it as well, because a quick
            // Alt+Tab is over before this window ever gets focus.
            Keys.onReleased: event => {
                if (Services.Switcher.isModKey(event.key)) {
                    Services.Switcher.releaseSeen();
                    event.accepted = true;
                }
            }
        }

        onHereChanged: if (here) keys.forceActiveFocus()
    }
}
