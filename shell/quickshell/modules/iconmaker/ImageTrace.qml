import QtQuick
import "../icons/Trace.js" as Trace

// Reads an image file and hands back shapes.
//
// The pixels come out of a Canvas, which is the only thing in QtQuick
// that will give them up: an Image shows a picture and will not say what
// is in it. So the file is drawn into a canvas at a working size and
// read back with getImageData.
//
// Two things about that canvas are load-bearing, and both were wrong the
// first time — with the same symptom, "Tracing…" for ever, on an image
// of any size:
//
//   It has to be inside a window. This lived beside the FloatingWindow
//   rather than in it, so it was in no scene at all; nothing ever
//   polished it, onPaint never ran, and the flag that says "working"
//   was never cleared. A Canvas outside a window is not slow, it is
//   inert.
//
//   And it cannot be `visible: false`, which takes an item out of the
//   render path and stops it painting. It is placed off the side of the
//   window instead, where it is in the scene and out of sight.
//
// Drawn small on purpose. A 2000px logo has more boundary pixels than a
// 24-unit grid has places to put them, and tracing it full size costs
// seconds and produces thousands of nodes that all land on the same
// quarter unit anyway. So the source can be any size at all — it is
// scaled to `traceSize` before anything looks at it.
Item {
    id: root

    property url source: ""
    property int threshold: 128
    property real detail: 1
    // 96 is four pixels per grid unit, which is finer than the grid can
    // express and costs about a millisecond.
    property int traceSize: 96

    property bool busy: false
    property string note: ""

    signal traced(var shapes)
    signal failed(string reason)

    // Only paint events we asked for produce a result. A Canvas is
    // painted for its own reasons too — being shown, being resized —
    // and a stray one would trace whatever was last drawn a second time.
    property bool wanted: false

    function run() {
        if (String(root.source) === "") return;
        root.busy = true;
        root.wanted = true;
        root.note = "";
        watchdog.restart();
        if (sheet.isImageLoaded(root.source)) sheet.requestPaint();
        else sheet.loadImage(root.source);
    }

    function give(reason) {
        root.busy = false;
        root.wanted = false;
        watchdog.stop();
        root.failed(reason);
    }

    onSourceChanged: root.run()

    // Nothing here should take a second, let alone for ever. If it does,
    // say so: a spinner that never stops tells you nothing about what
    // went wrong, and this one ran for a week.
    Timer {
        id: watchdog
        interval: 8000
        onTriggered: {
            if (!root.busy) return;
            root.give(sheet.isImageError(root.source)
                      ? "Could not read that file — is it an image?"
                      : "Gave up reading that image.");
        }
    }

    Canvas {
        id: sheet
        // Off the side of the window: in the scene, so it paints, and
        // out of the way, so it is not seen. See the note above.
        x: -8192
        y: -8192
        width: root.traceSize
        height: root.traceSize
        renderStrategy: Canvas.Immediate
        renderTarget: Canvas.Image

        onImageLoaded: if (root.wanted) sheet.requestPaint()
        onPaint: {
            if (!root.wanted) return;
            if (String(root.source) === "") { root.give("No file."); return; }
            if (sheet.isImageError(root.source)) {
                root.give("Could not read that file — is it an image?");
                return;
            }
            if (!sheet.isImageLoaded(root.source)) return;   // still coming

            root.wanted = false;
            watchdog.stop();

            const ctx = sheet.getContext("2d");
            ctx.reset();
            ctx.clearRect(0, 0, sheet.width, sheet.height);

            // Fitted, not stretched: a wide logo squashed into a square
            // traces as a squashed logo.
            const sz = sheet.imageSize(root.source);
            if (!sz || sz.width <= 0 || sz.height <= 0) {
                root.give("That file has no picture in it.");
                return;
            }
            const k = Math.min(sheet.width / sz.width, sheet.height / sz.height);
            const w = Math.max(1, Math.round(sz.width * k));
            const h = Math.max(1, Math.round(sz.height * k));
            ctx.drawImage(root.source, Math.round((sheet.width - w) / 2),
                          Math.round((sheet.height - h) / 2), w, h);

            const img = ctx.getImageData(0, 0, sheet.width, sheet.height);
            const px = img.data;
            const count = sheet.width * sheet.height;

            // Which channel says what the logo is.
            //
            // Transparency, when there is any. A logo saved on a flat
            // white background has none — every pixel is opaque, the
            // whole square traces as one block, and the answer looks
            // like a bug rather than like the wrong file. So when
            // nothing is transparent, darkness stands in for it, which
            // is right for a dark mark on a light ground and is said
            // out loud below rather than guessed at silently.
            let clear = 0;
            for (let i = 0; i < count; i++) if (px[i * 4 + 3] < 250) clear++;
            const useAlpha = clear > count * 0.02;

            const mask = new Array(count);
            for (let i = 0; i < count; i++) {
                if (useAlpha) {
                    mask[i] = px[i * 4 + 3];
                } else {
                    // Rec. 601 luma, inverted: dark ink on light paper.
                    const l = 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1]
                              + 0.114 * px[i * 4 + 2];
                    mask[i] = 255 - l;
                }
            }

            const out = Trace.trace(mask, sheet.width, sheet.height,
                                    { threshold: root.threshold, detail: root.detail });
            root.busy = false;
            if (out.error) { root.failed(out.error); return; }
            root.note = useAlpha ? "" : "No transparency in that file — traced the dark parts.";
            root.traced(out.shapes);
        }
    }
}
