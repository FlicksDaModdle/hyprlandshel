// The new tab page and the home page in the shell's colours.
//
// Unlike Settings they are not drawn by the browser's own process: Firefox
// puts them in a content process of their own, which Pages.sys.mjs never
// sees and which is sandboxed away from ~/.config, where the palette lives.
// So the stylesheet goes to them rather than them fetching it. The defaults,
// the palette and css/newtab.css are read here, joined into one sheet
// scoped to those two pages, and registered with the stylesheet service,
// which hands it to every process — pages already open included. When the
// palette changes the sheet is rebuilt and swapped.
import { Theme } from "resource://hyprshell/Theme.sys.mjs";

const SOURCES = ["resource://hyprshell/css/defaults.css",
                 "resource://hyprshell/css/newtab.css"];

// Firefox Home is both: about:home for a new window, about:newtab for a tab.
const SCOPE = '@-moz-document url-prefix("about:newtab"), url-prefix("about:home") {\n';

export const NewTab = {
  sources: null,
  current: null,

  start() {
    Theme.listeners.push(text => this.update(text));
    if (Theme.text !== null) this.update(Theme.text);
  },

  // A resource: URL to the file behind it, so it can be read as text.
  async read(url) {
    const res = Services.io.getProtocolHandler("resource")
      .QueryInterface(Ci.nsIResProtocolHandler);
    const file = Services.io.newURI(res.resolveURI(Services.io.newURI(url)))
      .QueryInterface(Ci.nsIFileURL).file;
    return IOUtils.readUTF8(file.path);
  },

  async update(palette) {
    try {
      if (!this.sources) this.sources = await Promise.all(SOURCES.map(u => this.read(u)));
      const [defaults, rules] = this.sources;
      // The page sets its own color-scheme, and it would otherwise win over
      // a stylesheet like this one: the palette's is repeated so it holds.
      const m = /color-scheme:\s*(dark|light)/.exec(palette || "");
      const scheme = m ? `:root { color-scheme: ${m[1]} !important; }\n` : "";
      const css = SCOPE + defaults + "\n" + (palette || "") + "\n" + scheme + rules + "\n}\n";
      const next = Services.io.newURI("data:text/css;charset=utf-8," + encodeURIComponent(css));

      const sss = Cc["@mozilla.org/content/style-sheet-service;1"]
        .getService(Ci.nsIStyleSheetService);
      // A user sheet: it is what outranks the page's own !important
      // declarations, the way userContent.css does.
      sss.loadAndRegisterSheet(next, sss.USER_SHEET);
      if (this.current && sss.sheetRegistered(this.current, sss.USER_SHEET))
        sss.unregisterSheet(this.current, sss.USER_SHEET);
      this.current = next;
    } catch (e) {
      Cu.reportError("hyprshell: new tab sheet failed: " + e);
    }
  },
};
