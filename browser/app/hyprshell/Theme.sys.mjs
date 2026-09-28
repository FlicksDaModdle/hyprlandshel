// The browser's colours: the shell's palette, loaded over the defaults, and
// reloaded the moment the shell rewrites it.
//
// userChrome.css is read once, when Firefox starts, which is why changing the
// accent in the shell used to change nothing until a restart. Here the
// palette is an ordinary stylesheet loaded into each window through
// windowUtils, so it can be taken out and put back: the file is checked every
// second and a half, and a new modification time swaps it in every open
// window at once.
import { setInterval } from "resource://gre/modules/Timer.sys.mjs";

const DEFAULTS = "resource://hyprshell/css/defaults.css";
const CHROME = "resource://hyprshell/css/chrome.css";

export const Theme = {
  windows: new Set(),
  path: "",
  mtime: -1,
  version: 0,
  // The palette as loaded — a file: URI with a version on it, because a
  // stylesheet is cached by URI and the same URI would reload the old one.
  current: null,
  // The palette's text as last read (null until then), and whoever wants
  // it each time it changes — NewTab.sys.mjs, which cannot load it by URI.
  text: null,
  listeners: [],

  init() {
    this.path = this.palettePath();
    this.check();
    setInterval(() => this.check(), 1500);
  },

  // hyprshell.palette overrides where to look; otherwise the file the shell
  // writes beside its theme.json.
  palettePath() {
    const own = Services.prefs.getStringPref("hyprshell.palette", "");
    if (own) return own;
    const env = Services.env;
    const base = env.get("XDG_CONFIG_HOME") || (env.get("HOME") + "/.config");
    return base + "/quickshell/hyprshell/firefox-colors.css";
  },

  async check() {
    let mtime = 0;
    let text = "";
    try {
      mtime = (await IOUtils.stat(this.path)).lastModified;
      text = await IOUtils.readUTF8(this.path);
    } catch (e) {
      mtime = 0;
    }
    if (mtime === this.mtime) return;
    this.mtime = mtime;
    this.version++;
    const next = mtime
      ? PathUtils.toFileURI(this.path) + "?v=" + this.version
      : null;
    for (const win of this.windows) this.swap(win, this.current, next);
    this.current = next;
    this.text = text;
    this.followScheme(text);
    for (const f of this.listeners) f(text);
  },

  // Web pages follow the shell's light or dark too, not only the toolbar.
  // 0 is dark, 1 light; with no palette the browser's own choice stands.
  followScheme(text) {
    const m = /color-scheme:\s*(dark|light)/.exec(text || "");
    if (!m) return;
    Services.prefs.setIntPref("layout.css.prefers-color-scheme.content-override",
                              m[1] === "dark" ? 0 : 1);
  },

  swap(win, old, next) {
    const u = win.windowUtils;
    if (old) {
      try { u.removeSheetUsingURIString(old, u.AUTHOR_SHEET); } catch (e) {}
    }
    if (next) u.loadSheetUsingURIString(next, u.AUTHOR_SHEET);
  },

  // Defaults first and the palette after them, so the palette wins at equal
  // specificity; the design itself only reads the variables, so where it
  // falls in the order does not matter.
  //
  // A window takes chrome.css; the browser's own pages (Pages.sys.mjs) take
  // their own sheet over the same palette.
  attach(win, sheet = CHROME) {
    const u = win.windowUtils;
    u.loadSheetUsingURIString(DEFAULTS, u.AUTHOR_SHEET);
    if (this.current) u.loadSheetUsingURIString(this.current, u.AUTHOR_SHEET);
    u.loadSheetUsingURIString(sheet, u.AUTHOR_SHEET);
    this.windows.add(win);
    win.addEventListener("unload", () => this.windows.delete(win), { once: true });
  },
};
