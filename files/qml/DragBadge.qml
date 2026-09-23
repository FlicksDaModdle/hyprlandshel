import QtQuick
import Hyprshell

// What the cursor carries during a drag.
//
// One badge for both views, deliberately: grabbing the delegate itself gave
// a tidy square in the grid and the entire full-width row in the list, so
// the same drag looked like two different gestures. This is a small chip —
// glyph, name, and a count when there is more than one — and it looks the
// same wherever the drag started.
//
// It lives off to the side of the window rather than being hidden, because
// an item that is not rendered grabs as nothing. Nobody sees it there.
Item {
    id: badge

    required property var app
    readonly property var svc: FilesService

    // The image the drag actually uses. Re-grabbed whenever the selection
    // changes, which happens on the click that precedes the drag, so the
    // picture is ready before the pointer has moved its threshold.
    property url image: ""

    readonly property var lead: {
        const names = badge.app.selection;
        if (!names.length) return null;
        return badge.app.visibleEntries.find(e => e.name === names[0]) || null;
    }
    readonly property int count: badge.app.selection.length

    x: -4000
    y: 0
    width: chip.width
    height: chip.height

    Rectangle {
        id: chip
        width: Math.min(260, content.implicitWidth + 22)
        height: 38
        radius: Appearance.rSm
        color: Appearance.sheet
        border.width: 1
        border.color: Appearance.accent

        Row {
            id: content
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: badge.lead ? badge.svc.iconFor(badge.lead) : "file"
                size: 22
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, 150)
                text: badge.lead ? badge.lead.name : ""
                elide: Text.ElideMiddle
                font.pixelSize: Appearance.fs(12)
                font.weight: Font.Medium
            }

            // "and 3 more", as a count rather than a stack of chips: the
            // number is the useful part and a pile of overlapping tiles is
            // just harder to read.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: badge.count > 1
                width: countLabel.implicitWidth + 12
                height: 20
                radius: 10
                color: Appearance.accent

                StyledText {
                    id: countLabel
                    anchors.centerIn: parent
                    text: "+" + (badge.count - 1)
                    font.pixelSize: Appearance.fs(11)
                    font.weight: Font.DemiBold
                    color: Appearance.inkOnAccent
                }
            }
        }
    }

    // Grabbing on every keystroke of a shift-range would be a render target
    // per step, so it settles first.
    Timer {
        id: settle
        interval: 40
        onTriggered: badge.regrab()
    }

    function regrab() {
        if (!badge.lead) { badge.image = ""; return; }
        badge.grabToImage(function (result) { badge.image = result.url; });
    }

    Connections {
        target: badge.app
        function onSelectionChanged() { settle.restart(); }
    }
}
