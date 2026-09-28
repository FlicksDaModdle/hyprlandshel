// Everything that happens to a browser window as it opens.
import { Theme } from "resource://hyprshell/Theme.sys.mjs";
import { Layout } from "resource://hyprshell/Layout.sys.mjs";
import { UrlView } from "resource://hyprshell/UrlView.sys.mjs";

const HTML = "http://www.w3.org/1999/xhtml";

export const Window = {
  attach(win) {
    const doc = win.document;
    doc.documentElement.setAttribute("hyprshell", "");
    Theme.attach(win);
    Layout.apply();
    this.bead(doc);
    this.divider(doc);
    UrlView.attach(win);
    this.rename(win);
  },

  // "Configuration — Hyprshell", not "— Mozilla Firefox": the title the bar,
  // the dock and Alt+Tab show. Tabbrowser builds the title from the brand it
  // read when the window opened, so the one call that builds it is wrapped
  // and the brand swapped for this browser's name.
  rename(win) {
    const gBrowser = win.gBrowser;
    const doc = win.document;
    const brand = (doc.getElementById("mainWindowTitle") || {}).textContent || "";
    if (!gBrowser || !brand || gBrowser.hyprshellRenamed) return;
    const ours = Services.prefs.getStringPref("hyprshell.name", "Hyprshell");
    const original = gBrowser.getWindowTitleForBrowser.bind(gBrowser);
    gBrowser.getWindowTitleForBrowser = browser =>
      original(browser).split(brand).join(ours);
    gBrowser.hyprshellRenamed = true;
    gBrowser.updateTitlebar();
  },

  // The accent bead at the head of the title row, as on every window in the
  // concept — the mark of which window has focus.
  bead(doc) {
    const tabs = doc.getElementById("TabsToolbar");
    if (!tabs || doc.getElementById("hs-bead")) return;
    const bead = doc.createElementNS(HTML, "div");
    bead.id = "hs-bead";
    tabs.prepend(bead);
  },

  // The thin rule between the page's buttons and the menu.
  divider(doc) {
    const menu = doc.getElementById("PanelUI-button");
    if (!menu || doc.getElementById("hs-navdiv")) return;
    const d = doc.createElementNS(HTML, "div");
    d.id = "hs-navdiv";
    menu.before(d);
  },
};
