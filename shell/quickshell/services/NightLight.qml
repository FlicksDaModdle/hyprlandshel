pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Night light: the screens warmed after dark. Backs the control center's
// "Night light" tile and Settings → Display.
//
// Built in, through hyprshell-daemon (rust/daemon/src/gamma.rs): the
// compositor's gamma control, with a schedule — always, sunset to sunrise
// (worked out for your time zone's city, or a place you give), or set
// times — and fades. Nothing to install and no program left running.
//
// Without the daemon, hyprsunset (or wlsunset) as before: "on" means that
// program running at the temperature, read back from the process table so
// one started from outside shows as on.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    property bool active: false
    readonly property int temperature: prefs.nightTemp
    property bool available: true
    property string backend: "hyprsunset"

    // ── built in ──
    readonly property bool builtin: Services.Daemon.running && Services.Daemon.modules.gamma === true && !builtinRefused
    // The compositor would not give the gamma (and no rival explains it):
    // hyprsunset, if there is one, can still do it its own way.
    property bool builtinRefused: false
    property string error: ""
    property string sunrise: ""
    property string sunset: ""
    property string place: ""
    property string next: ""
    readonly property string mode: prefs.nightMode       // off | on | sun | times

    readonly property string label: active ? temperature + " K"
        : (builtin && mode === "sun" && sunset !== "" ? "at " + sunset
           : builtin && mode === "times" ? "at " + prefs.nightFrom : "off")

    function configure() {
        if (!builtin) return;
        const lat = parseFloat(prefs.nightLat), lon = parseFloat(prefs.nightLon);
        const msg = { cmd: "gamma-config", mode: prefs.nightMode, temp: prefs.nightTemp,
                      from: prefs.nightFrom, to: prefs.nightTo };
        if (isFinite(lat) && isFinite(lon)) { msg.lat = lat; msg.lon = lon; }
        Services.Daemon.send(msg);
    }
    // Every change to the settings, sent once the burst is over (a dragged
    // temperature slider).
    readonly property string config: [builtin, prefs.settingsReady, prefs.nightMode, prefs.nightTemp,
                                      prefs.nightFrom, prefs.nightTo, prefs.nightLat, prefs.nightLon].join("|")
    onConfigChanged: if (builtin && prefs.settingsReady) configSoon.restart()
    Timer { id: configSoon; interval: 120; onTriggered: root.configure() }

    Process {
        id: probe
        command: ["sh", "-c",
            "if pgrep -x hyprsunset >/dev/null 2>&1; then echo 'on hyprsunset'; "
            + "elif pgrep -x wlsunset >/dev/null 2>&1; then echo 'on wlsunset'; "
            + "elif command -v hyprsunset >/dev/null 2>&1; then echo 'off hyprsunset'; "
            + "elif command -v wlsunset >/dev/null 2>&1; then echo 'off wlsunset'; "
            + "else echo 'none'; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(" ");
                if (parts[0] === "none") { root.available = false; root.active = false; return; }
                root.available = true;
                root.active = parts[0] === "on";
                if (parts[1]) root.backend = parts[1];
            }
        }
    }

    // Only to notice hyprsunset or wlsunset started or stopped from
    // outside; anything done here re-checks at once (action's onExited).
    Timer {
        interval: 30000
        running: !root.viaDaemon && !root.builtin
        repeat: true
        triggeredOnStart: true
        onTriggered: probe.running = true
    }

    // hyprshell-daemon reads the process table itself and says when it
    // changes, so neither the timer above nor the probe's sh and pgrep run.
    readonly property bool viaDaemon: Services.Daemon.nightLightLive
    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "gamma") {
                if (root.builtinRefused) return;
                root.active = !!ev.active;
                root.error = ev.error || "";
                root.sunrise = ev.sunrise || "";
                root.sunset = ev.sunset || "";
                root.place = ev.place || "";
                root.next = ev.next || "";
                if (ev.available === false && ev.active && !root.builtinRefused) {
                    // The compositor will not do it: hyprsunset's way, if
                    // there is one, and its state rather than ours.
                    root.builtinRefused = true;
                    root.active = false;
                    root.recheck();
                }
                return;
            }
            if (ev.ev !== "nightlight" || root.builtin) return;
            const run = ev.running || "", inst = ev.installed || "";
            root.available = run !== "" || inst !== "";
            root.active = run !== "";
            if (run !== "") root.backend = run;
            else if (inst !== "") root.backend = inst;
        }
    }
    function recheck() {
        if (viaDaemon) Services.Daemon.send({ cmd: "nl-refresh" });
        else probe.running = true;
    }

    Process { id: action; onExited: root.recheck() }

    // Programs that would fight the built-in one for the screen's colours.
    Process { id: stopRivals; command: ["sh", "-c", "pkill -x hyprsunset; pkill -x wlsunset; true"] }
    onBuiltinChanged: if (builtin) { stopRivals.running = true; configSoon.restart(); }

    function setActive(on) {
        if (builtin) {
            // On a schedule, the tile overrides it until the next change;
            // otherwise it is the switch itself.
            if (mode === "sun" || mode === "times")
                Services.Daemon.send({ cmd: "gamma-override", on: on });
            else
                prefs.nightMode = on ? "on" : "off";
            active = on;
            return;
        }
        if (!available) return;
        active = on;   // optimistic; the probe corrects it
        if (!on) {
            action.command = ["sh", "-c", "pkill -x hyprsunset; pkill -x wlsunset; true"];
        } else if (backend === "hyprsunset") {
            // Replace any existing daemon so the temperature actually changes.
            action.command = ["sh", "-c",
                "pkill -x hyprsunset; hyprsunset -t " + temperature + " >/dev/null 2>&1 &"];
        } else {
            // wlsunset has no "always this temperature" mode, so day and
            // night temperatures are set to the same value.
            action.command = ["sh", "-c",
                "pkill -x wlsunset; wlsunset -T " + (temperature + 100) + " -t " + temperature + " >/dev/null 2>&1 &"];
        }
        action.running = true;
    }

    function toggle() { setActive(!active); }

    function setTemperature(k) {
        prefs.nightTemp = Math.round(Math.max(1900, Math.min(6000, k)));
        if (!builtin && active) setActive(true);
    }
    function setMode(m) { prefs.nightMode = m; }
}
