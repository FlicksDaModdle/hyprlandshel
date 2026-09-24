import QtQuick
import Quickshell.Io
import "../icons/Trace.js" as Trace
import "../icons/Svg.js" as Svg

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

    // An SVG is already the answer.
    //
    // It is a list of curves. Rasterising it to 96 pixels and walking
    // the staircase back out gives an approximation of something exact,
    // and every logo imported that way came back soft where it should
    // have been crisp. So SVG files are read and only bitmaps are
    // traced.
    readonly property bool isSvg: /\.svgz?($|\?)/i.test(String(root.source))

    function run() {
        if (String(root.source) === "") return;
        root.busy = true;
        root.wanted = true;
        root.note = "";
        watchdog.restart();

        if (root.isSvg) {
            // A reload rather than a first read: the path may not have
            // changed, and the sliders do not apply to this path anyway.
            svgFile.reload();
            return;
        }
        if (root.canvasCan("loadImage")) sheet.loadImage(root.source);
        // The probe may already have it, in which case nothing else is
        // coming and the paint has to be asked for.
        if (probe.status === Image.Ready) sheet.requestPaint();
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
    FileView {
        id: svgFile
        path: root.isSvg ? String(root.source).replace(/^file:\/\//, "") : ""
        printErrors: false
        onLoaded: {
            if (!root.wanted) return;
            root.wanted = false;
            let out;
            try {
                out = Svg.parse(svgFile.text());
            } catch (err) {
                root.give("Could not read that SVG: " + err);
                return;
            }
            root.busy = false;
            watchdog.stop();
            if (out.error) { root.failed(out.error); return; }
            root.note = out.note || "";
            root.traced(out.shapes);
        }
        onLoadFailed: if (root.wanted) root.give("Could not open that file.")
    }

    Timer {
        id: watchdog
        interval: 8000
        onTriggered: {
            if (!root.busy) return;
            root.give(probe.status === Image.Error
                      ? "Could not read that file — is it an image?"
                      : "Gave up reading that image.");
        }
    }

    // What size the file is.
    //
    // Canvas has an imageSize() in the documentation and not in every
    // build — on this one it is simply not a function, and the
    // TypeError came out of the middle of the paint handler where it
    // took the whole trace with it. An Image knows its own dimensions
    // and has a status that says whether the file was readable at all,
    // which is better information than Canvas offers anyway.
    Image {
        id: probe
        source: root.source
        // Never shown — by being off the side of the window, not by
        // being invisible. Invisibility is what stopped the Canvas
        // beside it from ever painting, and there is no reason to find
        // out the hard way whether it also affects loading.
        x: -8192
        y: -8192
        asynchronous: true
        cache: false

        // The scaling happens here, not on the canvas.
        //
        // drawImage was being asked to fit the picture into the 24-unit
        // square and was drawing it at full size instead, so a 361px
        // logo landed in a 96px canvas and only its top-left corner was
        // traced — the answer looked like a crop because it was one.
        //
        // sourceSize is a bound on the loaded image, aspect preserved,
        // and it is the well-trodden path: every Image in every QML
        // application uses it. For an SVG it is better than a bound —
        // the file is rasterised at this size rather than at its
        // nominal one and then resampled, so the trace sees clean edges
        // instead of somebody else's scaling.
        sourceSize.width: root.traceSize
        sourceSize.height: root.traceSize
        onStatusChanged: {
            if (status === Image.Error && root.wanted)
                root.give("Could not read that file — is it an image?");
            else if (status === Image.Ready && root.wanted)
                sheet.requestPaint();
        }
    }

    // Which of Canvas's methods this build actually has.
    //
    // imageSize() is in the documentation and was not in the binary, and
    // it took a TypeError in the middle of a signal handler to find out.
    // There is no reason to believe the rest are guaranteed either, so
    // nothing here is called without asking first, and the Image below
    // is the fallback for everything it can answer.
    function canvasCan(fn) { return typeof sheet[fn] === "function"; }

    // How big the loaded image actually is, after sourceSize has bounded
    // it. implicitWidth and implicitHeight are that; sourceSize is only
    // what was asked for.
    function loadedSize() {
        if (probe.status !== Image.Ready) return null;
        const w = probe.implicitWidth, h = probe.implicitHeight;
        // Finite and positive, checked rather than assumed: a NaN slips
        // through `w <= 0` untouched, and a NaN width is what turns a
        // scale factor into Infinity and a draw into a crop.
        if (!(w > 0) || !(h > 0) || !isFinite(w) || !isFinite(h)) return null;
        return Qt.size(w, h);
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
            if (root.canvasCan("isImageError") && sheet.isImageError(root.source)) {
                root.give("Could not read that file — is it an image?");
                return;
            }
            if (root.canvasCan("isImageLoaded") && !sheet.isImageLoaded(root.source))
                return;                                       // still coming
            if (probe.status !== Image.Ready) return;         // size not known yet

            // The watchdog stays armed until there is an answer. It used
            // to be stopped here, at the top, which is exactly when it
            // was still needed: the TypeError below fired two lines
            // later, the handler unwound, and nothing was left running
            // to notice that "Tracing…" would never end.
            root.wanted = false;

            // Anything at all that goes wrong in here has to come back
            // out as a message. A QML exception inside a signal handler
            // is printed and swallowed: the handler stops where it
            // stood, whatever it was in the middle of stays half done,
            // and the only sign is a line in a log nobody is reading.
            try {
                const ctx = sheet.getContext("2d");
                ctx.reset();
                ctx.clearRect(0, 0, sheet.width, sheet.height);

                // Fitted, not stretched: a wide logo squashed into a square
                // traces as a squashed logo.
                const sz = root.loadedSize();
                if (!sz) {
                    root.give("That file has no picture in it.");
                    return;
                }
                // Already the right size, so this only centres it.
                const w = Math.min(sz.width, sheet.width);
                const h = Math.min(sz.height, sheet.height);
                const dx = Math.round((sheet.width - w) / 2);
                const dy = Math.round((sheet.height - h) / 2);
                // Two ways to name the picture, because only one of
                // them works and which one is not knowable from here.
                // The url is the documented form and wants the canvas to
                // have loaded it first; the Image item is already loaded
                // and is what works when loadImage is not there.
                //
                // Tried in turn, and judged by the result rather than by
                // whether it threw: drawImage draws nothing at all when
                // it does not recognise what it was handed, which is not
                // an error and would otherwise be reported as an image
                // with nothing in it.
                const count = sheet.width * sheet.height;
                let px = null;
                for (const what of [root.source, probe]) {
                    ctx.clearRect(0, 0, sheet.width, sheet.height);
                    try {
                        // Three arguments, not five: the picture is
                        // already the size it should be, and asking
                        // drawImage to resize it is what cropped it.
                        ctx.drawImage(what, dx, dy);
                    } catch (e) {
                        continue;
                    }
                    const got = ctx.getImageData(0, 0, sheet.width, sheet.height).data;
                    // Where did it actually land? Not just "did
                    // anything land", because a picture drawn at full
                    // size into a small canvas lands everywhere — and
                    // that is a crop, which passed as success once
                    // already and came back as a logo with three
                    // quarters missing.
                    let x0 = sheet.width, y0 = sheet.height, x1 = -1, y1 = -1;
                    for (let i = 0; i < count; i++) {
                        if (got[i * 4 + 3] === 0) continue;
                        const x = i % sheet.width, y = (i - x) / sheet.width;
                        if (x < x0) x0 = x;
                        if (x > x1) x1 = x;
                        if (y < y0) y0 = y;
                        if (y > y1) y1 = y;
                    }
                    if (x1 < 0) continue;                    // nothing drawn
                    if (x0 < dx - 1 || y0 < dy - 1
                        || x1 > dx + w || y1 > dy + h) continue;   // not where it was put
                    px = got;
                    break;
                }
                if (px === null) {
                    root.give("Could not draw that file into the grid — "
                              + "it may be empty, or too large to place.");
                    return;
                }

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
                watchdog.stop();
                if (out.error) { root.failed(out.error); return; }
                root.note = useAlpha ? "" : "No transparency in that file — traced the dark parts.";
                root.traced(out.shapes);
            } catch (err) {
                root.give("Could not trace that image: " + err);
            }
        }
    }
}
