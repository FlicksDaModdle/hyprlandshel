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
    // How many looks Howdy knows you by; -1 while unknown (Howdy's list
    // may want root to read).
    readonly property int faces: root.looks !== null ? root.looks.length : root.listedFaces
    property int listedFaces: -1
    // Each look: { id, label, time (a Date) }, read from Howdy's own file
    // of them; null when it can't be read.
    property var looks: null
    property string modelsPath: ""
    FileView {
        id: modelsFile
        path: root.modelsPath
        printErrors: false
        onLoaded: {
            try {
                const all = JSON.parse(text() || "[]");
                root.looks = all.map(m => ({ id: m.id, label: String(m.label || "Face"),
                                             time: new Date(Number(m.time) * 1000) }));
            } catch (e) {
                root.looks = null;
            }
        }
        // Not there: no looks yet (if the folder can be read at all).
        onLoadFailed: err => root.looks = err === FileViewError.FileNotFound ? [] : null
    }
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
                # Greyscale only is an infrared camera, whatever its name
                # says (the kernel cuts names at 32 characters).
                ir=0
                if command -v v4l2-ctl >/dev/null 2>&1; then
                    f=$(v4l2-ctl -d "/dev/\${v##*/}" --list-formats 2>/dev/null)
                    printf '%s' "$f" | grep -q "'GREY'" && ! printf '%s' "$f" | grep -qE "'(YUYV|MJPG|NV12|RGB3)'" && ir=1
                fi
                printf 'cam\\t/dev/%s\\t%s\\t%s\\n' "\${v##*/}" "$(cat "$v/name")" "$ir"
            done
            for c in /etc/howdy/config.ini /usr/lib/security/howdy/config.ini /lib/security/howdy/config.ini; do
                [ -r "$c" ] || continue
                sed -n -E 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(.*)$/device\\t\\1/p' "$c" | head -n1
                break
            done
            # Where Howdy keeps your looks (Howdy 3, then Howdy 2): the
            # folder, and your file in it if there is one yet.
            for m in /etc/howdy/models /usr/lib/security/howdy/models /lib/security/howdy/models; do
                [ -d "$m" ] || continue
                printf 'models\t%s\n' "$m/$USER.dat"
                break
            done
            if command -v howdy >/dev/null 2>&1; then
                out=$(howdy -U "$USER" list 2>/dev/null) && printf 'faces\\t%s\\n' "$(printf '%s\\n' "$out" | grep -cE '^[[:space:]]*[0-9]+')"
            fi
            true`]
        stdout: StdioCollector {
            onStreamFinished: {
                let howdy = false, pam = false, greeter = false, faces = -1, device = "", models = "";
                const cams = [];
                for (const line of text.split("\n")) {
                    const t = line.split("\t");
                    if (t[0] === "howdy") howdy = true;
                    else if (t[0] === "pam") pam = true;
                    else if (t[0] === "greeter") greeter = true;
                    else if (t[0] === "cam" && t.length >= 3)
                        cams.push({ path: t[1], name: t[2].trim(), ir: t[3] === "1" || /\bIR\b|infrared/i.test(t[2]) });
                    else if (t[0] === "device") device = (t[1] || "").trim();
                    else if (t[0] === "faces") faces = parseInt(t[1], 10);
                    else if (t[0] === "models") models = (t[1] || "").trim();
                }
                root.howdyInstalled = howdy;
                root.pamModule = pam;
                root.greeterInstalled = greeter;
                root.cameras = cams;
                root.camera = device;
                root.listedFaces = isFinite(faces) ? faces : -1;
                root.modelsPath = models;
                if (models !== "") modelsFile.reload();
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
    // The camera can be open in one place at a time: the preview lets go
    // before Howdy takes it, and comes back when Howdy is done.
    function addFace(alt) {
        if (root.busy) return;
        // Windows Hello's way: the ordinary camera shows you while the
        // infrared one records. With only the one camera, it has to let go.
        if (root.previewShared) {
            root.resumePreview = root.previewing;
            root.stopPreview();
        } else {
            root.startPreview();
        }
        root.addFailed = false;
        runProc.adding = true;
        run(alt ? ["--add-face", "--alt"] : ["--add-face"],
            "Hold still and look at the camera…",
            alt ? "Your alternative look is added" : "Your face is added");
    }
    function removeLook(id) { run(["--remove-face", String(id)], "Removing that look…", "That look is removed"); }
    function clearFaces() { run(["--clear-faces"], "Removing your faces…", "Your faces are removed"); }

    Process {
        id: runProc
        property string done: ""
        property bool adding: false
        stdout: StdioCollector { id: runOut }
        stderr: StdioCollector { id: runErr }
        onExited: code => {
            root.busy = false;
            root.refresh();
            if (root.resumePreview) { root.resumePreview = false; root.startPreview(); }
            const adding = runProc.adding;
            runProc.adding = false;
            if (adding && code !== 0) { root.addFailed = true; addFailedClear.restart(); }
            if (code === 0) {
                root.status = runProc.done;
                if (adding) { root.justAdded = true; justAddedClear.restart(); }
                return;
            }
            root.failed = true;
            // pkexec: 126 a dismissed or wrong password, 127 not allowed.
            if (code === 126 || code === 127) { root.status = "Not changed: the password wasn't given"; return; }
            const said = (runErr.text.trim() || runOut.text.trim()).split("\n").filter(l => l.trim() !== "");
            root.status = (said.length ? said[said.length - 1] : "That didn't work").replace(/^howdy-setup\.sh: /, "");
        }
    }

    // ── the camera, seen ────────────────────────────────────────────────
    // What the face camera sees, for lining your face up before adding it:
    // ffmpeg writes a frame a dozen times a second to a file (swapped in
    // whole, never half-written), and the panel shows the latest.
    readonly property string previewFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hyprshell-face-preview.jpg"
    // The ordinary camera when there is one besides Howdy's (an infrared
    // picture is a grey ghost, and Howdy needs its camera to itself while
    // it records), else Howdy's.
    readonly property string previewDevice: {
        const howdy = root.camera !== "" ? root.camera
                    : (root.cameras.find(c => c.ir) || root.cameras[0] || { path: "" }).path;
        const rgb = root.cameras.find(c => !c.ir && c.path !== howdy);
        return rgb ? rgb.path : howdy;
    }
    readonly property bool previewShared: root.previewDevice === root.camera
                                          || !!root.cameras.find(c => c.ir && c.path === root.previewDevice)
    readonly property bool adding: root.busy && runProc.adding
    property bool addFailed: false
    Timer { id: addFailedClear; interval: 2500; onTriggered: root.addFailed = false }
    readonly property bool previewing: previewProc.running
    property bool resumePreview: false
    // A look was just added: the panel's frame shows the tick a moment.
    property bool justAdded: false
    Timer { id: justAddedClear; interval: 2500; onTriggered: root.justAdded = false }
    property int previewFrame: 0
    property string previewError: ""
    function startPreview() {
        if (previewProc.running || root.previewDevice === "" || (root.busy && root.previewShared)) return;
        root.previewError = "";
        previewProc.command = ["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "v4l2", "-i", root.previewDevice,
                               "-vf", "fps=12,scale=640:-2", "-q:v", "6", "-update", "1", "-atomic_writing", "1",
                               "-y", root.previewFile];
        previewProc.running = true;
        previewStop.restart();
    }
    function stopPreview() { if (previewProc.running) previewProc.signal(15); }
    Process {
        id: previewProc
        stderr: StdioCollector { id: previewErr }
        onExited: code => {
            if (code !== 0 && code !== 255 && previewErr.text.trim() !== "")
                root.previewError = code === 127 ? "The preview needs ffmpeg" : previewErr.text.trim().split("\n").pop();
        }
    }
    // A new frame to show, while it runs.
    Timer { interval: 90; repeat: true; running: previewProc.running; onTriggered: root.previewFrame++ }
    // Not left running with nobody looking.
    Timer { id: previewStop; interval: 180000; onTriggered: root.stopPreview() }

    // ── trying it ───────────────────────────────────────────────────────
    // The lock screen's own face service, run here.
    function test() {
        if (root.busy || testPam.active || !root.lockOn) return;
        root.stopPreview();
        root.failed = false;
        root.status = "Look at the camera…";
        if (!testPam.start()) { root.failed = true; root.status = "Couldn't start the face check"; }
    }
    readonly property bool testing: testPam.active
    PamContext {
        id: testPam
        config: "hyprshell-lock"
        user: Services.SysInfo.user
        // What Howdy said on the way, so a failure says why.
        property string said: ""
        onPamMessage: if (message && message.trim() !== "") said = message.trim()
        onActiveChanged: if (active) said = ""
        onResponseRequiredChanged: if (responseRequired) abort()
        onCompleted: result => {
            root.failed = result !== PamResult.Success;
            root.status = result === PamResult.Success ? "Recognised you"
                : "Didn't recognise you" + (testPam.said !== "" ? " · Howdy says: " + testPam.said : "");
        }
        onError: err => { root.failed = true; root.status = "The face check couldn't run"; }
    }
}
