import QtQuick
import QtMultimedia

// The live wallpaper's video, for Ground.qml: looping, silent, filling the
// screen the way Settings → Wallpaper → Live scales it, and fading in once
// the first frame is up.
Item {
    id: vg

    property string path: ""
    property bool running: true
    property string scaling: "fill"      // fill | fit | stretch

    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo

    opacity: playing ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

    MediaPlayer {
        id: player
        source: vg.path !== "" ? "file://" + vg.path : ""
        loops: MediaPlayer.Infinite
        videoOutput: output
        // No audioOutput: a login screen makes no sound.
        onSourceChanged: vg.apply()
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: vg.scaling === "fit" ? VideoOutput.PreserveAspectFit
                : vg.scaling === "stretch" ? VideoOutput.Stretch
                : VideoOutput.PreserveAspectCrop
    }

    function apply() {
        if (vg.running && vg.path !== "") player.play();
        else player.pause();
    }
    onRunningChanged: apply()
    Component.onCompleted: apply()
}
