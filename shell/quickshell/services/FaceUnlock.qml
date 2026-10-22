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
    // The webcam check: on, and which looks (Howdy model ids) have webcam
    // pictures for it, kept beside Howdy's models by howdy-webcam.py.
    property bool webcamCheck: false
    property var webcamIds: []
    FileView {
        id: webcamFile
        path: root.modelsPath !== "" ? root.modelsPath.replace(/\.dat$/, ".webcam.json") : ""
        printErrors: false
        onLoaded: {
            try {
                root.webcamIds = JSON.parse(text() || "[]").map(l => l.howdy_id);
            } catch (e) {
                root.webcamIds = [];
            }
        }
        onLoadFailed: root.webcamIds = []
    }
    // ── Howdy's settings ────────────────────────────────────────────────
    // Read from its config.ini as it is; changed through howdy-setup.sh
    // --set (scripts/howdy-config.py, which takes only the settings it
    // knows, within their ranges). Changes wait in `pending` and go in
    // together, so the password is asked for once, not at every slider.
    property string configPath: ""
    // { "video.certainty": "3.5", "webcam.min_light": "45", … }
    property var config: ({})
    property var pending: ({})
    readonly property bool hasPending: Object.keys(root.pending).length > 0
    FileView {
        id: configFile
        path: root.configPath
        printErrors: false
        onLoaded: {
            const out = {};
            let section = "";
            for (const line of text().split("\n")) {
                const t = line.trim();
                if (t === "" || t.startsWith("#") || t.startsWith(";")) continue;
                const head = /^\[(.+)\]$/.exec(t);
                if (head) { section = head[1]; continue; }
                // The webcam check's options, from its rule.
                if (section === "rubberstamps" && t.startsWith("hyprshell_webcam")) {
                    const option = /(\w+)=(\S+)/g;
                    let m;
                    while ((m = option.exec(t)) !== null) out["webcam." + m[1]] = m[2];
                    continue;
                }
                const kv = /^(\w+)\s*=\s*(.*)$/.exec(line);
                if (kv && section !== "") out[section + "." + kv[1]] = kv[2].trim();
            }
            root.config = out;
        }
    }
    // What it is (or will be, once applied).
    function cfg(name, fallback) {
        if (name in root.pending) return root.pending[name];
        return name in root.config ? root.config[name] : fallback;
    }
    function cfgBool(name, fallback) { return String(root.cfg(name, fallback ? "true" : "false")).toLowerCase() === "true"; }
    function cfgNum(name, fallback) { const n = Number(root.cfg(name, fallback)); return isFinite(n) ? n : fallback; }
    function setCfg(name, value) {
        const next = Object.assign({}, root.pending);
        const v = typeof value === "boolean" ? (value ? "true" : "false") : String(value);
        if (root.config[name] === v) delete next[name];
        else next[name] = v;
        root.pending = next;
    }
    function discardConfig() { root.pending = ({}); }
    function applyConfig() {
        if (!root.hasPending) return;
        const args = Object.keys(root.pending).map(k => k + "=" + root.pending[k]);
        applying.args = args;
        run(["--set"].concat(args), "Changing Howdy's settings…", "Howdy's settings are changed");
    }
    // Pending changes are cleared once they're in (or kept, to try again).
    QtObject { id: applying; property var args: [] }
    // (Later: whether it failed is set after busy goes.)
    onBusyChanged: if (!root.busy && applying.args.length > 0) Qt.callLater(root.afterApply)
    function afterApply() {
        if (!root.failed) root.pending = ({});
        applying.args = [];
        configFile.reload();
    }

    function setWebcamCheck(on) {
        if (on) run(["--webcam-check", "on", root.previewDevice], "Turning the webcam check on…",
                     "The webcam has to recognise you too; in low light the infrared camera decides alone");
        else run(["--webcam-check", "off"], "Turning the webcam check off…", "The infrared camera decides alone");
    }
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
                printf 'config\\t%s\\n' "$c"
                sed -n -E 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(.*)$/device\\t\\1/p' "$c" | head -n1
                # The webcam check (scripts/hyprshell_webcam.py): rubberstamps
                # on, and its rule among them.
                r=$(sed -n '/^\\[rubberstamps\\]/,/^\\[/p' "$c")
                printf '%s\\n' "$r" | grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' \\
                    && printf '%s\\n' "$r" | grep -Eq '^[[:space:]]+hyprshell_webcam' && echo webcamcheck
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
                let howdy = false, pam = false, greeter = false, faces = -1, device = "", models = "", webcamCheck = false, configPath = "";
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
                    else if (t[0] === "webcamcheck") webcamCheck = true;
                    else if (t[0] === "config") configPath = (t[1] || "").trim();
                }
                root.howdyInstalled = howdy;
                root.pamModule = pam;
                root.greeterInstalled = greeter;
                root.cameras = cams;
                root.camera = device;
                root.listedFaces = isFinite(faces) ? faces : -1;
                root.modelsPath = models;
                root.webcamCheck = webcamCheck;
                root.configPath = configPath;
                if (configPath !== "") configFile.reload();
                if (models !== "") { modelsFile.reload(); webcamFile.reload(); }
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
    // Windows Hello's way: the webcam shows you while the infrared camera
    // records. With only the one camera, or a laptop whose two can't
    // stream at once (Howdy fails to open its camera while the webcam
    // runs), Howdy records alone.
    function addFace(alt) {
        if (root.busy) return;
        root.addAlt = alt;
        root.addingAlone = root.previewShared || root.previewDevice === "";
        console.info("FaceUnlock: adding", alt ? "an alternative look" : "a face", "through", root.camera || "Howdy's camera",
                     root.addingAlone ? "(no webcam beside it)" : "while " + root.previewDevice + " shows you");
        root.addFailed = false;
        root.justAdded = false;
        root.startAdding();
    }
    // The webcam first, as Windows Hello does: Howdy starts recording once
    // you can see yourself in the circle (or after five seconds without a
    // picture), not before.
    function startAdding() {
        if (root.addingAlone) {
            root.stopPreview();
            root.launchAdding(false);
            return;
        }
        root.startPreview();
        root.preparing = true;
        if (root.previewReady) cameraSettle.restart();
        else cameraWait.restart();
    }
    // Webcam pictures for the webcam check, from the picture you've just
    // lined up in: five, a third of a second apart.
    function takeStills() {
        cameraWait.stop();
        cameraSettle.stop();
        if (!root.previewReady) { root.launchAdding(false); return; }
        stillsProc.command = ["sh", "-c", `
            out=$1 dir=$2
            mkdir -p "$dir" && chmod 700 "$dir" || exit 1
            rm -f "\${dir:?}/1.jpg" "\${dir:?}/2.jpg" "\${dir:?}/3.jpg" "\${dir:?}/4.jpg" "\${dir:?}/5.jpg"
            for i in 1 2 3 4 5; do cp "$out" "$dir/$i.jpg" || exit 1; sleep 0.33; done`,
            "face-stills", root.previewFile, root.stillsDir];
        stillsProc.running = true;
    }
    Process {
        id: stillsProc
        onExited: code => root.launchAdding(code === 0)
    }
    function launchAdding(withStills) {
        cameraWait.stop();
        cameraSettle.stop();
        runProc.adding = true;
        runProc.recordingAt = 0;
        run((root.addAlt ? ["--add-face", "--alt"] : ["--add-face"]).concat(withStills ? ["--stills", root.stillsDir] : []),
            "Hold still and look at the camera…",
            root.addAlt ? "Your alternative look is added" : "Your face is added");
        // After: busy now, so `adding` never drops in between.
        root.preparing = false;
    }
    // Waiting for it, before Howdy starts.
    property bool preparing: false
    onPreviewReadyChanged: if (root.preparing && root.previewReady) cameraSettle.restart()
    // A moment to see yourself first.
    Timer { id: cameraSettle; interval: 700; onTriggered: if (root.preparing) root.takeStills() }
    Timer { id: cameraWait; interval: 5000; onTriggered: if (root.preparing) root.launchAdding(false) }
    // Howdy is recording (after the password).
    readonly property bool recording: (root.busy && runProc.adding && runProc.recordingAt > 0) || root.holding
    // Howdy takes a second or so; the scan stays on screen a little
    // longer than that, so it can be seen happening.
    property bool holding: false
    property string heldStatus: ""
    Timer {
        id: holdTimer
        onTriggered: {
            root.holding = false;
            root.status = root.heldStatus;
            root.justAdded = true;
            justAddedClear.restart();
        }
    }
    property bool addAlt: false
    property bool addingAlone: false
    // Tried alone once per add, no more.
    property bool retriedAlone: false
    Timer {
        id: retryAlone
        interval: 500
        onTriggered: { root.busy = false; root.startAdding(); }
    }

    function removeLook(id) { run(["--remove-face", String(id)], "Removing that look…", "That look is removed"); }
    function clearFaces() { run(["--clear-faces"], "Removing your faces…", "Your faces are removed"); }

    Process {
        id: runProc
        property string done: ""
        property bool adding: false
        // When recording began ("recording", from howdy-setup.sh), and
        // what else it said.
        property real recordingAt: 0
        property string out: ""
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "recording") runProc.recordingAt = Date.now();
                else runProc.out += line + "\n";
            }
        }
        onStarted: runProc.out = ""
        stderr: StdioCollector { id: runErr }
        onExited: code => {
            root.busy = false;
            root.refresh();
            const adding = runProc.adding;
            runProc.adding = false;
            const said = (runErr.text.trim() || runProc.out.trim()).split("\n").filter(l => l.trim() !== "");
            // The webcam in Howdy's way (the camera busy, or no USB
            // bandwidth left for it): again, with the webcam off. Not for
            // anything else Howdy says — too dark, no face — which the
            // webcam has nothing to do with.
            if (adding && code !== 0 && code !== 126 && code !== 127 && !root.addingAlone && !root.retriedAlone
                    && /No space left on device|Device or resource busy|Failed to (read|open) (the )?camera/i.test(said.join(" "))) {
                console.info("FaceUnlock: Howdy couldn't open its camera beside the webcam; again without it:", said.join(" | "));
                root.retriedAlone = true;
                root.addingAlone = true;
                root.stopPreview();
                root.busy = true;
                runProc.adding = true;
                root.status = "Trying again with the webcam off…";
                retryAlone.restart();
                return;
            }
            if (adding) {
                root.retriedAlone = false;
                if (code !== 0) { root.addFailed = true; addFailedClear.restart(); }
            }
            if (code === 0) {
                root.status = runProc.done;
                if (adding) {
                    const shown = Date.now() - (runProc.recordingAt || Date.now());
                    if (shown < 3000) {
                        root.heldStatus = root.status;
                        root.status = "Hold still and look at the camera…";
                        root.holding = true;
                        holdTimer.interval = 3000 - shown;
                        holdTimer.restart();
                    } else {
                        root.justAdded = true;
                        justAddedClear.restart();
                    }
                }
                return;
            }
            root.failed = true;
            // pkexec: 126 a dismissed or wrong password, 127 not allowed.
            if (code === 126 || code === 127) { root.status = "Not changed: the password wasn't given"; return; }
            root.status = (said.length ? said[said.length - 1] : "That didn't work").replace(/^howdy-(setup\.sh|config): /, "");
        }
    }

    // ── the camera, seen ────────────────────────────────────────────────
    // While a face is being added, the panel shows you through the webcam:
    // ffmpeg writes its picture a dozen times a second to a file (swapped
    // in whole, never half-written), and the panel shows the latest. It
    // goes when the shell goes (setpriv --pdeathsig), so it can't be left
    // holding the camera; one left over from before is stopped at start.
    //
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
    // A webcam besides Howdy's camera, for the webcam check.
    readonly property bool hasWebcam: root.previewDevice !== "" && !root.previewShared
    readonly property bool adding: (root.busy && runProc.adding) || root.preparing || root.holding
    property bool addFailed: false
    Timer { id: addFailedClear; interval: 4000; onTriggered: { root.addFailed = false; if (!root.busy) root.stopPreview(); } }
    // A look was just added: the panel's frame shows the tick a moment.
    property bool justAdded: false
    Timer { id: justAddedClear; interval: 2500; onTriggered: { root.justAdded = false; if (!root.busy) root.stopPreview(); } }

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + (Quickshell.env("UID") || "1000"))
    readonly property string previewFile: root.runtimeDir + "/hyprshell-face-preview.jpg"
    // Where the webcam pictures for the webcam check are put, for
    // howdy-setup.sh (which takes them from nowhere else).
    readonly property string stillsDir: root.runtimeDir + "/hyprshell-face-stills"
    property bool previewing: false
    // The first frame is there.
    property bool previewFileReady: false
    readonly property bool previewReady: root.previewing && root.previewFileReady
    property int previewFrame: 0
    property string previewError: ""
    function startPreview() {
        previewStop.restart();
        if (previewProc.running || root.previewDevice === "" || (root.busy && root.previewShared)) return;
        console.info("FaceUnlock: webcam picture from", root.previewDevice, previewProc.small ? "(MJPEG 640×480)" : "(the camera's own format)");
        root.previewError = "";
        root.previewFileReady = false;
        root.previewing = true;
        previewProc.stopping = false;
        previewProc.command = ["sh", "-c", previewProc.script, "face-preview", root.previewFile, root.previewDevice,
                               previewProc.small ? "1" : ""];
        previewProc.running = true;
    }
    function stopPreview() {
        root.previewing = false;
        root.previewFileReady = false;
        if (!previewProc.running) return;
        previewProc.stopping = true;
        previewProc.signal(15);
    }
    Process {
        id: previewProc
        // Small and compressed first (MJPEG, 640 × 480): the webcam and the
        // infrared camera are often one USB device, and a big raw picture
        // can leave the infrared one no bandwidth. The camera's own format
        // if it can't do that.
        property bool small: true
        property bool stopping: false
        readonly property string script: `
            out=$1 dev=$2 small=$3
            rm -f "$out"
            set -- -nostdin -loglevel error -f v4l2 \${small:+-input_format mjpeg -video_size 640x480} -i "$dev" \\
                -vf fps=12,scale=640:-2 -q:v 5 -update 1 -atomic_writing 1 -y "$out"
            command -v setpriv >/dev/null 2>&1 && exec setpriv --pdeathsig TERM -- ffmpeg "$@"
            exec ffmpeg "$@"`
        // What ffmpeg says, as it says it (it can complain and keep going).
        property string said: ""
        stderr: SplitParser {
            onRead: line => {
                if (line.trim() === "") return;
                previewProc.said = line.trim();
                console.warn("FaceUnlock: ffmpeg:", previewProc.said);
            }
        }
        onStarted: previewProc.said = ""
        onExited: code => {
            if (previewProc.stopping) return;
            const said = previewProc.said;
            console.info("FaceUnlock: webcam picture stopped (" + code + "):", said || "-");
            root.previewing = false;
            root.previewFileReady = false;
            if (code === 127) { root.previewError = "The webcam picture needs ffmpeg"; return; }
            if (previewProc.small && code !== 0) {
                previewProc.small = false;
                root.startPreview();
                return;
            }
            root.previewError = said !== "" ? "The webcam: " + said : "The webcam stopped";
        }
    }
    // Until the first frame is written.
    Timer {
        interval: 150
        repeat: true
        running: root.previewing && !root.previewFileReady
        onTriggered: if (!readyCheck.running) readyCheck.running = true
    }
    Process {
        id: readyCheck
        command: ["test", "-s", root.previewFile]
        onExited: code => {
            if (code !== 0 || !root.previewing) return;
            root.previewFileReady = true;
            console.info("FaceUnlock: first webcam frame in", root.previewFile);
        }
    }
    // On, and still nothing after a few seconds: said, with ffmpeg's last
    // word if it had one.
    Timer {
        interval: 4000
        running: root.previewing && !root.previewFileReady
        onTriggered: {
            root.previewError = "The webcam is on, but no picture has come from it"
                + (previewProc.said !== "" ? ": " + previewProc.said : "");
            console.warn("FaceUnlock:", root.previewError, "(" + root.previewDevice + " → " + root.previewFile + ")");
        }
    }
    // A new frame to show, while it runs.
    Timer { interval: 90; repeat: true; running: root.previewReady; onTriggered: root.previewFrame++ }
    // Not left on with nobody looking.
    Timer { id: previewStop; interval: 180000; onTriggered: root.stopPreview() }
    // One left over from a shell that went without stopping it.
    Process {
        running: true
        command: ["pkill", "-f", "^ffmpeg .*hyprshell-face-preview"]
    }

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
