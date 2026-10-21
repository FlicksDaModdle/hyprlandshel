import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import "../../config" as Config
import "../../services" as Services

// The lock screen's password, one for every monitor. Each monitor has a
// lock surface of its own, and which of them the compositor sends the
// keyboard to is its business (the focused monitor, the one under the
// pointer): with one shared state, what you type lands in the field
// whichever screen has the keys, and every screen's card shows it.
//
// Your face, too, when Howdy is set up (Settings → Login screen, or scripts/howdy-setup.sh): the moment
// the screen locks, a face-only PAM service (/etc/pam.d/hyprshell-lock)
// looks for you, and unlocks if it finds you. The password works all the
// while beside it, through `login` as before: pressing Enter stops the
// face attempt and checks what was typed.
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

    // ── your face ─────────────────────────────────────────────────────────
    // There once setup.sh has written the service; read, not just looked
    // for, so a file that is there but unreadable counts as not set up.
    property bool faceEnabled: false
    FileView {
        path: "/etc/pam.d/hyprshell-lock"
        printErrors: false
        onLoaded: root.faceEnabled = text().indexOf("pam_howdy") >= 0
        onLoadFailed: root.faceEnabled = false
    }
    // What the face attempt is doing, for the line under the field.
    property string info: ""
    readonly property bool faceLooking: face.active
    readonly property bool canRetryFace: faceEnabled && !face.active && !pam.active
    function retryFace() {
        if (!root.canRetryFace) return;
        root.info = "Looking for you…";
        if (!face.start()) root.info = "";
    }
    // When the screen locks, and when it is woken.
    function begin() {
        root.reset();
        root.retryFace();
    }
    function stop() {
        if (face.active) face.abort();
        root.info = "";
    }

    PamContext {
        id: face
        config: "hyprshell-lock"
        user: Services.SysInfo.user
        // A face-only service asks nothing; anything it does ask is not
        // for us to answer with a password.
        onResponseRequiredChanged: if (responseRequired) abort()
        onCompleted: result => {
            if (result === PamResult.Success) {
                root.info = "";
                root.reset();
                Config.UiState.locked = false;
            } else {
                root.info = "Face not recognised · type your password";
            }
        }
        onError: err => { root.info = ""; }
    }

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
        // Enter on an empty field tries your face again.
        if (entered.length === 0) { retryFace(); return; }
        if (pam.active) return;
        if (face.active) face.abort();
        info = "";
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
