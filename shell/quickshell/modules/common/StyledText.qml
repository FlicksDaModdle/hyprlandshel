import QtQuick
import "../../config" as Config

// Every string in the shell is Inter with a tuned weight and size, so this
// fixes the family and sensible defaults in one place instead of repeating
// `font.family: "Inter"` several hundred times.
Text {
    font.family: Config.Appearance.fontFamily
    font.pixelSize: Config.Appearance.fs(12)   // callers override; scale still applies
    font.weight: Font.Medium
    color: Config.Appearance.ink
    textFormat: Text.PlainText

    // Native rasterising hints stems onto the pixel grid, which is what
    // makes small text look sharp rather than soft. Qt's default distance
    // field is smoother under arbitrary transforms and blurrier standing
    // still, and a shell is almost entirely small text standing still.
    //
    // Settable because it is the wrong choice under a fractional scale: a
    // natively rendered glyph cannot be resampled, so it lands between
    // pixels instead of on them.
    renderType: Config.Appearance.textNative ? Text.NativeRendering
                                             : Text.QtRendering


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
