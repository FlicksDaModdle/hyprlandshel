import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Polkit
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"
import "../settings"

// The session's polkit agent: what asks for your password when something
// wants to act as administrator — pkexec, systemctl on a system service, the
// task manager ending another user's process, a mount, a firmware update.
//
// Hyprland starts no agent of its own, and without one every one of those
// requests fails at once with "no authentication agent", which reads as
// "not allowed" rather than "nobody asked".
//
// Loaded from a URL by shell.qml, since Quickshell.Services.Polkit is a
// build option: on a build without it this file fails to load and nothing
// else is affected. If another agent (polkit-gnome, hyprpolkitagent, KDE's)
// is already running, registration fails, this stays dormant and that one
// keeps answering.
Scope {
    id: root

    PolkitAgent {
        id: agent
        onIsRegisteredChanged: if (isRegistered) console.log("polkit: answering authentication requests")
        onAuthenticationRequestStarted: {
            prompt.response = "";
            prompt.reveal = false;
        }
    }

    // Shared across the per-screen windows, so moving focus between monitors
    // mid-prompt doesn't lose what was typed.
    QtObject {
        id: prompt
        property string response: ""
        property bool reveal: false
        property bool busy: false
        readonly property var flow: agent.flow
        function submit() {
            if (!flow || prompt.busy) return;
            prompt.busy = true;
            flow.submit(prompt.response);
            prompt.response = "";
        }
        function cancel() { if (flow) flow.cancelAuthenticationRequest(); }
    }
    Connections {
        target: prompt.flow
        ignoreUnknownSignals: true
        // A wrong password restarts the conversation; asking again is what
        // turns busy back off.
        function onIsResponseRequiredChanged() { if (prompt.flow.isResponseRequired) prompt.busy = false; }
        function onAuthenticationFailed() { prompt.busy = false; }
        function onAuthenticationSucceeded() { prompt.busy = false; }
        function onAuthenticationRequestCancelled() { prompt.busy = false; }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData ?? null

            readonly property bool here: !!modelData && Services.Compositor.isFocusedScreen(modelData)
            visible: agent.isActive && !!prompt.flow && here

            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.namespace: "hyprshell-polkit"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            onVisibleChanged: if (visible) field.input.forceActiveFocus()

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.45)
                MouseArea { anchors.fill: parent }    // a click outside is not "cancel"
            }

            PanelSurface {
                id: card
                anchors.centerIn: parent
                width: 420
                height: body.implicitHeight + 44

                Column {
                    id: body
                    x: 22; y: 24
                    width: card.width - 44
                    spacing: 12

                    Row {
                        spacing: 12
                        Rectangle {
                            width: 36; height: 36
                            radius: 18
                            color: Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.16)
                            MonoIcon {
                                anchors.centerIn: parent
                                name: "lock"
                                size: 20
                                inkColor: Config.Appearance.ink
                                accentColor: Config.Appearance.accent
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            StyledText {
                                text: "Authentication required"
                                font.pixelSize: Config.Appearance.fs(15)
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                text: prompt.flow && prompt.flow.selectedIdentity
                                      ? "As " + (prompt.flow.selectedIdentity.displayName || prompt.flow.selectedIdentity.string)
                                      : ""
                                font.pixelSize: Config.Appearance.fs(12)
                                color: Config.Appearance.ink3
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: prompt.flow ? prompt.flow.message : ""
                        font.pixelSize: Config.Appearance.fs(13)
                        color: Config.Appearance.ink2
                    }

                    // More than one identity can answer when several users
                    // are administrators; the first is polkit's choice.
                    Flow {
                        width: parent.width
                        spacing: 6
                        visible: !!prompt.flow && prompt.flow.identities.length > 1
                        Repeater {
                            model: prompt.flow ? prompt.flow.identities : []
                            NetButton {
                                required property var modelData
                                label: modelData.displayName || modelData.string
                                primary: prompt.flow && prompt.flow.selectedIdentity === modelData
                                onClicked: prompt.flow.selectedIdentity = modelData
                            }
                        }
                    }

                    NetField {
                        id: field
                        width: parent.width
                        label: prompt.flow && prompt.flow.inputPrompt ? prompt.flow.inputPrompt.replace(/:\s*$/, "") : "Password"
                        secret: !prompt.flow || !prompt.flow.responseVisible
                        reveal: prompt.reveal
                        text: prompt.response
                        onEdited: t => prompt.response = t
                        onAccepted: prompt.submit()
                        input.enabled: !prompt.busy
                        Keys.onEscapePressed: prompt.cancel()
                    }

                    StyledText {
                        width: parent.width
                        visible: text !== ""
                        wrapMode: Text.WordWrap
                        text: !prompt.flow ? ""
                            : prompt.flow.supplementaryMessage !== "" ? prompt.flow.supplementaryMessage
                            : prompt.flow.failed ? "That wasn't right. Try again."
                            : ""
                        font.pixelSize: Config.Appearance.fs(12)
                        color: prompt.flow && (prompt.flow.supplementaryIsError || prompt.flow.failed)
                               ? Config.Appearance.accent : Config.Appearance.ink3
                    }

                    Item {
                        width: parent.width
                        height: 32
                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: prompt.flow ? prompt.flow.actionId : ""
                            elide: Text.ElideRight
                            width: parent.width - buttons.width - 12
                            font.pixelSize: Config.Appearance.fs(10.5)
                            color: Config.Appearance.ink3
                        }
                        Row {
                            id: buttons
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            NetButton { label: "Cancel"; onClicked: prompt.cancel() }
                            NetButton {
                                label: prompt.busy ? "Checking…" : "Authenticate"
                                primary: true
                                active: !prompt.busy
                                onClicked: prompt.submit()
                            }
                        }
                    }
                }
            }
        }
    }
}
