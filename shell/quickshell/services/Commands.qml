pragma Singleton
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Every action the shell can be asked to perform, and the channel the
// keybinds use to ask.
//
// The channel is a file. `hyprland.lua` appends a line to
// $XDG_RUNTIME_DIR/hyprshell.cmd and the watcher below reads it.
//
// That is deliberately the dullest possible mechanism, after three that
// were not. Global shortcuts need a Quickshell built with a protocol this
// one was not. `qs ipc call` has to *find* this process first — it hashes
// the config file path, reads $XDG_RUNTIME_DIR/quickshell/by-path/<hash>
// and filters what it finds by display connection — and on the machine this
// was written for that lookup comes back empty while `qs list --all` prints
// the instance, pid and config path quite happily. Reaching it by pid or by
// instance id did not help either.
//
// Appending a line to a file has nothing to discover and nothing to match.
// It needs no binary on PATH, no socket, no protocol and no agreement about
// how this process was started — only that both sides read the same
// $XDG_RUNTIME_DIR, which the keybinds had already proven they do, because
// their own log was landing in it the whole time.
//
// The watcher writes its pid to hyprshell.cmd.watcher so `hyprshellctl
// doctor` can say whether anything is actually listening, rather than
// leaving that to be inferred.
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string cmdFile: runtimeDir + "/hyprshell.cmd"

    // True once the watcher process is up. shell.qml holds a reference to
    // this so the singleton is constructed at startup rather than whenever
    // something first happens to touch it.
    readonly property bool watching: watcher.running

    // The one table. shell.qml's IpcHandler calls into it by name and so
    // does every keybind, so a shortcut and `qs ipc call` cannot drift into
    // doing different things.
    //
    // Each entry takes the argument string, which is empty for most.
    readonly property var table: ({
        // Panels
        "toggleLauncher":      () => Config.UiState.toggleLauncher(),
        "toggleOverview":      () => Config.UiState.toggleOverview(),
        "toggleControlCenter": () => Config.UiState.toggleControlCenter(),
        "toggleNotifications": () => Config.UiState.toggleNotifications(),
        "toggleCalendar":      () => Config.UiState.toggleCalendar(),
        "togglePower":         () => Config.UiState.togglePower(),
        "closePanels":         () => Config.UiState.closeAll(),
        "openSettings":        arg => Config.UiState.openSettings(arg || "Appearance"),
        // The file manager is its own application now, not a surface of the
        // shell: an ordinary toplevel the compositor tiles and focuses like
        // anything else, and a real drag source, which a layer-shell
        // surface is not. An argument is a directory to open.
        "openFiles":           arg => Config.Apps.launchFiles(arg),

        // Appearance
        "toggleTheme":         () => Config.Appearance.toggleTheme(),
        "cycleTheme":          () => Config.Appearance.cycleTheme(),
        "setTheme":            arg => Config.Appearance.setTheme(arg),
        "setWallpaper":        arg => Config.Appearance.wallpaper = arg,
        "setAccent":           arg => Config.Appearance.accentIndex = parseInt(arg, 10) || 0,
        "syncTheming":         () => Services.Theming.resync(),

        // Session
        "lock":                () => Config.UiState.lock(),
        "reloadShell":         () => Services.Session.reloadShell(),

        // Levels. Bound to the media keys so the shell's own OSD is what
        // shows, instead of each hotkey silently poking wpctl.
        "volumeUp":            () => Services.Audio.step(0.05),
        "volumeDown":          () => Services.Audio.step(-0.05),
        "volumeMute":          () => Services.Audio.toggleMute(),
        "micMute":             () => Services.Audio.toggleInputMute(),
        "brightnessUp":        () => Services.Brightness.step(0.05),
        "brightnessDown":      () => Services.Brightness.step(-0.05),

        // Notifications and windows
        "toggleDnd":           () => Services.Notifications.toggleDnd(),
        "showDesktop":         () => Services.Compositor.toggleShowDesktop()
    })

    readonly property var names: Object.keys(table)

    // A toggle asked for twice within a blink is one press, not two.
    //
    // This exists so the config can bind the same physical key more than one
    // way — by keysym and by keycode — without a tap opening and closing the
    // launcher again. Which spelling a Hyprland build accepts for the Super
    // key has not been possible to determine from here, so it binds both and
    // the second delivery is swallowed.
    //
    // Only toggles: nobody means to toggle the same panel twice in 200ms,
    // while volume and brightness are held down on purpose.
    property string lastToggle: ""
    property double lastToggleAt: 0

    // The window is refreshed on a suppressed repeat too, not only on one
    // that gets through. Refreshing only on the latter meant a steady
    // stream leaked: at 0, 150, 300ms the first fired, the second was
    // suppressed without moving the mark, and the third was 300ms from a
    // mark that had not moved, so it fired as well.
    //
    // With Super bound once (see hyprland.lua) nothing should reach here
    // twice anyway. This is the backstop, and a backstop that lets every
    // other event through is not one.
    function isDuplicate(name) {
        if (name.indexOf("toggle") !== 0) return false;
        const now = Date.now();
        const repeat = name === lastToggle && now - lastToggleAt < 150;
        lastToggle = name;
        lastToggleAt = now;
        return repeat;
    }

    // "openSettings Display" -> table.openSettings("Display")
    function run(line) {
        const s = String(line || "").trim();
        if (s === "") return false;

        const cut = s.indexOf(" ");
        const name = cut === -1 ? s : s.slice(0, cut);
        const arg = cut === -1 ? "" : s.slice(cut + 1).trim();

        const fn = table[name];
        if (!fn) {
            console.warn("Commands: no such command:", name);
            return false;
        }

        if (isDuplicate(name)) return true;

        fn(arg);
        return true;
    }

    // The shell's own pid, so the status file below can say where this
    // process is. Read through a function because a Quickshell without the
    // property would otherwise leave a broken binding behind.
    function ownPid() {
        try {
            return String(Quickshell.processId || "");
        } catch (e) {
            return "";
        }
    }

    // `tail -F` rather than a FileView: this has to see every line appended
    // while the shell runs, not the file's current contents, and it has to
    // survive the file being truncated or replaced. -n 0 starts at the end,
    // so nothing queued before the shell started is replayed.
    //
    // The outer loop is what makes it durable: if tail is killed or the file
    // goes away, it is back a second later instead of leaving the shortcuts
    // dead until the next reload.
    //
    // It also writes a status file naming this process, the watcher, and
    // whether Quickshell's own IPC socket for this pid exists — the address
    // DankMaterialShell's helper connects to. `hyprshellctl doctor` prints
    // it, so "is anything listening, and is the socket route available on
    // this build" is a fact to read rather than a thing to guess at.
    Process {
        id: watcher
        running: true
        command: ["sh", "-c",
            'f="${XDG_RUNTIME_DIR:-/tmp}/hyprshell.cmd"; '
            + 's="${XDG_RUNTIME_DIR:-/tmp}/quickshell/by-pid/$1/ipc.sock"; '
            + '{ echo "watcher $$"; echo "shell $1"; '
            + '  if [ -S "$s" ]; then echo "socket $s"; '
            + '  else echo "socket missing $s"; fi; '
            + '} > "$f.status"; '
            + ': > "$f"; '
            + 'while :; do tail -n 0 -F "$f" 2>/dev/null; sleep 1; done',
            "hyprshell-watch", root.ownPid()]

        stdout: SplitParser {
            onRead: data => root.run(data)
        }

        onExited: (code, status) => {
            console.warn("Commands: the command watcher exited", code, status,
                         "— keyboard shortcuts will not work until the shell "
                         + "is restarted");
        }
    }
}
