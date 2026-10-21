import QtQuick
import QtMultimedia

// The webcam, live, for FacePanel's circle while Howdy records your face
// through the infrared camera. Qt's own camera, drawn straight to the
// screen: no files, and it closes with the panel (or the shell).
//
// A small format is asked for (640 wide at most, compressed if the camera
// offers it): the webcam and the infrared camera are often one USB device,
// and a big raw picture can leave the infrared one no bandwidth.
//
// Loaded by FacePanel through a Loader, so a system without Qt Multimedia
// shows the dot face instead of failing.
Item {
    id: root

    // /dev/videoN, from services/FaceUnlock.qml.
    property string device: ""
    property bool active: false
    // A picture is coming through.
    readonly property bool showing: root.active && camera.active && output.sourceRect.width > 0
    property string error: ""

    MediaDevices { id: devices }

    // The camera whose id is the device path (Qt's V4L2 backend names them
    // so), else the first that isn't infrared, else the default.
    readonly property var cameraDevice: {
        const all = devices.videoInputs;
        for (const c of all) if (String(c.id) === root.device) return c;
        for (const c of all) if (!/\bIR\b|infrared/i.test(c.description)) return c;
        return devices.defaultVideoInput;
    }

    readonly property var smallFormat: {
        const formats = root.cameraDevice ? root.cameraDevice.videoFormats : [];
        const jpeg = typeof VideoFrameFormat !== "undefined" ? VideoFrameFormat.Format_Jpeg : -1;
        let best = null, bestScore = -1;
        for (const f of formats) {
            const w = f.resolution.width;
            if (w > 640 || w < 320) continue;
            const score = (f.pixelFormat === jpeg ? 100000 : 0) + Math.min(30, f.maxFrameRate) * 1000 + w;
            if (score > bestScore) { bestScore = score; best = f; }
        }
        return best;
    }

    // Set only when there is one: the camera's own otherwise.
    function useSmallFormat() { if (root.smallFormat) camera.cameraFormat = root.smallFormat; }
    onSmallFormatChanged: useSmallFormat()
    Component.onCompleted: useSmallFormat()

    CaptureSession {
        camera: Camera {
            id: camera
            active: root.active && !!root.cameraDevice
            cameraDevice: root.cameraDevice
            onActiveChanged: console.info("FaceCamera:", active ? "on" : "off",
                                          root.cameraDevice ? String(root.cameraDevice.id) : "-",
                                          root.smallFormat ? root.smallFormat.resolution.width + "×" + root.smallFormat.resolution.height : "")
            onErrorOccurred: (error, errorString) => {
                root.error = errorString;
                console.warn("FaceCamera:", errorString);
            }
        }
        videoOutput: output
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: root.showing
        // As in a mirror.
        transform: Scale { origin.x: output.width / 2; xScale: -1 }
    }
}
