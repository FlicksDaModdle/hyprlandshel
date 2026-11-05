// Writes ui/icons.slint from the shell's glyphs (shell/quickshell/modules/icons/IconPaths.js),
// so the Rust shell draws exactly the icons the QML one does.
//   node rshell/tools/gen-icons.js
const fs = require("fs"), path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../../shell/quickshell/modules/icons/IconPaths.js"), "utf8")
    .replace(/^\.pragma library/m, "");
const icons = new Function(src + "\nreturn icons;")();
const kebab = s => s.replace(/[A-Z]/g, m => "-" + m.toLowerCase());
const q = s => JSON.stringify(s || "");
let out = "// Generated from shell/quickshell/modules/icons/IconPaths.js by rshell/tools/gen-icons.js:\n"
        + "// the shell's own glyphs, so the Rust shell draws exactly the same icons.\n"
        + "export struct GlyphData { ink: string, acc: string, ink-w: string, acc-w: string, fill: string, fill-ink: string, "
        + "dot-x: float, dot-y: float, dot-r: float, dot-acc: bool }\n\nexport global Icons {\n";
const seen = new Set();
for (const name of Object.keys(icons)) {
    const g = icons[name], k = kebab(name);
    if (seen.has(k)) continue;
    seen.add(k);
    const d = (g.dots && g.dots[0]) || null;
    out += `    out property <GlyphData> ${k}: { ink: ${q(g.ink)}, acc: ${q(g.acc)}, ink-w: ${q(g.inkW)}, acc-w: ${q(g.accW)}, `
         + `fill: ${q(g.fill)}, fill-ink: ${q(g.fillInk)}, dot-x: ${d ? d.cx : 0}, dot-y: ${d ? d.cy : 0}, `
         + `dot-r: ${d ? d.r : 0}, dot-acc: ${d && d.c === "acc" ? "true" : "false"} };\n`;
}
fs.writeFileSync(path.join(__dirname, "../ui/icons.slint"), out + "}\n");
console.log(seen.size + " glyphs → rshell/ui/icons.slint");
