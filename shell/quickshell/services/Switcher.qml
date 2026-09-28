pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Alt+Tab: which windows, in what order, and when to switch.
//
// The drawing is modules/switcher/Switcher.qml; everything that decides
// anything is here, so the one hard question has one answer.
//
// That question is "has Alt been let go". The shortcut reaches the shell
// as a line in a file (see services/Commands.qml and hyprland.lua), which
// can say "Tab was pressed" but has no way to say "and Alt is still
// down". A release bind in Hyprland could, in principle — but 0.56 arms a
// release bind by the submap and the chord that were live when the key
// went *down*, and whether it survives Tab being pressed in between is
// decided by chord-suppression rules that are easy to misread and cannot
// be tried from here. The switcher's own window could see the release too,
// but only once it has keyboard focus, and a quick Alt+Tab is over before
// it does.
//
// So it asks. `hl.is_key_down` is Hyprland's own record of which keys are
// held, kept for every key whether or not anything is bound to it, and
// `hyprctl repl` hands back what a Lua expression returns. Every 50ms
// while a switch is under way, "is Alt still down?" — and the first "no"
// is the release, however quickly it came and whoever had focus. The
// switcher's window watching for the release itself is kept as the faster
// path; the poll is the one that cannot be missed.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance

    // A switch is under way — Tab has been pressed and nothing chosen yet.
    property bool open: false
    // The overlay is on screen. Not the same thing: a quick Alt+Tab
    // switches without ever showing it, which is what makes the tap useful.
    property bool shown: false
    property var entries: []
    property int index: 0
    // The output it opened on, so it stays there.
    property string screenName: ""
    // Bumped per switch, so an answer about the last one cannot end this one.
    property int session: 0
    property double lastCommitAt: 0
    // Set when hyprctl could not answer the question at all — a Hyprland
    // without `repl`, or without hl.is_key_down. The overlay then shows at
    // once and waits for Enter, Escape or a click, rather than guessing.
    property bool pollBroken: false

    // Opened from Settings' "Try it" rather than from the keyboard. Nobody
    // is holding the modifier then, so it waits for a choice instead of
    // switching the moment the poll finds it up.
    property bool previewing: false

    readonly property var current:
        (index >= 0 && index < entries.length) ? entries[index] : null

    // ── the modifier ──────────────────────────────────────────────────────
    readonly property string mod: {
        const m = String(prefs.altTabMod || "ALT").toUpperCase();
        return (m === "SUPER" || m === "CTRL") ? m : "ALT";
    }
    readonly property var modKeysyms: ({
        "ALT": ["Alt_L", "Alt_R"],
        "SUPER": ["Super_L", "Super_R"],
        "CTRL": ["Control_L", "Control_R"]
    })
    // "Is either copy of the modifier down?", as one Lua expression.
    readonly property string heldExpr: root.modKeysyms[root.mod]
        .map(k => 'hl.is_key_down("' + k + '")').join(" or ")

    // Qt's names for the same keys, for the overlay's own release check.
    // Right Alt usually comes through as AltGr.
    function isModKey(key) {
        switch (root.mod) {
        case "SUPER": return key === Qt.Key_Super_L || key === Qt.Key_Super_R
                          || key === Qt.Key_Meta;
        case "CTRL":  return key === Qt.Key_Control;
        default:      return key === Qt.Key_Alt || key === Qt.Key_AltGr;
        }
    }

    // ── the list ──────────────────────────────────────────────────────────
    //
    // Most recently used first — Hyprland numbers every window by how
    // recently it had focus — so the first Tab lands on the window you
    // were in before this one, and a quick tap flips between the two.
    function build() {
        const C = Services.Compositor;
        const on = C.focusedMonitorName;
        let wins = prefs.altTabScope === "all" ? C.clients
                 : prefs.altTabScope === "monitor" ? C.clientsOnMonitor(on)
                 : C.clientsShownOn(on);
        if (!prefs.altTabSpecial)
            wins = wins.filter(c => String(c.workspaceName || "").indexOf("special") !== 0);
        wins = wins.slice().sort((a, b) => a.focusHistory - b.focusHistory);

        const out = [];
        const byApp = ({});
        for (const c of wins) {
            if (prefs.altTabGroup && c.cls && byApp[c.cls] !== undefined) {
                out[byApp[c.cls]].count++;
                continue;
            }
            if (c.cls) byApp[c.cls] = out.length;
            out.push({
                address: c.address,
                cls: c.cls,
                title: c.title || Config.Apps.labelFor(c.cls) || c.cls || "Window",
                label: Config.Apps.labelFor(c.cls),
                icon: Config.Apps.iconFor(c.cls),
                workspace: c.workspace,
                workspaceName: c.workspaceName,
                count: 1
            });
        }
        return out;
    }

    // ── what the shortcuts say ────────────────────────────────────────────
    // `altTab next` and friends, from services/Commands.qml.
    function command(arg) {
        switch (String(arg || "next").trim()) {
        case "next":    root.step(1); break;
        case "prev":    root.step(-1); break;
        case "commit":  root.commit(); break;
        case "cancel":  root.cancel(); break;
        case "release": root.releaseSeen(); break;
        default: console.warn("Switcher: no such action", arg);
        }
    }

    function step(dir) {
        if (!prefs.altTabEnabled) return;
        if (!root.open) {
            // A Tab that was pressed before the release that ended the
            // last switch, and has only now arrived. It belonged to that
            // switch; starting a new one with it would switch twice.
            //
            // Short, because the settle before a commit already takes in
            // any Tab that was on its way at the release; this only has to
            // catch one that was unusually slow. It was 150ms, which also
            // swallowed a deliberate second Alt+Tab a quarter of a second
            // after the first — the commit itself lands up to 130ms after
            // the release, so "150ms after the commit" reached well into
            // the time a fast hand takes to go again.
            if (Date.now() - root.lastCommitAt < 60) return;
            const list = root.build();
            if (list.length === 0) return;
            root.entries = list;
            // The second entry is the previous window. Shift+Tab from
            // nothing goes to the least recent.
            root.index = list.length === 1 ? 0 : (dir > 0 ? 1 : list.length - 1);
            root.screenName = Services.Compositor.focusedMonitorName;
            root.session++;
            root.open = true;
            root.shown = false;
            if (!prefs.altTabHold || root.pollBroken || root.previewing) {
                root.shown = true;
            } else {
                showDelay.interval = Math.max(0, prefs.altTabDelay);
                showDelay.restart();
                root.pollNow();
            }
            return;
        }
        if (root.entries.length === 0) return;
        root.index = (root.index + dir + root.entries.length) % root.entries.length;
        // Pressing Tab again is choosing, and choosing needs to see.
        root.showNow();
    }

    function preview() {
        if (root.open) return;
        root.previewing = true;
        root.step(1);
        if (!root.open) root.previewing = false;
    }

    function select(i) {
        if (i >= 0 && i < root.entries.length) root.index = i;
    }

    function showNow() {
        if (!root.open) return;
        showDelay.stop();
        root.shown = true;
    }

    // The modifier came up. Not acted on at once: a Tab pressed just
    // before it may still be on its way through the command file, and it
    // belongs to this switch. 70ms is longer than that trip and shorter
    // than anyone notices.
    function releaseSeen() {
        if (!root.open || !prefs.altTabHold || root.previewing || settle.running) return;
        settle.restart();
    }

    function commit() {
        if (!root.open) return;
        const target = root.current;
        root.close();
        root.lastCommitAt = Date.now();
        // Focusing a window on another workspace takes you there.
        if (target) Services.Compositor.focusClient(target.address);
    }

    function cancel() {
        if (root.open) root.close();
    }

    function close() {
        showDelay.stop();
        settle.stop();
        root.open = false;
        root.shown = false;
        root.previewing = false;
        root.entries = [];
        root.index = 0;
    }

    // Closes the window under the selection and takes it out of the list,
    // which carries on with what is left.
    function closeEntry(i) {
        const e = root.entries[i];
        if (!e) return;
        Services.Compositor.closeClient(e.address);
        root.drop(e.address);
    }

    function drop(address) {
        const list = root.entries.filter(x => x.address !== address);
        if (list.length === root.entries.length) return;
        root.entries = list;
        if (list.length === 0) { root.close(); return; }
        root.index = Math.min(root.index, list.length - 1);
    }

    // A window that closes by itself while the switcher is up leaves it.
    Connections {
        target: Services.Compositor
        function onClientsChanged() {
            if (!root.open) return;
            const live = ({});
            for (const c of Services.Compositor.clients) live[c.address] = true;
            for (const e of root.entries.slice())
                if (!live[e.address]) root.drop(e.address);
        }
    }

    Timer {
        id: showDelay
        onTriggered: if (root.open) root.shown = true
    }

    Timer {
        id: settle
        interval: 70
        onTriggered: root.commit()
    }

    // ── is the modifier still down ────────────────────────────────────────
    Timer {
        interval: 50
        repeat: true
        running: root.open && root.prefs.altTabHold && !root.pollBroken
                 && !root.previewing
        onTriggered: root.pollNow()
    }

    function pollNow() {
        if (keyProc.running) return;
        keyProc.forSession = root.session;
        keyProc.command = ["hyprctl", "repl", root.heldExpr];
        keyProc.running = true;
    }

    Process {
        id: keyProc
        property int forSession: 0
        stdout: StdioCollector {
            onStreamFinished: root.pollAnswer(keyProc.forSession, text)
        }
    }

    function pollAnswer(forSession, text) {
        if (forSession !== root.session || !root.open) return;
        const t = String(text || "").trim();
        if (t === "false") { root.releaseSeen(); return; }
        if (t === "true") return;
        // Anything else is hyprctl saying it cannot answer. Say so once and
        // stop asking; the overlay stays up until something is chosen.
        root.pollBroken = true;
        console.warn("Switcher: cannot tell whether " + root.mod + " is held ("
                     + JSON.stringify(t) + "). Alt+Tab will wait for Enter, "
                     + "Escape or a click instead of the release.");
        root.showNow();
    }
}
