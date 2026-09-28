// The browser's own pages — Settings and Add-ons — in the shell's colours.
//
// They are pages, not part of the window, so the window's stylesheets never
// reach them. But they run inside the browser with the same privileges as
// its interface, so each one is caught as it opens and given the palette
// and css/pages.css the same way a window is, and the palette is swapped in
// them live along with the windows.
//
// Almost all of their look comes from Firefox's design tokens, which inherit
// into their components; pages.css maps those onto the palette. The one
// thing a stylesheet cannot see is which entry of the side navigation is
// selected — each entry keeps that inside its own shadow tree — so it is
// copied out here, onto the entry, as hs-selected.
import { Theme } from "resource://hyprshell/Theme.sys.mjs";

const SHEET = "resource://hyprshell/css/pages.css";

// about:settings is another name for about:preferences.
const PAGES = /^about:(preferences|settings|addons)(?=[?#]|$)/;

export const Pages = {
  start() {
    Services.obs.addObserver(this, "document-element-inserted");
  },

  observe(doc, topic) {
    if (topic !== "document-element-inserted") return;
    try {
      const uri = doc.documentURI || "";
      if (!PAGES.test(uri) || !doc.nodePrincipal?.isSystemPrincipal) return;
      const win = doc.defaultView;
      if (!win) return;
      Theme.attach(win, SHEET);
      doc.documentElement.setAttribute("hyprshell", "");
      win.addEventListener("DOMContentLoaded", () => this.watchNav(doc), { once: true });
    } catch (e) {
      // A page that does not take the design is still a working page.
      Cu.reportError("hyprshell: page setup failed: " + e);
    }
  },

  watchNav(doc) {
    const seen = new WeakSet();
    const follow = async el => {
      if (seen.has(el)) return;
      seen.add(el);
      await el.updateComplete;
      const button = el.shadowRoot?.querySelector("button");
      if (!button) return;
      const sync = () => el.toggleAttribute("hs-selected", button.hasAttribute("selected"));
      sync();
      new doc.defaultView.MutationObserver(sync)
        .observe(button, { attributes: true, attributeFilter: ["selected"] });
    };
    const scan = () => {
      for (const el of doc.querySelectorAll("moz-page-nav-button")) follow(el);
    };
    scan();
    // Entries that appear later — Add-ons fills its list in after loading.
    new doc.defaultView.MutationObserver(scan)
      .observe(doc.documentElement, { childList: true, subtree: true });
  },
};
