// Hyprshell Browser's control symbols, in the shell's own icon language.
//
//   node browser/tools/gen-icons.js
//
// The shell draws its icons from shell/quickshell/modules/icons/IconPaths.js:
// 24-unit glyphs of 2px round strokes, ink, with one detail picked out in the
// accent. The browser's buttons are drawn the same way, and where the shell
// already has a glyph for something — home, download, reload, star, lock,
// search, settings — that glyph is used as it is, read from the same file, so
// the two can never drift apart.
//
// Firefox paints chrome SVGs with two colours from the element that uses
// them: context-fill for the ink and context-stroke for the accent. chrome.css
// sets those to currentColor and the shell's accent, so every symbol follows
// hover, disabled and a change of accent without a second copy of anything.
const fs = require("fs");
const path = require("path");
const ROOT = path.join(__dirname, "..", "..");
const OUT = path.join(ROOT, "browser", "app", "hyprshell", "icons");

// The shell's table, loaded as it is. It is a QML JS library; the pragma line
// is the only thing plain JavaScript does not accept.
const src = fs.readFileSync(path.join(ROOT, "shell/quickshell/modules/icons/IconPaths.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const shell = new Function(src + "\nreturn { icons, circle, ellipse, rrect, join };")();
const { circle, rrect, join } = shell;
const S = shell.icons;

// Glyphs the shell has no need for, drawn to the same rules.
const own = {
  back:       { ink: "M19 12H6", acc: "M11 6.5L5.5 12L11 17.5" },
  forward:    { ink: "M5 12H18", acc: "M13 6.5L18.5 12L13 17.5" },
  stop:       { ink: "M6.5 6.5L17.5 17.5", acc: "M17.5 6.5L6.5 17.5" },
  menu:       { ink: "M4.5 6.5H19.5 M4.5 17.5H19.5", acc: "M4.5 12H14" },
  extensions: { ink: join(rrect(4, 4, 7, 7, 2), rrect(4, 13, 7, 7, 2), rrect(13, 13, 7, 7, 2)),
                acc: rrect(13, 4, 7, 7, 2) },
  reader:     { ink: "M12 7.2C10 5.7 7.2 5.2 4 5.6V18.4C7.2 18 10 18.5 12 20C14 18.5 16.8 18 20 18.4V5.6C16.8 5.2 14 5.7 12 7.2Z",
                acc: "M12 7.2V20" },
  newtab:     { ink: "M12 5V19", acc: "M5 12H19" },
  close:      { ink: "M6.5 6.5L17.5 17.5 M17.5 6.5L6.5 17.5" },
  minimize:   { ink: "M6 12H18" },
  maximize:   { ink: rrect(5.5, 5.5, 13, 13, 2.5) },
  restore:    { ink: rrect(4.5, 8.5, 11, 11, 2.5), acc: "M8.5 5.5H16a2.5 2.5 0 0 1 2.5 2.5V15.5" },
  sidebar:    { ink: rrect(3.5, 4.5, 17, 15, 2.5), acc: "M9.5 4.5V19.5" },
  account:    { ink: join(circle(12, 12, 8.5), circle(12, 10, 3)),
                acc: "M6.8 17.8C8 15.9 9.9 15 12 15S16 15.9 17.2 17.8" },
  bookmark:   { ink: "M7 4.5H17V20L12 16.5L7 20Z", acc: "M10 9H14" },
  history:    { ink: circle(12, 12, 8.5), acc: "M12 7.5V12L15.2 14.2" },
  private:    { ink: "M3.5 10.5C3.5 8 5.5 6.5 8 6.5C9.6 6.5 10.8 7.4 12 7.4S14.4 6.5 16 6.5C18.5 6.5 20.5 8 20.5 10.5C20.5 14 18 16.5 15.5 16.5C13.8 16.5 13 15 12 15S10.2 16.5 8.5 16.5C6 16.5 3.5 14 3.5 10.5Z",
                acc: "M7 11H10 M14 11H17" },
  lockopen:   { ink: rrect(4.5, 10.5, 15, 9, 2), acc: "M8 10.5V7.5A4 4 0 0 1 15.6 5.8" },
  newwindow:  { ink: rrect(3.5, 4.5, 17, 15, 2.5), acc: "M12 9V15 M9 12H15" },
  print:      { ink: join("M7 9V4.5H17V9", rrect(3.5, 9, 17, 7.5, 2), "M7 14H17V19.5H7Z"), acc: "M16.5 11.8H16.6" },
  save:       { ink: "M12 4.5V13.5 M4.5 17V19.5H19.5V17", acc: "M8.5 10.5L12 14L15.5 10.5" },
  zoom:       { ink: join(circle(10.5, 10.5, 6.5), "M15.4 15.4L20.5 20.5"), acc: "M10.5 8V13 M8 10.5H13" },
  fullscreen: { ink: "M4.5 9V4.5H9 M15 4.5H19.5V9 M19.5 15V19.5H15 M9 19.5H4.5V15" },
  passwords:  { ink: join(circle(8, 15, 3.5), "M10.5 12.5L19 4"), acc: "M16 7L18.5 9.5" },
  more:       { dots: [{ cx: 5.5, cy: 12, r: 1.5, c: "ink" }, { cx: 12, cy: 12, r: 1.5, c: "ink" },
                       { cx: 18.5, cy: 12, r: 1.5, c: "acc" }] },
  help:       { ink: circle(12, 12, 8.5), acc: "M9.6 9.6a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .9-1 1.6V14",
                dots: [{ cx: 12, cy: 16.8, r: 1.1, c: "acc" }] },
};

// The shell's glyphs, used as they are.
const fromShell = {
  home: "home", reload: "rotateCw", downloads: "download", star: "star",
  lock: "lock", shield: "shield", search: "search", settings: "settings",
  chevron: "chevronDown", info: "info", trash: "trash", find: "search",
};

// The shell's shield carries its check in ink; in the address bar the concept
// wants it whole in accent, which the CSS does by giving both colours the
// accent. Here the check is moved to the accent layer so that the plain
// shield, elsewhere, reads as the other glyphs do.
function shieldSplit(g) {
  const [body, check] = g.ink.split(" M9 12");
  return { ink: body, acc: "M9 12" + check };
}

function svg(g) {
  const parts = [];
  const layer = (d, stroke, w) => d && parts.push(
    `<path d="${d}" fill="none" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`);
  layer(g.ink, "context-fill", 2);
  layer(g.inkW, "context-fill", 3);
  layer(g.acc, "context-stroke", 2);
  layer(g.accW, "context-stroke", 3);
  if (g.fill) parts.push(`<path d="${g.fill}" fill="context-stroke"/>`);
  for (const d of g.dots || [])
    parts.push(`<circle cx="${d.cx}" cy="${d.cy}" r="${d.r}" fill="${d.c === "acc" ? "context-stroke" : "context-fill"}"/>`);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24">${parts.join("")}</svg>\n`;
}

fs.mkdirSync(OUT, { recursive: true });
for (const f of fs.readdirSync(OUT)) if (f.endsWith(".svg")) fs.unlinkSync(path.join(OUT, f));
let n = 0;
const write = (name, g) => { fs.writeFileSync(path.join(OUT, name + ".svg"), svg(g)); n++; };
for (const [name, g] of Object.entries(own)) write(name, g);
for (const [name, key] of Object.entries(fromShell)) {
  if (!S[key]) throw new Error("the shell has no glyph " + key);
  write(name, key === "shield" ? shieldSplit(S[key]) : S[key]);
}
// A bookmarked page: the star, filled.
write("star-filled", { ink: S.star.ink, fill: S.star.ink });
console.log(n + " symbols written to " + path.relative(ROOT, OUT));
