pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Services

// The keyring, unlocked after a login with your face (Settings → Login
// screen → Keyring), through scripts/face-keyring.sh.
//
// A face login has no password to hand the keyring, so its password is
// kept for it: sealed with the laptop's TPM (systemd-creds, a credential of
// yours alone), useless off this machine. When the shell starts it is
// unsealed and the login keyring unlocked — a no-op after a password
// login, where the keyring is open already.
//
// The password is typed once, here, goes to the script on its stdin, and
// isn't kept: the keyring itself checks it before anything is stored.
Singleton {
    id: root

    readonly property string script: Services.Agent.shellDir + "/scripts/face-keyring.sh"

    // systemd-creds can seal a credential of yours alone from 256 on.
    property int credsVersion: 0
    property bool tpm: false
    property bool keyringInstalled: false
    readonly property bool available: credsVersion >= 256 && tpm && keyringInstalled
    property bool stored: false
    property bool probed: false

    property bool busy: false
    property string status: ""
    property bool failed: false

    function refresh() { check.running = true; }
    Component.onCompleted: refresh()

    Process {
        id: check
        command: ["bash", root.script, "--check"]
        stdout: StdioCollector {
            onStreamFinished: {
                let creds = 0, tpm = false, keyring = false, stored = false;
                for (const line of text.split("\n")) {
                    const t = line.split("\t");
                    if (t[0] === "creds") creds = parseInt(t[1], 10) || 0;
                    else if (t[0] === "tpm") tpm = t[1] === "yes";
                    else if (t[0] === "keyring") keyring = true;
                    else if (t[0] === "stored") stored = true;
                }
                const first = !root.probed;
                root.credsVersion = creds;
                root.tpm = tpm;
                root.keyringInstalled = keyring;
                root.stored = stored;
                root.probed = true;
                // Once, as the shell starts.
                if (first && stored) root.unlock();
            }
        }
    }

    function unlock() {
        if (root.busy || !root.stored) return;
        root.busy = true;
        root.failed = false;
        run.mode = "unlock";
        run.command = ["bash", root.script, "--unlock"];
        run.running = true;
    }

    function store(password) {
        if (root.busy || password === "") return;
        root.busy = true;
        root.failed = false;
        root.status = "Checking it with the keyring…";
        run.mode = "store";
        run.pending = password;
        run.command = ["bash", root.script, "--store"];
        run.running = true;
    }

    function forget() {
        if (root.busy) return;
        root.busy = true;
        run.mode = "forget";
        run.command = ["bash", root.script, "--forget"];
        run.running = true;
    }

    Process {
        id: run
        property string mode: ""
        // The password, until the script has it.
        property string pending: ""
        stdinEnabled: true
        stdout: StdioCollector { id: runOut }
        stderr: StdioCollector { id: runErr }
        onStarted: {
            if (run.pending !== "") {
                run.write(run.pending);
                run.pending = "";
            }
            // Closed, so the script's read ends.
            run.stdinEnabled = false;
        }
        onExited: code => {
            run.stdinEnabled = true;
            run.pending = "";
            root.busy = false;
            const said = runErr.text.trim().split("\n").pop().replace(/^face-keyring\.sh: /, "");
            if (code === 0) {
                root.failed = false;
                root.status = run.mode === "store" ? "Stored, sealed with the TPM: your face opens the keyring now"
                            : run.mode === "forget" ? "Removed: after a face login, the keyring asks for your password"
                            : "";
            } else {
                root.failed = true;
                root.status = said || "That didn't work";
                if (run.mode === "unlock") console.warn("FaceKeyring:", root.status);
            }
            root.refresh();
        }
    }
}
