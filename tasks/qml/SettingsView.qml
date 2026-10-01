import QtQuick
import Hyprshell
import Hyprshell.Backend

// How the task manager itself behaves.
Item {
    id: view
    property var frame: null

    component Setting: Item {
        id: s
        property string label: ""
        property string note: ""
        default property alias control: holder.data
        width: parent ? parent.width : 600
        height: Math.max(48, texts.implicitHeight + 16)
        Column {
            id: texts
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - holder.width - 20
            spacing: 2
            StyledText { text: s.label; font.pixelSize: Appearance.fs(13); font.weight: Font.Medium }
            StyledText { visible: text !== ""; width: parent.width; wrapMode: Text.WordWrap; text: s.note; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
        }
        Item {
            id: holder
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: col.implicitHeight + 30
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Column {
            id: col
            x: 20; y: 6
            width: Math.min(760, flick.width - 40)
            ViewHeader { width: parent.width; title: "Settings"; subtitle: "How often it looks, and how it shows what it sees" }
            Setting {
                label: "Update speed"
                note: "How often everything is read. Faster costs a little more processor; minimised, it always slows down."
                Seg {
                    options: [{ label: "0.5 s", value: 500 }, { label: "1 s", value: 1000 }, { label: "2 s", value: 2000 }, { label: "5 s", value: 5000 }]
                    value: Tasks.settings.interval
                    onPicked: v => { Tasks.set("interval", v); Monitor.interval = v; }
                }
            }
            Setting {
                label: "Smooth graphs"
                note: "Graphs glide at the display's own rate between readings instead of stepping once a reading. Costs a few percent of one core while a graph is on screen."
                Switch { checked: Tasks.settings.smooth; onToggled: on => Tasks.set("smooth", on) }
            }
            Setting {
                label: "Graphs show"
                Seg {
                    options: [{ label: "1 min", value: 60 }, { label: "2 min", value: 120 }, { label: "5 min", value: 300 }]
                    value: Tasks.settings.span
                    onPicked: v => Tasks.set("span", v)
                }
            }
            Setting {
                label: "Keep exited processes"
                note: "A process that ends stays a moment as a red row, so whatever just vanished can be seen to have gone."
                Seg {
                    options: [{ label: "Off", value: 0 }, { label: "5 s", value: 5 }, { label: "15 s", value: 15 }, { label: "30 s", value: 30 }]
                    value: Tasks.settings.tombstone
                    onPicked: v => { Tasks.set("tombstone", v); Monitor.processes.tombstoneSeconds = v; }
                }
            }
            Setting {
                label: "CPU per process"
                note: "As a share of the whole processor, as Windows shows it, or of one core, as top and htop do (a busy program can then read 400%)."
                Seg {
                    options: [{ label: "Whole processor", value: false }, { label: "One core", value: true }]
                    value: Tasks.settings.perCore
                    onPicked: v => { Tasks.set("perCore", v); Monitor.processes.perCore = v; }
                }
            }
            Setting {
                label: "Open on"
                SevenCombo {
                    width: 200
                    model: view.frame ? view.frame.allViews.map(v => ({ label: v.label, value: v.id })) : []
                    value: Tasks.settings.startView
                    onPicked: v => Tasks.set("startView", v)
                }
            }
            Setting {
                label: "Fold the side rail"
                note: "Just the glyphs. Clicking the rail's edge does the same."
                Switch { checked: Tasks.settings.navCollapsed; onToggled: on => Tasks.set("navCollapsed", on) }
            }
        }
    }
}
