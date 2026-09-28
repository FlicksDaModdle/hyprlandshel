// Hyprshell Browser: run hyprshell.cfg, from this install's own directory,
// with chrome privileges at startup. This is Firefox's autoconfig — the
// mechanism enterprises use to lock settings down — and it is what lets the
// browser's own interface be rebuilt rather than only restyled.
//
// The sandbox is off because the file does more than set prefs: it loads
// the interface modules in hyprshell/ into every browser window.
pref("general.config.filename", "hyprshell.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);
