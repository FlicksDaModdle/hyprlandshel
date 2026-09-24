import QtQuick
import QtQuick.Window
import Hyprterm

// The window.
//
// An ordinary Qt toplevel with the compositor's decoration turned off and
// the designed one drawn inside it, exactly as the file manager does —
// see files/qml/Main.qml for why that is the shape rather than a
// layer-shell surface.
//
// It holds any number of sessions. Each is a Term of its own with its own
// shell, scrollback and title; the window shows one at a time and keeps
// the rest at the same size, so a program in a background tab is never
// surprised by the window it comes back to.
Window {
    id: win

    width: 900
    height: 560
    minimumWidth: 320
    minimumHeight: 200
    visible: true
    color: "transparent"

    // Sessions, oldest first, and which one is on screen.
    property var sessions: []
    property int current: 0
    readonly property var term: current >= 0 && current < sessions.length
                                ? sessions[current] : null

    title: !term ? "Terminal"
         : (term.title !== "" ? term.title
            : (term.cwd !== "" ? "Terminal — " + Appearance.pretty(term.cwd)
                               : "Terminal"))

    readonly property bool maximised: win.visibility === Window.Maximized
    function moveTo() { win.startSystemMove(); }
    function toggleMaximised() {
        win.visibility = win.maximised ? Window.Windowed : Window.Maximized;
    }
    function minimise() { win.visibility = Window.Minimized; }

    Component {
        id: termComponent
        Term {}
    }

    // ── sessions ──────────────────────────────────────────────────────────
    function newTab() {
        const t = termComponent.createObject(win);
        if (!t) return;
        // The palette before the shell: a cell records "the default
        // colour", and what that resolves to is decided here.
        t.setPalette(Appearance.ink, Appearance.bg, Appearance.ansi);
        // At the size the window already is, rather than the 80x24 a new
        // Term starts at — otherwise the first thing a new tab does is
        // redraw itself.
        if (frame.viewRows > 0) t.setSize(frame.viewRows, frame.viewCols);
        t.start(startCommand);
        t.exited.connect(function () { win.closeTerm(t); });
        win.sessions = win.sessions.concat([t]);
        win.current = win.sessions.length - 1;
    }

    function closeTerm(t) {
        const i = win.sessions.indexOf(t);
        if (i < 0) return;
        const rest = win.sessions.slice();
        rest.splice(i, 1);
        win.sessions = rest;
        // The last one closing is the window closing: a terminal with no
        // session in it is a window with nothing to do.
        if (rest.length === 0) { win.close(); return; }
        win.current = Math.min(i, rest.length - 1);
        t.destroy();
    }

    function closeTab(i) {
        if (i >= 0 && i < win.sessions.length) win.closeTerm(win.sessions[i]);
    }
    function selectTab(i) {
        if (i >= 0 && i < win.sessions.length) win.current = i;
    }
    function stepTab(delta) {
        const n = win.sessions.length;
        if (n > 1) win.current = ((win.current + delta) % n + n) % n;
    }

    Component.onCompleted: win.newTab()

    TermFrame {
        id: frame
        anchors.fill: parent
        host: win
        term: win.term
    }
}
