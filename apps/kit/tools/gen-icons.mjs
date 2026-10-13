// Turns the shell's icon tables into icons.json for the Rust apps, so they
// draw the same glyphs: the shell's own (shell/quickshell/modules/icons/
// IconPaths.js) and the apps' (files/qml/IconPaths.js, which has the file
// and device glyphs), the shell's winning where both have a name.
// Run from apps/kit:  node tools/gen-icons.mjs
import fs from "node:fs";
import vm from "node:vm";
function load(file) {
    const src = fs.readFileSync(file, "utf8").replace(/^\.pragma.*$/m, "");
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src + "\n;globalThis.__icons = icons;", ctx);
    return ctx.__icons;
}
const tables = [load("../../files/qml/IconPaths.js"), load("../../shell/quickshell/modules/icons/IconPaths.js")];
const out = {};
for (const icons of tables) {
    for (const [k, v] of Object.entries(icons)) {
        if (!v || typeof v !== "object") continue;
        const e = {};
        for (const key of ["ink", "acc", "inkW", "accW", "fill", "fillInk"]) if (v[key]) e[key] = v[key];
        if (Array.isArray(v.dots) && v.dots.length) e.dots = v.dots.map(d => [d.cx, d.cy, d.r, d.c === "acc" ? 1 : 0]);
        out[k] = e;
    }
}
fs.writeFileSync("icons.json", JSON.stringify(out));
console.log(Object.keys(out).length + " icons");
