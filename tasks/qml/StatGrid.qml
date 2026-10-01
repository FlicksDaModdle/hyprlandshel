import QtQuick
import Hyprshell

// The big figures under a graph, then the fixed facts beside them.
Row {
    id: grid
    property var stats: []          // [{ label, value, big }]
    property var facts: []          // [{ label, value }]
    width: parent ? parent.width : 600
    spacing: 30
    Flow {
        width: grid.facts.length > 0 ? grid.width * 0.52 : grid.width
        spacing: 24
        Repeater {
            model: grid.stats
            Stat {
                required property var modelData
                width: modelData.wide ? 200 : 118
                label: modelData.label
                value: modelData.value
                big: modelData.big !== false
                valueColor: modelData.alert ? Appearance.accent : Appearance.ink
            }
        }
    }
    Column {
        visible: grid.facts.length > 0
        width: grid.width * 0.48 - 30
        spacing: 0
        Repeater {
            model: grid.facts
            KeyValue {
                required property var modelData
                width: parent.width
                labelWidth: Math.min(160, parent.width * 0.45)
                label: modelData.label
                value: modelData.value
            }
        }
    }
}
