pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Config

// Glyphs you made yourself, kept beside the rest of the settings and
// loaded at runtime.
//
// The built-in pack (modules/icons/IconPaths.js) is a `.pragma library`,
// which is compiled in and cannot grow. This is the other half: the same
// shape of data, read from a file, and MonoIcon looks here for any name
// the pack does not have. Nothing else in the shell needs to know which
// of the two a glyph came from.
//
// The file is ~/.config/quickshell/hyprshell/icons.json:
//
//   { "version": 1,
//     "icons": {
//       "myGlyph": {
//         "ink":  "M4 4 L20 20",        stroke 2, ink colour
//         "acc":  "M4 20 L20 4",        stroke 2, accent colour
//         "inkW": "", "accW": "",       the heavier 3-wide variants
//         "fill": "",                   filled, accent
//         "dots": [{ "cx": 12, "cy": 12, "r": 1.5, "c": "acc" }],
//         "shapes": [ … ]               see below
//       } } }
//
// `shapes` is what the icon maker drew, and the five path strings are
// what that drawing came out as. Both are kept on purpose: a merged path
// cannot be taken apart again, so an icon saved without its shapes would
// render forever and never be editable again. MonoIcon ignores `shapes`
// entirely; the maker ignores the paths and re-derives them on save.
Singleton {
    id: root

    readonly property string path: Config.Appearance.configDir + "/icons.json"

    // name → spec, in the shape MonoIcon reads.
    property var icons: ({})

    // Whether the file has actually been read.
    //
    // This matters more than it looks. Saving rewrites the whole file
    // from `icons`, and `icons` starts empty — so a save made before the
    // read has landed writes an empty file over a full one and takes
    // every icon you ever made with it. Nothing about that is visible:
    // the icon you just saved is in memory and on screen, and the loss
    // only shows up at the next start, which is exactly how it was
    // reported.
    //
    // It is not a narrow race either. Quickshell's FileView cancels an
    // in-flight *read* when a write starts (cancelAsync disowns the
    // reader and drops it), so one early save does not just miss the
    // file — it stops `loaded` from ever arriving, and the store stays
    // empty for the rest of the session. Every later save then rewrites
    // the file from nothing.
    //
    // So: nothing writes until this is true, and put() makes it true by
    // reading first.
    property bool ready: false
    // In the order they were made, not alphabetical.
    //
    // A JavaScript object keeps its string keys in insertion order, and
    // both put() and parse() build the map by walking the old one and
    // adding to the end — so the newest glyph is last here, last in the
    // file, and last in the picker, which is where you look for the one
    // you just drew. Sorted, it landed somewhere around "g".
    readonly property var names: Object.keys(root.icons)

    function has(name) { return !!root.icons[name]; }
    function spec(name) { return root.icons[name] || null; }

    // Everything a glyph may carry. Anything else in the file is dropped
    // on the way in rather than handed to the renderer.
    readonly property var pathKeys: ["ink", "acc", "inkW", "accW", "fill", "fillInk"]

    // A hand-edited or half-written file should cost you your icons, not
    // your shell. Every field is checked and anything unrecognised is
    // left out, so the worst a broken entry can do is draw nothing.
    function clean(raw) {
        if (!raw || typeof raw !== "object") return null;
        const out = {};
        for (const k of root.pathKeys)
            if (typeof raw[k] === "string" && raw[k] !== "") out[k] = raw[k];

        if (Array.isArray(raw.dots)) {
            const dots = [];
            for (const d of raw.dots) {
                if (!d || typeof d !== "object") continue;
                const cx = Number(d.cx), cy = Number(d.cy), r = Number(d.r);
                // NaN fails every comparison, including against itself,
                // so this rejects it without naming it.
                if (!(cx >= -100 && cx <= 124)) continue;
                if (!(cy >= -100 && cy <= 124)) continue;
                if (!(r > 0 && r <= 24)) continue;
                dots.push({ cx: cx, cy: cy, r: r, c: d.c === "acc" ? "acc" : "ink" });
            }
            if (dots.length > 0) out.dots = dots;
        }

        // Carried through untouched for the maker to reopen, and never
        // looked at by anything that draws.
        if (Array.isArray(raw.shapes)) out.shapes = raw.shapes;

        // A glyph with no drawable part is not a glyph.
        const draws = root.pathKeys.some(k => out[k]) || (out.dots && out.dots.length > 0);
        return draws ? out : null;
    }

    // The one place the store is filled, so "we have read the file" and
    // "here is what was in it" can never disagree.
    function adopt(text) {
        root.parse(text);
        root.ready = true;
    }

    // Read the file now if it has not been read yet, and say whether the
    // store can be trusted afterwards.
    //
    // Asking for the text is what forces the read: `blockLoading` on the
    // FileView below makes text() wait for the file rather than handing
    // back an empty string while a read is still in the air, and the
    // read emits loaded or loadFailed on its way through.
    //
    // The return value is `ready` and nothing else — in particular this
    // does not adopt whatever text() gave back. A read that fails on
    // permissions also returns an empty string, and taking that for "you
    // have no icons" is the very thing being guarded against.
    function ensureLoaded() {
        if (root.ready) return true;
        file.text();
        return root.ready;
    }

    function parse(text) {
        if (!text || text.trim() === "") { root.icons = ({}); return; }
        let doc;
        try {
            doc = JSON.parse(text);
        } catch (err) {
            console.warn("UserIcons: icons.json is not valid JSON, ignoring it —", err);
            return;     // keep whatever was already loaded
        }
        const src = (doc && doc.icons) || {};
        const out = {};
        for (const name in src) {
            const g = root.clean(src[name]);
            if (g) out[name] = g;
        }
        root.icons = out;
    }

    function serialise() {
        return JSON.stringify({ version: 1, icons: root.icons }, null, 2) + "\n";
    }

    // Adds or replaces one glyph. `glyph` is cleaned on the way in for the
    // same reason the file is: the maker is not the only thing that could
    // ever call this.
    function put(name, glyph) {
        const g = root.clean(glyph);
        if (!name || !g) return false;
        // Refuses rather than saving one icon over all the others.
        if (!root.ensureLoaded()) return false;
        const next = {};
        for (const k in root.icons) next[k] = root.icons[k];
        next[name] = g;
        root.icons = next;
        root.flush();
        return true;
    }

    function remove(name) {
        if (!root.ensureLoaded()) return;
        if (!root.icons[name]) return;
        const next = {};
        for (const k in root.icons) if (k !== name) next[k] = root.icons[k];
        root.icons = next;
        root.flush();
    }

    // A missing file is written empty the moment it is found missing, so
    // that by the time anything saves there is a file to save into.
    //
    // The guard is the same one as everywhere else: a store that has not
    // read the file does not get to write it.
    function flush() {
        if (!root.ready) {
            console.warn("UserIcons: refusing to write " + root.path
                         + " before it has been read — nothing was saved.");
            return;
        }
        file.setText(root.serialise());
    }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false

        // Read it as soon as the store exists, and let text() block if
        // someone asks before that read has landed.
        //
        // The blocking is the point. This is a few kilobytes of JSON on
        // local disk — the case Quickshell's own documentation names for
        // blockLoading — and the alternative is a save racing the read
        // that should have told it what was already there.
        preload: true
        blockLoading: true
        // Every save completes before the click that caused it returns.
        // An async write can be cancelled by the next operation on this
        // view, and a cancelled write is silent.
        blockWrites: true

        // Edited by hand, or by a second shell instance. Either way the
        // icons on screen should be the ones in the file.
        onFileChanged: reload()
        onLoaded: root.adopt(file.text())

        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                // First run. Nothing to read is itself an answer: there
                // are no icons, and it is now safe to write.
                root.icons = ({});
                root.ready = true;
                file.setText(root.serialise());
                return;
            }
            // Anything else — a permission, a directory that is not
            // there — must not be read as "you have no icons", or the
            // next save would write that over the file that has them.
            // So the store stays not-ready, and saving refuses.
            console.warn("UserIcons: could not read " + root.path
                         + " (error " + error + "). Icons cannot be saved"
                         + " until this is fixed.");
        }

        // Writing is the whole point of this file, and it used to fail in
        // silence: printErrors is off, and there was no handler.
        onSaveFailed: error => {
            console.warn("UserIcons: could not write " + root.path
                         + " (error " + error + "). Your icons were not saved.");
        }
    }
}
