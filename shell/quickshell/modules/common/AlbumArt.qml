import QtQuick
import Quickshell.Widgets
import "../../config" as Config

// The cover of whatever is playing, with the mockup's accent record mark
// behind it.
//
// The mark is not a placeholder for a picture that is coming — it is what
// the design draws, and roughly half of what plays on a desktop has no
// artwork at all (a stream, a local file with no embedded cover, a browser
// tab). So the mark is always there and the picture is laid over it once
// it has actually loaded, which also covers the moment between a track
// change and the new image arriving: the tile stays a tile instead of
// flashing empty.
Item {
    id: root

    // Whatever MPRIS handed over. Players are not consistent about the
    // form, so see `url` below.
    property string source: ""
    property real radius: Config.Appearance.rTile

    // The mark's proportions, taken from the two sizes the mockup draws:
    // a 22px tile with a 9px ring, a 2.5px dot and a 1.5px ring stroke,
    // and a 78px tile with 34, 9 and 2. Both fall out of these.
    readonly property real ring: Math.round(width * 0.43)
    readonly property real dot: width * 0.115
    readonly property real ringWidth: 1.5 + Math.max(0, width - 22) / 112

    // A URL Image will actually accept.
    //
    // Most players give a file:// or https:// URL and a few give a bare
    // path, which QUrl reads as *relative* — so it would be resolved
    // against this QML file's directory and quietly fail. Anything else
    // (an empty string, a scheme Qt has no handler for) is left to fail
    // its load, which the mark already covers.
    readonly property string url: {
        const s = root.source.trim();
        if (s === "") return "";
        if (/^[a-z][a-z0-9+.\-]*:/i.test(s)) return s;
        if (s.charAt(0) === "/") return "file://" + s;
        return "";
    }

    readonly property bool hasArt: art.status === Image.Ready

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Config.Appearance.accent

        // The record: a ring with a spindle hole, drawn as two circles
        // rather than an icon because it is the one piece of art in the
        // shell that is part of the layout rather than a glyph.
        Rectangle {
            anchors.centerIn: parent
            width: root.ring
            height: root.ring
            radius: width / 2
            color: "transparent"
            border.width: root.ringWidth
            border.color: Config.Appearance.inkOnAccent

            Rectangle {
                anchors.centerIn: parent
                width: root.dot
                height: root.dot
                radius: width / 2
                color: Config.Appearance.inkOnAccent
            }
        }
    }

    ClippingRectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        visible: root.hasArt

        Image {
            id: art
            anchors.fill: parent
            source: root.url
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            // Covers are frequently 1000px square and are drawn here at 22
            // or 78, so the full-size texture is pure waste. Rounded up to
            // twice the drawn size so it still has something to give on a
            // scaled output.
            sourceSize.width: Math.max(16, Math.round(root.width * 2))
            sourceSize.height: Math.max(16, Math.round(root.height * 2))
            // Players that cache art to a fixed path — one cover.jpg
            // rewritten per track — would otherwise show the previous
            // track's picture for as long as the shell ran, because the URL
            // never changed and Qt's cache is keyed on the URL.
            cache: false
        }
    }

    // Hairline inside the tile, as on the mockup's 78px art.
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Config.Appearance.rule
    }
}
