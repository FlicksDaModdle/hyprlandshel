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

    // ── KDE / Qt applications ─────────────────────────────────────────────
    // Dolphin, Ark, Okular and the rest read their colours from kdeglobals,
    // so writing the shell's palette there is what makes a file manager look
    // like it belongs to this desktop rather than to Breeze.
    //
    // This is colours only, and worth being plain about: it cannot move
    // Dolphin's toolbar, change its icons or give it the shell's rounded
    // chrome. A KDE app themed this way reads as the same *palette* as the
    // shell — the same charcoal, the same accent on selection — with KDE's
    // own layout. Going further means a Kvantum theme, which is a different
    // and much larger piece of work.
    //
    // kdeglobals is not ours — it is where KDE keeps single-click, the icon
    // theme, and whatever else you have set — so the groups this owns are
    // replaced and every other group is carried across untouched. Only
    // [General]'s two colour-scheme keys and the [Colors:*] and [WM] groups
    // are rewritten.
    readonly property string kdeDir: (Quickshell.env("XDG_CONFIG_HOME")
                                      || (Quickshell.env("HOME") + "/.config"))

    function rgb(c) {
        return Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
             + Math.round(c.b * 255);
    }

    // Flatten a translucent token against the background it sits on: KDE
    // takes flat colours, and handing it an alpha would just be ignored.
    function over(top, under) {
        const a = top.a;
        return Qt.rgba(top.r * a + under.r * (1 - a),
                       top.g * a + under.g * (1 - a),
                       top.b * a + under.b * (1 - a), 1);
    }

    readonly property string kdeWanted: {
        const A = Config.Appearance;
        const bg = A.ground, view = A.surface, ink = A.ink, dim = A.ink2;
        const sel = A.accent, onSel = A.onAccent;
        const line = root.over(A.rule, bg);
        const hover = root.over(A.hover, bg);

        function group(name, back, fore, extra) {
            return "[Colors:" + name + "]\n"
                 + "BackgroundNormal=" + root.rgb(back) + "\n"
                 + "BackgroundAlternate=" + root.rgb(extra || hover) + "\n"
                 + "ForegroundNormal=" + root.rgb(fore) + "\n"
                 + "ForegroundInactive=" + root.rgb(dim) + "\n"
                 + "ForegroundActive=" + root.rgb(sel) + "\n"
                 + "ForegroundLink=" + root.rgb(sel) + "\n"
                 + "DecorationFocus=" + root.rgb(sel) + "\n"
                 + "DecorationHover=" + root.rgb(sel) + "\n\n";
        }

        return "# Written by the shell (services/Theming.qml) from the "
             + "current theme.\n"
             + "# The [Colors:*] groups below are rewritten whenever the "
             + "theme changes;\n# edit theme.json, or the shell's Settings, "
             + "rather than this file.\n\n"
             + "[General]\n"
             + "ColorScheme=Hyprshell\n"
             + "Name=Hyprshell\n\n"
             + group("Window", bg, ink)
             + group("View", view, ink, bg)
             + group("Button", root.over(A.hover, view), ink)
             + group("Selection", sel, onSel, sel)
             + group("Tooltip", view, ink)
             + group("Complementary", bg, ink)
             + group("Header", root.over(A.hover, bg), ink)
             + "[WM]\n"
             + "activeBackground=" + root.rgb(bg) + "\n"
             + "activeForeground=" + root.rgb(ink) + "\n"
             + "inactiveBackground=" + root.rgb(view) + "\n"
             + "inactiveForeground=" + root.rgb(dim) + "\n"
             + "frame=" + root.rgb(sel) + "\n"
             + "inactiveFrame=" + root.rgb(line) + "\n";
    }

    FileView {
        id: kdeColors
        path: root.kdeDir + "/kdeglobals"
        preload: true
        printErrors: false
        atomicWrites: true
    }

    // Everything in the existing file that is not ours, in the order it was
    // written. A group is "ours" if this writes it; the rest — [KDE],
    // [Icons], [General]'s font keys and so on — is somebody else's and is
    // handed back unchanged.
    function keepForeign(existing) {
        const ours = /^\[(Colors:|WM\]|General\])/;
        const out = [];
        let keeping = true;
        for (const line of String(existing || "").split("\n")) {
            if (line.indexOf("[") === 0) keeping = !ours.test(line);
            if (keeping) out.push(line);
        }
        // Their [General] keys, minus the two this one sets.
        const general = [];
        let inGeneral = false;
        for (const line of String(existing || "").split("\n")) {
            if (line.indexOf("[") === 0) inGeneral = line.indexOf("[General]") === 0;
            else if (inGeneral && line.trim() !== ""
                     && line.indexOf("ColorScheme=") !== 0
                     && line.indexOf("Name=") !== 0) general.push(line);
        }
        return { rest: out.join("\n").replace(/\n{3,}/g, "\n\n").trim(),
                 general: general };
    }

    // Running KDE apps re-read kdeglobals when it changes, so this lands
    // without restarting Dolphin.
    function applyKde() {
        if (!Config.Appearance.themeQtApps) return;
        const existing = kdeColors.text() || "";
        const kept = keepForeign(existing);
        const wanted = kdeWanted.replace("[General]\nColorScheme=Hyprshell\nName=Hyprshell\n",
                                         "[General]\nColorScheme=Hyprshell\nName=Hyprshell\n"
                                         + (kept.general.length ? kept.general.join("\n") + "\n" : ""))
                     + (kept.rest !== "" ? "\n" + kept.rest + "\n" : "");
        if (existing === wanted) return;
        kdeColors.setText(wanted);
    }

    onKdeWantedChanged: applyKde()

    // ── text rendering ────────────────────────────────────────────────────
    // Subpixel order and hinting are fontconfig's to decide, not Qt's, and
    // fontconfig is read by every application on the session. So this writes
    // a snippet into the user's own conf.d rather than trying to do
    // something Qt-only: getting it right here fixes the whole desktop, and
    // getting it wrong in one app would be worse than useless.
    //
    // It only writes when there is something to say. With the setting left
    // at "" the file is emptied, which puts fontconfig back to whatever it
    // decided by itself.
    readonly property string fontconfDir: (Quickshell.env("XDG_CONFIG_HOME")
                                           || (Quickshell.env("HOME") + "/.config"))
                                          + "/fontconfig/conf.d"

    readonly property string subpixel: Config.Appearance.subpixel
    readonly property bool hinting: Config.Appearance.fontHinting

    readonly property string fontconfWanted: {
        if (subpixel === "") return "";
        const rgba = subpixel === "none" ? "none" : subpixel;
        return '<?xml version="1.0"?>\n'
            + '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">\n'
            + "<!-- Written by the shell: Settings \u2192 Fonts \u2192 Text rendering.\n"
            + "     Delete this file, or set the subpixel order back to\n"
            + "     \"Leave alone\", to hand the decision back to fontconfig. -->\n"
            + "<fontconfig>\n"
            + "  <match target=\"font\">\n"
            + '    <edit name="rgba" mode="assign"><const>' + rgba + "</const></edit>\n"
            + '    <edit name="antialias" mode="assign"><bool>true</bool></edit>\n'
            + '    <edit name="hinting" mode="assign"><bool>'
            + (hinting ? "true" : "false") + "</bool></edit>\n"
            + '    <edit name="hintstyle" mode="assign"><const>'
            + (hinting ? "hintslight" : "hintnone") + "</const></edit>\n"
            + "  </match>\n"
            + "</fontconfig>\n";
    }

    FileView {
        id: fontconf
        // 99- so it wins over a distribution's defaults, which are lower.
        path: root.fontconfDir + "/99-hyprshell-text.conf"
        preload: true
        printErrors: false
        atomicWrites: true
    }

    // Applications read fontconfig when they start, so this only reaches
    // things launched afterwards — including this shell. Nothing here can
    // change that, and pretending otherwise would be worse than saying so in
    // the settings row.
    function applyFontconf() {
        if (fontconf.text() === fontconfWanted) return;
        fontconf.setText(fontconfWanted);
    }

    onFontconfWantedChanged: applyFontconf()

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
        fontconf.reload();
        fontconf.setText(fontconfWanted);
        kdeColors.reload();
        applyKde();
    }
}
