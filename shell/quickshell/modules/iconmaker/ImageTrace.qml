import QtQuick
import "../icons/Trace.js" as Trace

// Reads an image file and hands back shapes.
//
// The pixels come out of a Canvas, which is the only thing in QtQuick
// that will give them up: an Image shows a picture and will not say what
// is in it. So the file is drawn into an offscreen canvas at a working
// size and read back with getImageData, which is a browser API that Qt
// implements and which does exactly what is wanted here.
//
// Drawn small on purpose. A 2000px logo has more boundary pixels than a
// 24-unit grid has places to put them, and tracing it full size costs
// seconds and produces thousands of nodes that all land on the same
// quarter unit anyway.
Item {
    id: root

    property url source: ""
    property int threshold: 128
    property real detail: 1
    // How big to trace at. 96 is four pixels per grid unit, which is
    // finer than anything the grid can express and cheap.
    property int traceSize: 96

    property bool busy: false
    property string note: ""

    signal traced(var shapes)
    signal failed(string reason)

    function run() {
        if (String(root.source) === "") return;
        root.busy = true;
        root.note = "";
        sheet.loadImage(root.source);
    }

    onSourceChanged: root.run()

    Canvas {
        id: sheet
        visible: false
        width: root.traceSize
        height: root.traceSize
        // Threaded would be better and is not available to something
        // that has to call back into JavaScript with the result.
        renderStrategy: Canvas.Immediate
        renderTarget: Canvas.Image

        onImageLoaded: requestPaint()
        onPaint: {
            if (String(root.source) === "" || !sheet.isImageLoaded(root.source)) return;
            const ctx = sheet.getContext("2d");
            ctx.reset();
            ctx.clearRect(0, 0, sheet.width, sheet.height);

            // Fitted, not stretched: a wide logo squashed into a square
            // traces as a squashed logo.
            const sz = sheet.imageSize(root.source);
            if (!sz || sz.width <= 0 || sz.height <= 0) {
                root.busy = false;
                root.failed("That file has no picture in it.");
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
