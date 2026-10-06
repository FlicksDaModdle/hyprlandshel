pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Pending updates: the official repositories (checkupdates, from
// pacman-contrib — it syncs a copy of the databases, so nothing changes
// on the system and no password is asked), the AUR (paru or yay, if
// either is installed) and Flatpak (if installed), with download sizes.
//
// Checked a little after login and then every few hours (Settings →
// About), and whenever the panel opens. "Update now" runs the update in
// a terminal — paru or yay when there is one, so the AUR comes too, then
// Flatpak — and checks again once it closes.
//
// A restart is called for when the running kernel is no longer installed
// (the update already replaced it), and warned of beforehand when one is
// in the list.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance

    // [{ name, from, to, source: "repo" | "aur" | "flatpak", size (bytes) }]
    property var items: []
    property bool checking: false
    property bool updating: false
    property real checkedAt: 0
    property string error: ""
    property bool rebootNeeded: false
    property bool haveCheckupdates: true
    property string aurHelper: ""

    readonly property int count: items.length
    readonly property real totalSize: items.reduce((a, i) => a + (i.size || 0), 0)
    readonly property var kernelUpdates: items.filter(i => i.source === "repo" && isKernel(i.name))
    readonly property bool restartAfter: kernelUpdates.length > 0

    function isKernel(name) {
        return /^linux(-[a-z0-9]+)*$/.test(name) && !/^linux-(firmware|api-headers|tools)/.test(name)
            && !/-headers$/.test(name) && !/-docs$/.test(name);
    }
    function sizeText(b) {
        if (!(b > 0)) return "";
        if (b < 1048576) return Math.max(1, Math.round(b / 1024)) + " KiB";
        if (b < 1073741824) return (b / 1048576).toFixed(b < 10485760 ? 1 : 0) + " MiB";
        return (b / 1073741824).toFixed(2) + " GiB";
    }
    function agoText() {
        if (!checkedAt) return "";
        const m = Math.round((Date.now() - checkedAt) / 60000);
        if (m < 1) return "just now";
        if (m < 60) return m + " min ago";
        return Math.round(m / 60) + " h ago";
    }

    // ── checking ─────────────────────────────────────────────────────────
    function check() {
        if (checking || updating) return;
        checking = true;
        checker.running = true;
    }
    Timer {
        // Shortly after login, not during it.
        interval: 90000
        running: root.prefs.updatesAuto
        onTriggered: root.check()
    }
    Timer {
        interval: Math.max(1, root.prefs.updatesEvery) * 3600000
        running: root.prefs.updatesAuto
        repeat: true
        onTriggered: root.check()
    }
    Connections {
        target: Config.UiState
        function onUpdatesOpenChanged() {
            if (Config.UiState.updatesOpen && Date.now() - root.checkedAt > 600000) root.check();
        }
    }

    // One script, one line per fact:
    //   R name old new          an official update
    //   S name size unit        its download size
    //   A name old new          an AUR update
    //   F id version            a Flatpak update
    //   H helper                the AUR helper found
    //   K                       running kernel no longer installed
    //   E message               something went wrong
    //   N                       checkupdates is missing
    readonly property string script: [
        "db=\"${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell/checkup-db\"",
        "mkdir -p \"$db\"",
        "if command -v checkupdates >/dev/null 2>&1; then",
        "  out=$(CHECKUPDATES_DB=\"$db\" checkupdates 2>\"$db.err\"); rc=$?",
        "  if [ \"$rc\" = 0 ]; then",
        "    printf \"%s\\n\" \"$out\" | awk 'NF>=4 {print \"R\", $1, $2, $4}'",
        "    names=$(printf \"%s\\n\" \"$out\" | awk '{print $1}')",
        "    LC_ALL=C pacman -Si --dbpath \"$db\" $names 2>/dev/null | awk -F\": *\" '/^Name/{n=$2} /^Download Size/{split($2,a,\" \"); print \"S\", n, a[1], a[2]}'",
        "  elif [ \"$rc\" != 2 ]; then",
        "    printf \"E %s\\n\" \"$(tail -n1 \"$db.err\")\"",
        "  fi",
        "elif command -v pacman >/dev/null 2>&1; then",
        "  echo N",
        "fi",
        "for h in paru yay; do",
        "  if command -v \"$h\" >/dev/null 2>&1; then",
        "    echo \"H $h\"",
        "    \"$h\" -Qua 2>/dev/null | awk 'NF>=4 && $1 !~ /^::/ {print \"A\", $1, $2, $4}'",
        "    break",
        "  fi",
        "done",
        "if command -v flatpak >/dev/null 2>&1; then",
        "  flatpak remote-ls --updates --columns=application,version 2>/dev/null | awk 'NF>=1 {print \"F\", $1, ($2 == \"\" ? \"-\" : $2)}'",
        "fi",
        "[ -d \"/usr/lib/modules/$(uname -r)\" ] || echo K"
    ].join("\n")
    Process {
        id: checker
        command: ["sh", "-c", root.script]
        stdout: StdioCollector {
            onStreamFinished: root.adopt(text)
        }
        onExited: root.checking = false
    }

    function unitBytes(n, unit) {
        const f = { "B": 1, "KiB": 1024, "MiB": 1048576, "GiB": 1073741824 }[unit] || 1;
        return Math.round(parseFloat(n) * f);
    }

    function adopt(text) {
        const list = [];
        const sizes = {};
        let err = "", reboot = false, helper = "", have = true;
        for (const line of String(text || "").split("\n")) {
            const f = line.trim().split(/\s+/);
            switch (f[0]) {
            case "R": list.push({ name: f[1], from: f[2], to: f[3], source: "repo", size: 0 }); break;
            case "S": sizes[f[1]] = unitBytes(f[2], f[3]); break;
            case "A": list.push({ name: f[1], from: f[2], to: f[3], source: "aur", size: 0 }); break;
            case "F": list.push({ name: f[1], from: "", to: f[2] === "-" ? "" : f[2], source: "flatpak", size: 0 }); break;
            case "H": helper = f[1]; break;
            case "K": reboot = true; break;
            case "N": have = false; break;
            case "E": err = line.slice(2).trim(); break;
            }
        }
        for (const i of list) if (sizes[i.name]) i.size = sizes[i.name];
        const before = root.items.length;
        root.items = list;
        root.error = err;
        root.rebootNeeded = reboot;
        root.aurHelper = helper;
        root.haveCheckupdates = have;
        root.checkedAt = Date.now();
        // Said once when updates first appear, not at every check.
        if (prefs.updatesNotify && before === 0 && list.length > 0 && !Config.UiState.updatesOpen) {
            notifyProc.command = ["notify-send", "-a", "Updates", "-i", "system-software-update",
                                  list.length + (list.length === 1 ? " update" : " updates") + " available",
                                  (totalSize > 0 ? sizeText(totalSize) + " to download. " : "")
                                  + (restartAfter ? "Includes a new kernel." : "")];
            notifyProc.running = true;
        }
    }
    Process { id: notifyProc }

    // ── updating ─────────────────────────────────────────────────────────
    function updateNow() {
        if (updating) return;
        const steps = [];
        if (aurHelper) steps.push(aurHelper + " -Syu");
        else steps.push("sudo pacman -Syu");
        if (items.some(i => i.source === "flatpak")) steps.push("flatpak update");
        const run = steps.map(s => 'echo; echo "\\033[1m$ ' + s + '\\033[0m"; ' + s).join("; ")
            + '; echo; printf "Done — press Enter to close. "; read _';
        updater.command = Config.Apps.termCommand(["-e", "sh", "-c", run]);
        updating = true;
        updater.running = true;
        Config.UiState.closeAll();
    }
    Process {
        id: updater
        onExited: {
            root.updating = false;
            root.check();
        }
    }
}
