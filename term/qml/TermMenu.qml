import QtQuick
import Hyprterm

// The right-click menu.
//
// A terminal's copy and paste are on shortcuts nobody outside terminals
// uses — Ctrl-Shift-C, because plain Ctrl-C has meant "interrupt" since
// long before it meant "copy". That is fine once you know it and a dead
// end if you do not, so the same two actions are here, where every other
// program on the desktop keeps them.
//
// It draws itself rather than using a QtQuick Controls Menu: Controls
// menus are native popups with their own window, their own shadow and
// their own idea of what a menu looks like, and this window is drawn to
// a mockup.
Rectangle {
    id: menu

    // The grid it acts on.
    required property var view
    // What to do about tabs, which the menu also offers.
    required property var host

    property bool open: false

    visible: open
    z: 900
    radius: Appearance.rPanel
    color: Appearance.panel
    border.width: 1
    border.color: Appearance.edge
    implicitWidth: 208
    implicitHeight: column.implicitHeight + 12

    // What a paste would insert, read when the menu opens. Kept as state
    // rather than called from the binding below, because reading the
    // clipboard asks the application that owns it for its contents, and
    // a binding would do that on every repaint.
    property string pending: ""

    function openAt(x, y) {
        menu.pending = menu.view.clipboardText();
        menu.open = true;
        // Flip rather than run off the window. A menu opened near the
        // bottom right corner is the normal case, not the odd one: that
        // is where the prompt is.
        const w = menu.parent ? menu.parent.width : 0;
        const h = menu.parent ? menu.parent.height : 0;
        menu.x = Math.max(6, Math.min(x, w - menu.implicitWidth - 6));
        menu.y = Math.max(6, Math.min(y, h - menu.implicitHeight - 6));
    }

    function close() { menu.open = false; }

    // The menu takes the keyboard while it is up, so that Escape closes
    // it rather than being sent to the shell — which is what happened
    // when the grid kept focus: the menu stayed open and the program on
    // the far side got an ESC it had not asked for.
    onOpenChanged: if (open) menu.forceActiveFocus()
    Keys.onPressed: event => {
        menu.close();
        menu.view.forceActiveFocus();
        event.accepted = true;
    }

    // The model is fixed, and whether an entry is available is a binding
    // in the row rather than a field in the list.
    //
    // It was a field once, and every entry in this menu half-worked
    // because of it: choosing Copy cleared the selection, which changed
    // hasSelection, which rebuilt this list, which destroyed and
    // recreated the Repeater's delegates — including the click handler
    // that was still running. The rest of that handler, the part that
    // hands the keyboard back to the grid, never ran, and its ids had
    // gone out of scope anyway. The symptom was the menu working
    // perfectly except that the next thing you typed vanished.
    //
    // An action never changes the shape of the menu it was chosen from.
    readonly property var entries: [
        // Greyed rather than hidden. A menu whose entries move around
        // depending on what is selected makes people read it every time;
        // one whose shape is fixed can be used from memory.
        { n: "Copy",       icon: "file",     act: "copy" },
        { n: "Paste",      icon: "download", act: "paste" },
        { n: "Select all", icon: "check",    act: "selectAll" },
        { n: "New tab",    icon: "plus",     act: "newTab", rule: true },
        { n: "Close tab",  icon: "x",        act: "closeTab" }
    ]

    function available(act) {
        switch (act) {
        case "copy":  return menu.view.hasSelection;
        case "paste": return menu.pending.length > 0;
        default:      return true;
        }
    }

    function run(act) {
        switch (act) {
        case "copy":      menu.view.copy(); menu.view.clearSelection(); break;
        case "paste":     menu.view.paste(); break;
        case "selectAll": menu.view.selectAll(); break;
        case "newTab":    menu.host.newTab(); break;
        case "closeTab":  menu.host.closeTab(menu.host.current); break;
        }
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        spacing: 0

        Repeater {
            model: menu.entries

            Item {
                id: item
                required property var modelData
                readonly property bool on: menu.available(modelData.act)
                width: column.width
                height: modelData.rule === true ? 41 : 36

                Rectangle {
                    visible: item.modelData.rule === true
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    width: parent.width
                    height: 1
                    color: Appearance.rule
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 36
                    radius: Appearance.rPill
                    color: rowHover.hovered && item.on
                           ? Appearance.accent : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: item.modelData.icon
                            size: 18
                            opacity: item.on ? 1 : 0.38
                            inkColor: rowHover.hovered && item.on
                                      ? Appearance.inkOnAccent : Appearance.ink
                            accentColor: rowHover.hovered && item.on
                                         ? Appearance.inkOnAccent : Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: item.modelData.n
                            font.pixelSize: Appearance.fs(12)
                            opacity: item.on ? 1 : 0.38
                            color: rowHover.hovered && item.on
                                   ? Appearance.inkOnAccent : Appearance.ink
                        }
                    }

                    HoverHandler {
                        id: rowHover
                        enabled: item.on
                        cursorShape: Qt.PointingHandCursor
                    }
                    // A MouseArea and not a TapHandler.
                    //
                    // A TapHandler takes only a passive grab at press, so
                    // the dismiss layer behind the menu — an ordinary
                    // MouseArea covering the window — took the exclusive
                    // one and the tap was cancelled before it fired.
                    // Every entry in this menu closed it and did nothing,
                    // which looked exactly like the menu working.
                    MouseArea {
                        anchors.fill: parent
                        enabled: item.on
                        onClicked: {
                            // Focus first, then act. The keyboard
                            // belongs to the grid — a paste chosen from
                            // the menu that then needed a click before
                            // Enter would work is not a paste anyone
                            // would use twice — and nothing here should
                            // depend on this delegate outliving the
                            // call that acts.
                            menu.close();
                            menu.view.forceActiveFocus();
                            menu.run(item.modelData.act);
                        }
                    }
                }
            }
        }
    }
}
