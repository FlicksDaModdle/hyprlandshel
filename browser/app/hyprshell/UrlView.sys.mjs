// The address as the concept shows it: the host in full ink, everything else
// quieter — "quickshell.org" then "/docs/configuration".
//
// Firefox has a formatting pass of its own, but it paints the quiet part with
// a selection colour that no stylesheet can reach, which is why the CSS theme
// could never get this right. This draws the address itself, over the field,
// while nobody is editing it; the moment the field takes focus the drawing
// goes and the real input is there, untouched. It never changes what the
// field holds — only how it looks at rest.
const HTML = "http://www.w3.org/1999/xhtml";

export function splitAddress(shown, full) {
  let host = "";
  try {
    const u = new URL(full || shown);
    if (u.protocol === "http:" || u.protocol === "https:") host = u.hostname;
  } catch (e) {}
  if (!host) return { pre: "", host: shown, post: "" };
  const at = shown.toLowerCase().indexOf(host.toLowerCase());
  if (at < 0) return { pre: "", host: shown, post: "" };
  return { pre: shown.slice(0, at), host: shown.slice(at, at + host.length),
           post: shown.slice(at + host.length) };
}

export const UrlView = {
  attach(win) {
    const doc = win.document;
    const urlbar = doc.getElementById("urlbar");
    const box = urlbar && urlbar.querySelector(".urlbar-input-box");
    const input = doc.getElementById("urlbar-input");
    if (!box || !input || doc.getElementById("hs-urlview")) return;

    const view = doc.createElementNS(HTML, "div");
    view.id = "hs-urlview";
    const parts = ["pre", "host", "post"].map(k => {
      const s = doc.createElementNS(HTML, "span");
      s.className = "hs-" + k;
      view.append(s);
      return s;
    });
    box.append(view);

    const update = () => {
      const gURLBar = win.gURLBar;
      const shown = input.value;
      const editing = urlbar.hasAttribute("focused") || !shown
        || urlbar.hasAttribute("searchmode") || urlbar.hasAttribute("usertyping");
      if (editing) {
        urlbar.removeAttribute("hs-urlview");
        return;
      }
      const p = splitAddress(shown, gURLBar && gURLBar.untrimmedValue);
      parts[0].textContent = p.pre;
      parts[1].textContent = p.host;
      parts[2].textContent = p.post;
      urlbar.setAttribute("hs-urlview", "");
    };
    // After Firefox has done its own update for the same event.
    const soon = () => win.requestAnimationFrame(update);

    input.addEventListener("focus", soon);
    input.addEventListener("blur", soon);
    input.addEventListener("input", soon);
    win.gBrowser.tabContainer.addEventListener("TabSelect", soon);
    win.gBrowser.addProgressListener({
      QueryInterface: ChromeUtils.generateQI(["nsIWebProgressListener",
                                              "nsISupportsWeakReference"]),
      onLocationChange: soon,
    });
    new win.MutationObserver(soon).observe(urlbar, {
      attributes: true,
      attributeFilter: ["focused", "searchmode", "usertyping", "pageproxystate"],
    });
    update();
  },
};
