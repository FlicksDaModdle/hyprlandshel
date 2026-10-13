// Turns the shell's icon table (shell/quickshell/modules/icons/IconPaths.js,
// a QML JavaScript library) into icons.json for the Rust apps, so they draw
// the same glyphs. Run from apps/kit:  node tools/gen-icons.mjs
import fs from "node:fs";
import vm from "node:vm";
const src = fs.readFileSync("../../shell/quickshell/modules/icons/IconPaths.js", "utf8")
    .replace(/^\.pragma.*$/m, "");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src + "\n;globalThis.__icons = icons;", ctx);
const out = {};
for (const [k, v] of Object.entries(ctx.__icons)) {
    if (!v || typeof v !== "object") continue;
    const e = {};
    for (const key of ["ink", "acc", "inkW", "accW", "fill", "fillInk"]) if (v[key]) e[key] = v[key];
    if (Array.isArray(v.dots) && v.dots.length) e.dots = v.dots.map(d => [d.cx, d.cy, d.r, d.c === "acc" ? 1 : 0]);
    out[k] = e;
}
fs.writeFileSync("icons.json", JSON.stringify(out));
console.log(Object.keys(out).length + " icons");
