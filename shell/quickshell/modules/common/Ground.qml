import QtQuick
import "../../config" as Config
import "../background"

// What the desktop shows, drawn again for the lock screen and the greeter:
// the live video (Settings → Wallpaper → Live), else the picture, the
// contour map, the animated style, or the theme's gradient — the same
// choice in the same order as the desktop, so locking and logging in look
// like the desktop they belong to.
//
// The greeter reads it from a copy of your theme whose paths point at
// copies of your picture and video it can read (see greeter/README.md).
Item {
    id: ground

    // The screen it is on, for where an animation's terrain or field is.
    property var screen: null
    // Whether animations and the video move. The lock screen and greeter
    // keep them going; nothing else decides here.
    property bool running: true
    // Where the animation starts: the desktop's own point in it, for the
    // lock screen, so locking doesn't jump the picture back to the start.
    property var phase: null

    readonly property var prefs: Config.Appearance
    readonly property string style: prefs.wallpaperStyle
    readonly property string imagePath: prefs.wallpaper || ""
    // The video, as the desktop picks it: the one chosen, or this screen's
    // own when each screen has its own.
    readonly property string videoPath: {
        let v = prefs.liveWallpaper || "";
        if (prefs.liveLayout === "each") {
            try {
                const m = JSON.parse(prefs.liveScreens || "{}") || {};
                const name = ground.screen ? String(ground.screen.name) : "";
                if (name && m[name]) v = m[name];
            } catch (e) {}
        }
        return /\.(mp4|m4v|webm|mkv|mov|avi|ogv|gif)$/i.test(v) ? v : "";
    }

    readonly property bool useImage: imagePath !== ""
    readonly property bool useTopo: !useImage && style === "topo"
    readonly property bool useAnimated: !useImage && !useTopo && style !== "gradient" && style !== ""
    readonly property bool showsVideo: video.status === Loader.Ready && !!video.item && video.item.playing
    // A picture of something — a photo, a video, an animation — rather than
    // the theme's own quiet ground: what is written over it wants a scrim
    // and light ink to read, whatever the theme.
    readonly property bool vivid: (useImage && picture.status === Image.Ready) || useAnimated || showsVideo

    // Under a picture too: one that can't be read — the greeter's own
    // copy of a theme naming a file in your home folder — leaves the
    // theme's gradient, not a black screen.
    GradientGround {
        anchors.fill: parent
        visible: !ground.useTopo && !ground.useAnimated
    }

    Loader {
        anchors.fill: parent
        active: ground.useTopo
        sourceComponent: Topography { screen: ground.screen; running: ground.running; startPhase: ground.phase }
    }

    Loader {
        anchors.fill: parent
        active: ground.useAnimated
        sourceComponent: AnimatedWallpaper { screen: ground.screen; running: ground.running; startPhase: ground.phase }
    }

    Image {
        id: picture
        anchors.fill: parent
        visible: ground.useImage
        source: ground.useImage ? "file://" + ground.imagePath : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: width
        sourceSize.height: height
    }

    // The video over all of it, fading in once it plays; what is under it
    // shows while it loads, and stays if it can't be played. A file of its
    // own, loaded by name, so a Qt without QtMultimedia loses only this.
    Loader {
        id: video
        anchors.fill: parent
        active: ground.videoPath !== ""
        source: active ? "VideoGround.qml" : ""
        onLoaded: {
            item.path = Qt.binding(() => ground.videoPath);
            item.running = Qt.binding(() => ground.running);
            item.scaling = Qt.binding(() => ground.prefs.liveScaling || "fill");
        }
    }
}
