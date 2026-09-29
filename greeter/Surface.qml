import QtQuick
import Quickshell
import "shell/modules/common"

// One screen of the greeter: the shell's own login screen (LoginView, the
// lock screen's too), with the greeter's people, sessions and power.
//
// Every screen gets the ground and the clock; only the primary one gets the
// card, since there is one keyboard and one person typing into it.
LoginView {
    id: surface

    required property var greeter
    readonly property var g: greeter

    auth: g
    userName: g.user ? g.user.display : (g.users.length === 0 ? "No users found" : "")
    pictures: g.user ? [g.user.icon] : []
    canStepUser: g.users.length > 1
    onStepUser: delta => g.pickUser((g.userIndex + delta + g.users.length) % g.users.length)

    sessionName: g.session ? g.session.name : ""
    canStepSession: g.sessions.length > 1
    onStepSession: delta => g.sessionIndex = (g.sessionIndex + delta + g.sessions.length) % g.sessions.length

    cornerText: g.hostname + (g.preview ? "  ·  preview" : "")
    onPower: action => g.power(action)

    // A preview in your own session takes the whole screen and the
    // keyboard, so it needs a way out. Under greetd there is nowhere to go.
    onEscapeOnEmpty: if (g.preview) Qt.quit()

    Connections {
        target: surface.g
        function onRejected() { if (surface.primary) surface.shake(); }
    }
}
