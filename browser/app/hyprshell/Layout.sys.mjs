// Where the toolbar buttons go: the concept's order, set once per profile.
//
// Once, and versioned, because after that the arrangement is yours — Firefox's
// own Customize still works, and anything moved there stays moved. Bumping
// VERSION re-applies it, which is only for when the design itself changes.
const VERSION = 1;

export const Layout = {
  apply() {
    if (Services.prefs.getIntPref("hyprshell.layout", 0) >= VERSION) return;
    const { CustomizableUI } = ChromeUtils.importESModule(
      "moz-src:///browser/components/customizableui/CustomizableUI.sys.mjs");

    // back · forward · reload · home | address | downloads · extensions
    // — and the menu, which is not a movable widget, sits after them.
    const nav = ["back-button", "forward-button", "stop-reload-button", "home-button",
                 "urlbar-container", "downloads-button", "unified-extensions-button"];
    for (const id of CustomizableUI.getWidgetIdsInArea("nav-bar")) {
      // The springs are what kept the address bar from filling the row.
      if (/^customizableui-special-spring/.test(id) || id === "vertical-spacer")
        CustomizableUI.removeWidgetFromArea(id);
    }
    // Not in the concept; still one right-click → Customize away.
    for (const id of ["fxa-toolbar-menu-button", "reset-pbm-toolbar-button"]) {
      try { CustomizableUI.removeWidgetFromArea(id); } catch (e) {}
    }
    nav.forEach((id, i) => {
      try { CustomizableUI.addWidgetToArea(id, "nav-bar", i); } catch (e) {}
    });

    // Shown from the start, as in the concept, rather than after the first
    // download.
    Services.prefs.setBoolPref("browser.download.autohideButton", false);
    Services.prefs.setIntPref("hyprshell.layout", VERSION);
  },
};
