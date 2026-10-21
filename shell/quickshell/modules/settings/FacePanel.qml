import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../../services" as Services
import "../common"

// Settings → Login screen → Your face (services/FaceUnlock.qml): what the
// face camera sees, with the face unlock lens over it to line your face up
// in, and adding it — your usual look, or an alternative one (glasses, a
// beard, a cap) for Howdy to know you by as well.
//
// The camera can be open in one place at a time, so the picture stops
// while Howdy records your face, and comes back when it's done.
Column {
    id: root

    readonly property var face: Services.FaceUnlock
    width: parent ? parent.width : 560
    spacing: 12

    Component.onDestruction: root.face.stopPreview()

    // ── the picture ─────────────────────────────────────────────────────
    ClippingRectangle {
        id: view
        width: root.width
        height: Math.round(width * 9 / 16)
        radius: Config.Appearance.rCard
        color: "#0d0c0c"

        Image {
            anchors.fill: parent
            visible: root.face.previewing && status === Image.Ready
            fillMode: Image.PreserveAspectFit
            cache: false
            asynchronous: false
            source: root.face.previewing ? "file://" + root.face.previewFile + "?" + root.face.previewFrame : ""
        }

        // The lens to line up in; the dot face inside it while Howdy is
        // recording, the tick when it's done.
        FaceScan {
            anchors.centerIn: parent
            size: Math.min(view.height * 0.62, 190)
            ink: Qt.rgba(1, 1, 1, 0.85)
            accent: Config.Appearance.accent
            state: root.face.justAdded ? "found" : "looking"
        }

        // Not showing anything yet.
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            spacing: 8
            visible: !root.face.previewing
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.face.busy ? root.face.status
                    : root.face.previewError !== "" ? root.face.previewError
                    : "See what the camera sees, and line your face up in the frame"
                font.pixelSize: Config.Appearance.fs(12)
                color: Qt.rgba(1, 1, 1, 0.75)
            }
            NetButton {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.face.busy && root.face.previewDevice !== ""
                label: "Show the camera"
                onClicked: root.face.startPreview()
            }
        }

        // Over the picture while it runs.
        Rectangle {
            visible: root.face.previewing
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            width: hint.implicitWidth + 24
            height: 28
            radius: 14
            color: Qt.rgba(0, 0, 0, 0.55)
            StyledText {
                id: hint
                anchors.centerIn: parent
                text: "Face in the frame, about an arm's length away"
                font.pixelSize: Config.Appearance.fs(12)
                color: "white"
            }
        }
    }

    // ── adding ──────────────────────────────────────────────────────────
    Row {
        spacing: 8
        NetButton {
            primary: true
            active: !root.face.busy
            label: root.face.faces > 0 ? "Add my face again" : "Add my face"
            onClicked: root.face.addFace(false)
        }
        NetButton {
            active: !root.face.busy
            label: "Add an alternative look"
            onClicked: root.face.addFace(true)
        }
        NetButton {
            visible: root.face.previewing
            label: "Hide the camera"
            onClicked: root.face.stopPreview()
        }
    }
    StyledText {
        width: root.width
        wrapMode: Text.Wrap
        text: root.face.faces > 0
              ? (root.face.faces + (root.face.faces === 1 ? " look enrolled. " : " looks enrolled. ")
                 + "An alternative look — with glasses, a beard, a cap, in other light — helps Howdy know you either way.")
              : "Add your face, then an alternative look if you sometimes wear glasses or look different."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
}
