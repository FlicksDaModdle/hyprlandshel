import QtQuick
import Quickshell
import "../../config" as Config

// Every string in the shell is Inter with a tuned weight and size, so this
// fixes the family and sensible defaults in one place instead of repeating
// `font.family: "Inter"` several hundred times.
Text {
    font.family: Config.Appearance.fontFamily
    font.pixelSize: 12
    font.weight: Font.Medium
    color: Config.Appearance.ink
    textFormat: Text.PlainText

    // The mockup puts font-variant-numeric: tabular-nums on every readout
    // (clock, percentages, counts) so digits don't shuffle width as they
    // change. font.features arrived in Qt 6.7; assigning it at runtime
    // behind a version check keeps the shell loading on 6.6.
    Component.onCompleted: {
        if (Quickshell.hasQtVersion(6, 7)) font.features = ({ "tnum": 1 });
    }
}
