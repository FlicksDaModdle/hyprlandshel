import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../../services" as Services
import "../common"

// Settings → Login screen → Your face (services/FaceUnlock.qml), set up the
// way Windows Hello does it: you see yourself in a circle, through the
// ordinary camera, while Howdy records your face through the infrared one
// beside it; the face unlock lens around the circle turns while it works
// and closes with a tick when it's done.
//
// Then the looks Howdy knows you by, each one removable. An alternative
// look is another set of pictures of you that Howdy compares against too —
// with glasses and without, a cap, a beard, daylight and lamplight — and
// it unlocks for whichever you match.
//
// With only the infrared camera, the picture is that camera's, and it
// pauses while Howdy records (a camera can be open in one place at a time).
Column {
    id: root

    readonly property var face: Services.FaceUnlock
    width: parent ? parent.width : 560
    spacing: 14

    Component.onDestruction: root.face.stopPreview()

    readonly property bool seeing: root.face.previewing && picture.status === Image.Ready

    // ── you, in the circle ──────────────────────────────────────────────
    Rectangle {
        id: stage
        width: root.width
        height: 318
        radius: Config.Appearance.rCard
        color: "#0d0c0c"

        readonly property real d: 196

        ClippingRectangle {
            id: circle
            anchors.horizontalCenter: parent.horizontalCenter
            y: 34
            width: stage.d
            height: stage.d
            radius: stage.d / 2
            color: "#191817"

            Image {
                id: picture
                anchors.fill: parent
                visible: root.seeing
                fillMode: Image.PreserveAspectCrop
                // As in a mirror.
                mirror: true
                cache: false
                asynchronous: false
                source: root.face.previewing ? "file://" + root.face.previewFile + "?" + root.face.previewFrame : ""
            }
            // Howdy has the only camera: the picture holds still, dimmed.
            Rectangle {
                anchors.fill: parent
                visible: root.seeing
                color: "black"
                opacity: root.face.adding && root.face.previewShared ? 0.45 : 0
            }
        }

        // The lens around the circle: still while nothing happens, turning
        // while Howdy records, closing with a tick when it has you.
        FaceScan {
            anchors.centerIn: circle
            size: stage.d + 30
            ink: Qt.rgba(1, 1, 1, 0.85)
            accent: Config.Appearance.accent
            showFace: !root.seeing
            state: root.face.justAdded ? "found"
                 : root.face.addFailed ? "failed"
                 : root.face.adding ? "looking" : "idle"
        }

        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: circle.bottom
            anchors.topMargin: 26
            width: parent.width - 48
            spacing: 4
            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.face.justAdded ? "All set"
                    : root.face.addFailed ? "Howdy didn't get a good look"
                    : root.face.adding ? "Keep looking at the camera"
                    : root.face.previewing ? "Centre your face in the circle"
                    : root.face.faces > 0 ? "Howdy knows your face" : "Set up your face"
                font.pixelSize: Config.Appearance.fs(16)
                font.weight: Font.DemiBold
                color: "white"
            }
            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.face.addFailed ? root.face.status
                    : root.face.adding ? (root.face.previewShared
                        ? "The infrared camera is recording: the picture waits until it's done"
                        : "The infrared camera beside it is learning your face. Hold still, an arm's length away")
                    : root.face.previewError !== "" ? root.face.previewError
                    : root.face.previewing ? "Then add your face: it takes a few seconds"
                    : root.face.faces > 0 ? "It unlocks for you at a glance. Wear glasses sometimes? Add that as an alternative look"
                    : "Add your face and Howdy unlocks for you at a glance"
                font.pixelSize: Config.Appearance.fs(12)
                color: Qt.rgba(1, 1, 1, 0.7)
            }
        }

        // The camera, on and off.
        NetButton {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 12
            visible: !root.face.adding && root.face.previewDevice !== ""
            label: root.face.previewing ? "Hide the camera" : "Show the camera"
            onClicked: root.face.previewing ? root.face.stopPreview() : root.face.startPreview()
        }
    }

    // ── adding ──────────────────────────────────────────────────────────
    Row {
        spacing: 8
        NetButton {
            primary: true
            active: !root.face.busy
            label: root.face.adding ? "Adding…" : root.face.faces > 0 ? "Add my face again" : "Add my face"
            onClicked: root.face.addFace(false)
        }
        NetButton {
            active: !root.face.busy && root.face.faces !== 0
            label: "Add an alternative look"
            onClicked: root.face.addFace(true)
        }
    }

    // ── the looks Howdy knows you by ────────────────────────────────────
    Column {
        width: root.width
        spacing: 6
        visible: root.face.looks !== null && root.face.looks.length > 0

        Repeater {
            model: root.face.looks || []
            delegate: Rectangle {
                required property var modelData
                width: root.width
                height: 44
                radius: Config.Appearance.rSm
                color: Config.Appearance.hover

                FaceScan {
                    id: mini
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    size: 26
                    ink: Config.Appearance.ink2
                    state: "idle"
                }
                Column {
                    anchors.left: mini.right
                    anchors.leftMargin: 10
                    anchors.right: remove.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: modelData.label
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: "Added " + Qt.formatDateTime(modelData.time, "d MMM yyyy, hh:mm")
                        font.pixelSize: Config.Appearance.fs(11)
                        color: Config.Appearance.ink3
                    }
                }
                NetButton {
                    id: remove
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    active: !root.face.busy
                    danger: true
                    label: "Remove"
                    onClicked: root.face.removeLook(modelData.id)
                }
            }
        }
    }

    StyledText {
        width: root.width
        wrapMode: Text.Wrap
        text: (root.face.looks === null && root.face.faces !== 0
               ? "Howdy keeps your looks where only root can read them, so they can't be listed here. " : "")
              + "An alternative look is another set of pictures of you that Howdy checks too, and it unlocks for "
              + "whichever you match: add one with glasses or without, in a cap, with a beard, in daylight and in lamplight."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
}
