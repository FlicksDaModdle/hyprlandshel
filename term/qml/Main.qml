import QtQuick
import QtQuick.Window
import Hyprterm

// The window.
//
// An ordinary Qt toplevel with the compositor's decoration turned off and
// the designed one drawn inside it, exactly as the file manager does —
// see files/qml/Main.qml for why that is the shape rather than a
// layer-shell surface.
Window {
    id: win

    width: 900
    height: 560
    minimumWidth: 320
    minimumHeight: 200
    visible: true
    color: "transparent"

    // The program's own title when it sets one (an OSC from ssh or vim),
    // and the directory otherwise — which is what the concept shows.
    title: term.title !== "" ? term.title
         : (term.cwd !== "" ? "Terminal — " + Appearance.pretty(term.cwd)
                            : "Terminal")

    readonly property bool maximised: win.visibility === Window.Maximized
    function moveTo() { win.startSystemMove(); }
    function toggleMaximised() {
        win.visibility = win.maximised ? Window.Windowed : Window.Maximized;
    }
    function minimise() { win.visibility = Window.Minimized; }

    Term {
        id: term
        Component.onCompleted: {
            // The palette has to be in place before anything is parsed:
            // cells record "the default colour", and what that means is
            // decided here.
            term.setPalette(Appearance.ink, Appearance.bg, Appearance.ansi);
            term.start(startCommand);
        }
        onExited: code => win.close()
    }

    TermFrame {
        anchors.fill: parent
        host: win
        term: term
    }
}
