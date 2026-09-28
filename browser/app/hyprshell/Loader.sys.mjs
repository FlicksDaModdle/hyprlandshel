// Finds every browser window as it opens and hands it to Window.sys.mjs.
import { Theme } from "resource://hyprshell/Theme.sys.mjs";
import { Window } from "resource://hyprshell/Window.sys.mjs";

export const Loader = {
  started: false,
  start() {
    if (this.started) return;
    this.started = true;
    Theme.init();
    Services.obs.addObserver(this, "browser-delayed-startup-finished");
  },
  observe(win, topic) {
    if (topic !== "browser-delayed-startup-finished") return;
    try {
      Window.attach(win);
    } catch (e) {
      // A window that fails to take the design is still a working browser.
      Cu.reportError("hyprshell: window setup failed: " + e + "\n" + (e.stack || ""));
    }
  },
};
