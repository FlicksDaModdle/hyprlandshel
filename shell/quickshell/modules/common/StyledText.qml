import QtQuick
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

    Component.onCompleted: {
        // Tabular numerals stop the clock, percentages and counts shuffling
        // width as their digits change.
        //
        // font.features arrived in Qt 6.7, so this feature-tests the property
        // itself rather than probing a version: Quickshell.hasQtVersion only
        // exists on recent Quickshell builds, and calling it on an older one
        // throws once per Text object in the shell.
        try {
            if (font.features !== undefined) font.features = ({ tnum: 1 });
        } catch (e) {
            // Older Qt — proportional digits, a purely cosmetic loss.
        }
    }
}
