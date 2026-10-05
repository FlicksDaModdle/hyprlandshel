pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// The editable half of the keybinds.
//
// Nothing here rewrites hyprland.lua. That file is hand-written, carries
// comments and logic, and a settings window that regenerated it would throw
// all of that away the first time you changed a shortcut. Instead the shell
// owns a second file — ~/.config/hypr/binds.lua — which hyprland.lua reads at
// the end of its own run, so whatever is in here wins over the defaults
// above it without touching them.
//
// The shortcuts themselves persist in theme.json as a key → accelerator map,
// so binds.lua can be regenerated from scratch at any time and is never the
// source of truth.
Singleton {
    id: root

    readonly property string hyprDir: (Quickshell.env("XDG_CONFIG_HOME")
                                       || (Quickshell.env("HOME") + "/.config")) + "/hypr"

    // Everything the shell exposes, with the default Hyprland writes when
    // nothing has been customised. `ipc` is the IpcHandler function in
    // shell.qml, reached through hyprshellctl exactly as hyprland.lua's own
    // binds reach it; `exec` launches one of the configured apps; `dsp` is a
    // raw Hyprland dispatcher instead.
    readonly property var actions: [
        { key: "launcher",    n: "Open launcher",        def: "Super_L",           ipc: "toggleLauncher", release: true },
        { key: "overview",    n: "Overview",             def: "SUPER + Tab",       ipc: "toggleOverview" },
        { key: "control",     n: "Control center",       def: "SUPER + C",         ipc: "toggleControlCenter" },
        { key: "notes",       n: "Notification center",  def: "SUPER + N",         ipc: "toggleNotifications" },
        { key: "dnd",         n: "Toggle do not disturb", def: "SUPER + SHIFT + N", ipc: "toggleDnd" },
        { key: "settings",    n: "Open settings",        def: "SUPER + comma",     ipc: "openSettings", arg: "Appearance" },
        { key: "theme",       n: "Toggle theme",         def: "SUPER + SHIFT + T", ipc: "toggleTheme" },
        { key: "reload",      n: "Reload shell",         def: "SUPER + SHIFT + R", ipc: "reloadShell" },
        { key: "lock",        n: "Lock screen",          def: "SUPER + L",         ipc: "lock" },
        { key: "showdesktop", n: "Show desktop",         def: "SUPER + D",         ipc: "showDesktop" },
        // Deliberately unbound. It is the one thing here that most
        // people never want and a few people need every day, and any
        // chord picked for it would be taken from something they do use.
        { key: "osk",         n: "On-screen keyboard",   def: "",                  ipc: "toggleKeyboard" },
        { key: "clipboard",   n: "Clipboard history",    def: "SUPER + SHIFT + V", ipc: "toggleClipboard" },
        { key: "terminal",    n: "Terminal",             def: "SUPER + Return",    exec: "terminal" },
        { key: "files",       n: "File manager",         def: "SUPER + E",         exec: "files" },
        { key: "browser",     n: "Browser",              def: "SUPER + B",         exec: "browser" },
        { key: "close",       n: "Close window",         def: "SUPER + Q",         dsp: "hl.dsp.window.close()" },
        { key: "float",       n: "Toggle floating",      def: "SUPER + V",         dsp: "hl.dsp.window.float({ action = \"toggle\" })" },
        { key: "fullscreen",  n: "Fullscreen",           def: "SUPER + F",         dsp: "hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"toggle\" })" }
    ]

    // key → accelerator, for anything changed from its default.
    function overrides() {
        if (!Config.Appearance.keybinds) return ({});
        try {
            const o = JSON.parse(Config.Appearance.keybinds);
            return (o && typeof o === "object") ? o : ({});
        } catch (e) {
            console.warn("Keybinds: theme.json keybinds is not valid JSON —", e);
            return ({});
        }
    }

    // The modifier the Windows key really sends on this keyboard. Every
    // accelerator is stored with SUPER as the token and translated on the
    // way out, so changing this re-points all of them at once instead of
    // needing each one re-recorded.
    readonly property string modKey: Config.Appearance.modKey || "SUPER"

    // The keysym each modifier sends on its own, for the tap binds. Changing
    // the modifier has to move the key too: "ALT + Super_L" would be Alt
    // held while tapping the Windows key, which is not what anyone means by
    // "tap the modifier".
    readonly property var tapKeys: ({
        "SUPER": "Super_L", "ALT": "Alt_L",
        "CTRL": "Control_L", "HYPER": "Hyper_L"
    })

    function withModKey(accel) {
        if (!accel || modKey === "SUPER") return accel;
        // A tap bind is the bare key, so it is replaced outright rather than
        // having its modifier swapped: picking Alt means tapping Alt.
        if (accel === tapKeys["SUPER"]) return tapKeys[modKey] || accel;
        return accel.replace(/\bSUPER\b/g, modKey);
    }

    function accelFor(key) {
        const o = overrides();
        if (o[key]) return o[key];
        const a = actions.find(x => x.key === key);
        return a ? a.def : "";
    }

    // What actually gets written — accelFor is what the UI shows.
    function boundAccel(key) { return withModKey(accelFor(key)); }

    function isCustom(key) { return !!overrides()[key]; }

    // "SUPER + Super_L" is how Hyprland spells "tap Super", and is not how
    // anyone wants to read it in a settings row.
    function displayAccel(key) {
        const accel = boundAccel(key);
        for (const mod in tapKeys) {
            if (accel === tapKeys[mod]) return "Tap " + mod;
        }
        return accel;
    }

    function setAccel(key, accel) {
        const o = overrides();
        const a = actions.find(x => x.key === key);
        if (!a) return;
        if (!accel || accel === a.def) delete o[key];
        else o[key] = accel;
        Config.Appearance.keybinds = JSON.stringify(o);
        write();
    }

    function resetAll() {
        Config.Appearance.keybinds = "";
        write();
    }

    // ── generated file ────────────────────────────────────────────────────
    FileView {
        id: bindsFile
        path: root.hyprDir + "/binds.lua"
        preload: true
        // text() answers from the disk rather than "" while a read is in
        // flight — the startup comparison above would otherwise see an
        // empty file every time and reload Hyprland on every start.
        blockLoading: true
        printErrors: false
        atomicWrites: true
    }

    function luaStr(s) {
        return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    // Only what you actually changed.
    //
    // This used to emit every bind, which meant the generated file shadowed
    // the whole of hyprland.lua the moment it existed — replacing working
    // native dispatchers with shell-outs and dropping arguments along the
    // way. A file that only carries overrides cannot do that: everything
    // untouched keeps using the config's own definition.
    function body() {
        // Shell actions call the IPC function inline, exactly as
        // hyprland.lua's own binds do — see the long comment there for why
        // it is written out rather than handed to a script, and what the
        // trace log is for. Keep the two in step: a rebound shortcut should
        // behave identically to the default it replaced.
        const ipcCall = (fn, arg) => {
            const call = fn + (arg ? " " + arg : "");
            return "hl.dsp.exec_cmd(shell(" + luaStr(call) + "))";
        };
        const lines = [
            "-- Generated by the shell's Settings → Keybinds. Do not hand-edit:",
            "-- it is rewritten whenever a shortcut changes.",
            "--",
            "-- Only shortcuts you have *changed* appear here. hyprland.lua reads",
            "-- this at the end of its own run, so these replace its defaults and",
            "-- everything else keeps using the definition in that file.",
            "--",
            "-- Deleting this file restores every default.",
            "",
            "-- The modifier the Windows key sends on this keyboard.",
            "local MOD = " + luaStr(modKey),
            "",
            "-- The shell IPC call, borrowed from hyprland.lua rather than",
            "-- copied: it hands this file its own `shell` helper just before",
            "-- loading it, so a rebound shortcut runs exactly what the default",
            "-- it replaced would have run. The fallback is only for the case",
            "-- of this file being loaded on its own, which nothing does.",
            "local shell = _G.hyprshellCall",
            "    or function(call) return \"qs -c hyprshell ipc call shell \" .. call end",
            "",
            "local apps = { terminal = " + luaStr(Config.Apps.execFor("appTerm"))
                + ", files = " + luaStr(Config.Apps.execFor("appFiles"))
                + ", browser = " + luaStr(Config.Apps.execFor("appWeb")) + " }",
            ""
        ];
        let emitted = 0;
        for (let i = 0; i < actions.length; i++) {
            const a = actions[i];
            // Untouched shortcuts are left to hyprland.lua.
            if (!isCustom(a.key) && modKey === "SUPER") continue;
            const accel = boundAccel(a.key);
            if (!accel) continue;
            let d;
            if (a.ipc) d = ipcCall(a.ipc, a.arg);
            else if (a.exec) d = "hl.dsp.exec_cmd(apps." + a.exec + ")";
            else d = a.dsp;   // a native dispatcher, verbatim
            // The launcher's default is a tap on the modifier, which is a
            // release bind. Rebinding it to an ordinary chord drops that
            // flag, which is right: a chord should fire on the way down.
            const opts = (a.release && !isCustom(a.key))
                       ? ", { release = true }" : "";
            lines.push("hl.bind(" + luaStr(accel) + ", " + d + opts + ")   -- " + a.n);
            emitted++;
        }
        if (emitted === 0) lines.push("-- (nothing overridden)");

        lines.push("");
        for (const l of root.altTabLines(ipcCall)) lines.push(l);

        // Workspace switching isn't in the action list — twenty positional
        // binds with no names — but it still has to follow the modifier, or
        // picking ALT would move every shortcut except the ones used most.
        // Only emitted when the modifier actually moved; on SUPER the
        // config's own binds are already right and native.
        if (modKey === "SUPER") return lines.join("\n") + "\n";

        lines.push("");
        lines.push("-- Workspaces 1-10, and moving windows to them.");
        // Native dispatchers, not `hyprctl dispatch workspace N`: under a
        // Lua config hyprctl evaluates its argument as Lua, so the old
        // hyprlang wording is a syntax error that only shows up in a log.
        lines.push("for i = 1, 10 do");
        lines.push("    local k = i % 10");
        lines.push("    hl.bind(MOD .. \" + \" .. k,"
                   + " hl.dsp.focus({ workspace = i }))");
        lines.push("    hl.bind(MOD .. \" + SHIFT + \" .. k,"
                   + " hl.dsp.window.move({ workspace = i }))");
        lines.push("end");

        return lines.join("\n") + "\n";
    }

    // ── Alt+Tab ───────────────────────────────────────────────────────────
    //
    // Two binds: the modifier with Tab steps forward, with Shift+Tab back.
    // Both repeat while Tab is held, as they do on Windows. Nothing binds
    // the release — services/Switcher.qml asks Hyprland whether the
    // modifier is still down instead, which is why there is no third line.
    //
    // Whatever else is on those chords is unbound first. Hyprland runs
    // every bind on a chord, so leaving Super+Tab on the overview and
    // adding the switcher to it would open both at once.
    readonly property string altTabMod: {
        const m = String(Config.Appearance.altTabMod || "ALT").toUpperCase();
        return (m === "SUPER" || m === "CTRL") ? m : "ALT";
    }
    function altTabAccel(shift) {
        const m = root.altTabMod === "SUPER" ? root.modKey : root.altTabMod;
        return m + (shift ? " + SHIFT" : "") + " + Tab";
    }

    // The shell's own shortcut already sitting on the chord, if any, so
    // Settings can say what choosing it would take away.
    function altTabClash() {
        const want = [root.altTabAccel(false), root.altTabAccel(true)]
            .map(a => a.replace(/\s+/g, "").toUpperCase());
        const hit = root.actions.find(a => {
            const b = root.boundAccel(a.key);
            return b && want.indexOf(b.replace(/\s+/g, "").toUpperCase()) >= 0;
        });
        return hit ? hit.n : "";
    }

    function altTabLines(ipcCall) {
        const out = ["-- Alt+Tab, from Settings → Alt+Tab."];
        if (!Config.Appearance.altTabEnabled) {
            out.push("-- (turned off: the chord goes to applications as usual)");
            return out;
        }
        for (const shift of [false, true]) {
            const accel = root.altTabAccel(shift);
            out.push("hl.unbind(" + luaStr(accel) + ")");
            out.push("hl.bind(" + luaStr(accel) + ", "
                     + ipcCall("altTab", shift ? "prev" : "next")
                     + ", { repeating = true })");
        }
        return out;
    }

    // binds.lua used to be written only when a shortcut changed, so a
    // fresh install never had one. Alt+Tab lives in it, so it is brought
    // up to date once the preferences are in, and again whenever the
    // Alt+Tab settings that change a bind do. Compared first: rewriting it
    // means a Hyprland reload, which is not something to do on every start.
    property bool synced: false
    readonly property string altTabKey:
        Config.Appearance.altTabEnabled + ":" + root.altTabMod + ":" + root.modKey
    onAltTabKeyChanged: if (root.synced) root.write();

    Timer {
        interval: 1500
        running: Config.Appearance.settingsReady && !root.synced
        onTriggered: {
            root.synced = true;
            if (bindsFile.text() !== root.body()) root.write();
        }
    }

    function write() {
        bindsFile.setText(body());
        // Hyprland only reads binds at config load, so the file is inert
        // until a reload. Routed through Compositor rather than run here, so
        // the configreloaded path re-applies every runtime setting the shell
        // owns — otherwise changing a shortcut quietly reverted the display
        // mode and the pointer settings along with it.
        Services.Compositor.reloadConfig();
    }
}
