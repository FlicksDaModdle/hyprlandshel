import QtQuick

// A panel built only when it is wanted, and let go a while after it was
// last closed.
//
// Every dropdown used to be built at startup and kept for good: all of
// its objects, its live bindings and whatever it tracks (the control
// center's mixer binds every app's audio stream) held in memory, and kept
// up to date, for panels that are open a few seconds a day. Now each is
// built when it opens, kept for half a minute after it closes — so a
// quick close and reopen costs nothing — and then released, with a
// garbage collection to hand the memory back.
//
//     LazyPanel { wanted: Config.UiState.calendarOpen; sourceComponent: Component { CalendarPanel {} } }
Loader {
    id: lazy

    property bool wanted: false
    property int keepMs: 30000
    property bool warm: false

    active: wanted || warm
    onWantedChanged: {
        if (wanted) { cool.stop(); warm = true; }
        else cool.restart();
    }
    Timer {
        id: cool
        interval: lazy.keepMs
        onTriggered: {
            lazy.warm = false;
            Qt.callLater(() => gc());
        }
    }
}
