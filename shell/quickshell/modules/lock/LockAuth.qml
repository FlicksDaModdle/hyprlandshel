import QtQuick
import Quickshell
import Quickshell.Services.Pam
import "../../config" as Config
import "../../services" as Services

// The lock screen's password, one for every monitor. Each monitor has a
// lock surface of its own, and which of them the compositor sends the
// keyboard to is its business (the focused monitor, the one under the
// pointer): with one shared state, what you type lands in the field
// whichever screen has the keys, and every screen's card shows it.
//
// LoginView's `auth` (see its header).
Scope {
    id: root

    property string entered: ""
    property string status: ""
    property bool failed: false
    readonly property bool busy: pam.active
    // PAM's own words, when it has an error to say.
    readonly property string pamMessage: pam.message && pam.messageIsError ? pam.message : ""

    signal rejected()

    // Which monitors' lock surfaces the compositor has given the keyboard,
    // by screen name; each surface reports its own.
    property var keyboardOn: ({})
    readonly property bool keyboardSomewhere: Object.keys(keyboardOn).some(k => keyboardOn[k])
    function setKeyboard(screen, has) {
        const next = Object.assign({}, keyboardOn);
        next[screen] = has;
        keyboardOn = next;
    }
    onBusyChanged: console.info("lock: " + (busy ? "checking the password" : "done checking"))

    function reset() {
        entered = "";
        status = "";
        failed = false;
    }

    function submit() {
        if (pam.active || entered.length === 0) return;
        status = "Checking…";
        failed = false;
        if (!pam.start()) {
            failed = true;
            status = "Could not start authentication";
        }
    }

    // Never stuck checking: a PAM module that stops answering (a
    // fingerprint reader waiting for a finger, say) would leave the field
    // deaf to every key. After twenty seconds the attempt is called off.
    Timer {
        interval: 20000
        running: pam.active
        onTriggered: {
            pam.abort();
            root.failed = true;
            root.entered = "";
            root.status = "That took too long. Try again.";
            root.rejected();
        }
    }

    PamContext {
        id: pam
        // `login` exists on every distribution; a dedicated
        // /etc/pam.d/hyprshell isn't required for this to work.
        config: "login"
        user: Services.SysInfo.user

        onResponseRequiredChanged: {
            if (responseRequired) respond(root.entered);
        }

        onCompleted: result => {
            if (result === PamResult.Success) {
                root.reset();
                Config.UiState.locked = false;
            } else {
                root.failed = true;
                root.entered = "";
                root.status = result === PamResult.MaxTries ? "Too many attempts" : "Wrong password";
                root.rejected();
            }
        }

        onError: err => {
            root.failed = true;
            root.status = "Authentication unavailable";
        }
    }
}
