import QtQuick

// The HDR calibration test pattern (HdrCalibration.qml): a checkerboard of
// the test level on its ground. When the two are the same light, as when
// the panel clips both, it is a plain square: the pattern "isn't visible".
Grid {
    id: grid

    property int cells: 5
    property color ground: "black"
    property color ink: "white"

    columns: cells
    rows: cells
    Repeater {
        model: grid.cells * grid.cells
        Rectangle {
            required property int index
            width: grid.width / grid.cells
            height: grid.height / grid.cells
            readonly property bool on: (Math.floor(index / grid.cells) + index % grid.cells) % 2 === 0
            color: on ? grid.ink : grid.ground
        }
    }
}
