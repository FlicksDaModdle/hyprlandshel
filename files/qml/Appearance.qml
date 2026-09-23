pragma Singleton
import QtQuick
import Hyprshell.Backend

// The palette.
//
// It follows the shell's theme.json when there is one, so the file manager
// matches the desktop it was designed for, and falls back to the design's
// own colours when run anywhere else. It only ever reads that file.
//
// Deliberately nothing else: the window's own settings live in
// FilesService. Keeping them here made the two singletons reference each
// other, which QML calls a cyclic dependency and resolves by giving one of
// them to the other half-built.
QtObject {
    id: root

    // ── the shell's theme, if it is installed ─────────────────────────────
    readonly property string themePath:
        Sys.configDir() + "/quickshell/hyprshell/theme.json"

    property var theme: ({})

    function loadTheme() {
        const text = Sys.readFile(root.themePath);
        if (!text) { root.theme = ({}); return; }
        try { root.theme = JSON.parse(text) || ({}); }
        catch (e) { root.theme = ({}); }
    }

    property Watcher themeWatch: Watcher {
        path: root.themePath
        onChanged: root.loadTheme()
    }

    Component.onCompleted: loadTheme()

    // ── theme ─────────────────────────────────────────────────────────────
    readonly property string themeMode: root.theme.theme || "dark"
    readonly property bool dark: {
        if (root.themeMode === "light") return false;
        if (root.themeMode === "dark") return true;
        // "auto" is dark from 19:00 to 07:00 — the shell's own rule.
        const h = new Date().getHours();
        return h >= 19 || h < 7;
    }

    readonly property color accent: root.theme.accent || "#ec3013"

    readonly property color ground:  dark ? "#201e1d" : "#f3f2f2"
    readonly property color surface: dark ? "#2d2b2b" : "#eae9e9"
    readonly property color ink:     dark ? "#f8f4f4" : "#201e1d"
    readonly property color ink2:    dark ? "#bab6b6" : "#605d5d"
    readonly property color ink3:    dark ? "#8a8686" : "#6b6868"

    readonly property color edge:  dark ? Qt.rgba(0.973, 0.957, 0.957, 0.16)
                                        : Qt.rgba(0.125, 0.118, 0.114, 0.14)
    readonly property color rule:  dark ? Qt.rgba(0.973, 0.957, 0.957, 0.10)
                                        : Qt.rgba(0.125, 0.118, 0.114, 0.09)
    readonly property color hover: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.09)
                                        : Qt.rgba(0.125, 0.118, 0.114, 0.07)
    readonly property color sel:   dark ? Qt.rgba(0.973, 0.957, 0.957, 0.14)
                                        : Qt.rgba(0.125, 0.118, 0.114, 0.10)

    readonly property color sheet: dark ? Qt.rgba(0.137, 0.129, 0.125, 1)
                                        : Qt.rgba(0.980, 0.976, 0.976, 1)
    readonly property color panel: sheet
    readonly property color seam:  accent

    // Ink laid on the accent, by the same relative-luminance rule the shell
    // uses, so a pale accent gets dark text rather than white on yellow.
    readonly property color onAccent: {
        const c = root.accent;
        const lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        return lum > 0.6 ? "#201e1d" : "#ffffff";
    }

    // ── geometry and type ─────────────────────────────────────────────────
    readonly property real roundingPct: root.theme.rounding === undefined
                                        ? 100 : root.theme.rounding
    readonly property real rf: roundingPct / 100
    readonly property real rSm: Math.round(9 * rf)
    readonly property real r: Math.round(14 * rf)
    readonly property real rWin: r
    readonly property real rPanel: r
    readonly property real rPill: r
    readonly property real rTile: r
    readonly property real rCard: r
    readonly property real barHeight: 0

    readonly property string fontFamily: root.theme.fontFamily || "Inter"
    readonly property real fontScale: root.theme.fontScale || 100
    readonly property real fontFactor: Math.max(75, Math.min(150, fontScale)) / 100
    function fs(px) { return Math.round(px * fontFactor); }

    readonly property bool textNative: root.theme.textNative === undefined
                                       ? true : root.theme.textNative
}
