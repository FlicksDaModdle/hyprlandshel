pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import "../config" as Config
import "." as Services

// Face unlock with Howdy, for Settings → Login screen.
//
// What is there is read without asking anyone for anything: Howdy and its
// PAM module, the lock screen's face service (/etc/pam.d/hyprshell-lock),
// greetd's PAM file, the cameras, the one Howdy is told to use, and how
// many faces are enrolled. What changes anything goes through
// scripts/howdy-setup.sh under pkexec, which asks for your password: it
// writes PAM files and Howdy's config, and enrols faces (always yours).
Singleton {
    id: root

    readonly property string script: Services.Agent.shellDir + "/scripts/howdy-setup.sh"

    property bool howdyInstalled: false
    property bool pamModule: false
    readonly property bool installed: howdyInstalled && pamModule
    property bool lockOn: false
    property bool greeterOn: false
    readonly property bool on: lockOn || greeterOn
    // [{ path, name, ir }]
    property var cameras: []
    property string camera: ""
    // -1 while unknown (Howdy's list may want root to read).
    property int faces: -1
    property bool greeterInstalled: false

    property bool busy: false
    property string status: ""
    property bool failed: false

    function refresh() {
        probe.running = true;
        lockFile.reload();
        greetdFile.reload();
    }
    Component.onCompleted: refresh()

    FileView {
        id: lockFile
        path: "/etc/pam.d/hyprshell-lock"
        printErrors: false
        onLoaded: root.lockOn = text().indexOf("pam_howdy") >= 0
        onLoadFailed: root.lockOn = false
    }
    FileView {
        id: greetdFile
        path: "/etc/pam.d/greetd"
        printErrors: false
        onLoaded: root.greeterOn = text().indexOf("hyprshell-face") >= 0
        onLoadFailed: root.greeterOn = false
    }

    Process {
        id: probe
        command: ["sh", "-c", `
            command -v howdy >/dev/null 2>&1 && echo howdy
            for d in /usr/lib/security /lib/security /usr/lib64/security /lib64/security /usr/lib/x86_64-linux-gnu/security; do
                [ -f "$d/pam_howdy.so" ] && { echo pam; break; }
            done
            [ -d /usr/share/hyprshell-greeter ] && echo greeter
            for v in /sys/class/video4linux/video*; do
                [ -e "$v/name" ] || continue
                # Capture nodes only; each camera has a metadata node too.
                [ "$(cat "$v/index" 2>/dev/null || echo 0)" = 0 ] || continue
                printf 'cam\\t/dev/%s\\t%s\\n' "\${v##*/}" "$(cat "$v/name")"
            done
            for c in /etc/howdy/config.ini /usr/lib/security/howdy/config.ini /lib/security/howdy/config.ini; do
                [ -r "$c" ] || continue
                sed -n -E 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(.*)$/device\\t\\1/p' "$c" | head -n1
                break
            done
            if command -v howdy >/dev/null 2>&1; then
                out=$(howdy -U "$USER" list 2>/dev/null) && printf 'faces\\t%s\\n' "$(printf '%s\\n' "$out" | grep -cE '^[[:space:]]*[0-9]+')"
            fi
            true`]
        stdout: StdioCollector {
            onStreamFinished: {
                let howdy = false, pam = false, greeter = false, faces = -1, device = "";
                const cams = [];
                for (const line of text.split("\n")) {
                    const t = line.split("\t");
                    if (t[0] === "howdy") howdy = true;
                    else if (t[0] === "pam") pam = true;
                    else if (t[0] === "greeter") greeter = true;
                    else if (t[0] === "cam" && t.length >= 3)
                        cams.push({ path: t[1], name: t[2].trim(), ir: /\bIR\b|infrared/i.test(t[2]) });
                    else if (t[0] === "device") device = (t[1] || "").trim();
                    else if (t[0] === "faces") faces = parseInt(t[1], 10);
                }
                root.howdyInstalled = howdy;
                root.pamModule = pam;
                root.greeterInstalled = greeter;
                root.cameras = cams;
                root.camera = device;
                root.faces = isFinite(faces) ? faces : -1;
            }
        }
    }

    function cameraLabel(c) { return c.name + (c.ir ? " (IR)" : "") + " · " + c.path.replace("/dev/", ""); }

    // ── changes, through pkexec ─────────────────────────────────────────
    function run(args, working, done) {
        if (root.busy) return;
        root.busy = true;
        root.failed = false;
        root.status = working;
        runProc.done = done;
        runProc.command = ["pkexec", "bash", root.script].concat(args);
        runProc.running = true;
    }
    function enable() { run([], "Setting up face unlock…", "Face unlock is on: lock the screen to try it"); }
    function disable() { run(["--remove"], "Turning face unlock off…", "Face unlock is off"); }
    function setCamera(path) { run(["--camera", path], "Switching camera…", "Howdy uses " + path); }
    function addFace() { run(["--add-face"], "Look at the camera…", "Your face is added"); }
    function clearFaces() { run(["--clear-faces"], "Removing your faces…", "Your faces are removed"); }

    Process {
        id: runProc
        property string done: ""
        stdout: StdioCollector { id: runOut }
        stderr: StdioCollector { id: runErr }
        onExited: code => {
            root.busy = false;
            root.refresh();
            if (code === 0) { root.status = runProc.done; return; }
            root.failed = true;
            // pkexec: 126 a dismissed or wrong password, 127 not allowed.
            if (code === 126 || code === 127) { root.status = "Not changed: the password wasn't given"; return; }
            const said = (runErr.text.trim() || runOut.text.trim()).split("\n").filter(l => l.trim() !== "");
            root.status = (said.length ? said[said.length - 1] : "That didn't work").replace(/^howdy-setup\.sh: /, "");
        }
    }

    // ── trying it ───────────────────────────────────────────────────────
    // The lock screen's own face service, run here.
    function test() {
        if (root.busy || testPam.active || !root.lockOn) return;
        root.failed = false;
        root.status = "Look at the camera…";
        if (!testPam.start()) { root.failed = true; root.status = "Couldn't start the face check"; }
    }
    readonly property bool testing: testPam.active
    PamContext {
        id: testPam
        config: "hyprshell-lock"
        user: Services.SysInfo.user
        onResponseRequiredChanged: if (responseRequired) abort()
        onCompleted: result => {
            root.failed = result !== PamResult.Success;
            root.status = result === PamResult.Success ? "Recognised you" : "Didn't recognise you";
        }
        onError: err => { root.failed = true; root.status = "The face check couldn't run"; }
    }
}
