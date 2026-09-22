pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Pushes the shell's theme out to the terminal, so flipping light/dark in
// Settings recolours kitty windows that are already open.
//
// It writes one line — which palette file to include — into
// ~/.config/kitty/hyprshell-colors.conf, then sends kitty SIGUSR1. That signal
// is kitty's own "reload your config" and needs no remote control, so nothing
// has to be enabled on kitty's side beyond the include that ships in
// kitty.conf. A kitty that isn't running is simply not signalled, and picks the
// right palette up whenever it next starts.
//
// Only the *choice* of palette is written here. The palettes themselves are
// checked in, because their sixteen ANSI colours are laid out on a shared
// OKLCH lightness scale with verified contrast — that is not something worth
// re-deriving in QML on every theme flip, and the accent deliberately does not
// feed into them (a blue accent must not make error text blue).
Singleton {
    id: root

    readonly property string kittyDir: (Quickshell.env("XDG_CONFIG_HOME")
                                        || (Quickshell.env("HOME") + "/.config")) + "/kitty"

    // Whether kitty's config is actually ours. If the user never installed it,
    // there's nothing to drive and the include file is left alone.
    property bool kittyPresent: false

    readonly property bool dark: Config.Appearance.dark

    readonly property string wanted:
        "# Written by the shell (services/Theming.qml) — edit kitty.conf instead,\n"
        + "# or set this by hand if you stop running the shell.\n"
        + "include colors-" + (dark ? "dark" : "light") + ".conf\n"

    // One view does both halves: it reads the file, so we know whether our
    // kitty config is installed and what palette it currently names, and it
    // writes the choice back.
    //
    // preload matters. Without it a FileView reads nothing until something
    // asks for its text, so loaded/loadFailed would never fire and
    // kittyPresent would stay false forever.
    FileView {
        id: include
        path: root.kittyDir + "/hyprshell-colors.conf"
        preload: true
        printErrors: false
        atomicWrites: true
        // Without this, installing the kitty config into a session that is
        // already up leaves kittyPresent stuck false for the life of the
        // shell — the one read happened before the file existed — and the
        // terminal keeps whatever palette it was installed with.
        watchChanges: true
        onFileChanged: reload()

        onLoaded: root.kittyPresent = true
        onLoadFailed: root.kittyPresent = false
    }

    // Covers the file appearing after startup: the moment it becomes
    // readable, make sure it names the palette the shell is actually using.
    onKittyPresentChanged: if (primed && kittyPresent) apply();

    Process { id: reloadProc }

    // -x matches the exact name so this can't hit an editor that happens to
    // have "kitty" in its command line. A failure is fine: it means no kitty
    // is running.
    function signalKitty() {
        reloadProc.command = ["sh", "-c", "pkill -USR1 -x kitty || true"];
        reloadProc.running = true;
    }

    // Guards the window before the preload lands: until the file's contents
    // are known there is nothing to compare against, and a startup apply()
    // would rewrite the file and reload every kitty window for nothing.
    property bool primed: false

    onDarkChanged: if (primed) apply();

    Timer {
        interval: 1200
        running: true
        onTriggered: {
            root.primed = true;
            // Reconcile once. If theme.json was edited while the shell was
            // down, the file on disk names the wrong palette and nothing else
            // would ever notice — dark hasn't *changed*, it was simply read.
            // When it already agrees, apply() writes nothing.
            root.apply();
        }
    }

    // Writes and signals only when the file doesn't already say the right
    // thing, so nothing happens on the theme's own initial evaluation.
    function apply() {
        if (!kittyPresent || include.text() === wanted) return;
        include.setText(wanted);
        signalKitty();
    }

    // Lets `qs ipc call shell syncTheming` force it, which is handy right
    // after installing the kitty config into a session that's already up —
    // there the file may have appeared since startup, or be right on disk
    // while the running kitty still has the old palette loaded. So this one
    // doesn't compare: it writes and signals unconditionally.
    function resync() {
        primed = true;
        kittyPresent = true;
        include.reload();
        include.setText(wanted);
        signalKitty();
    }
}
