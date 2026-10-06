pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// ASUS ROG laptop controls, through asusd (asusctl's service) by way of
// hyprshell-daemon (rust/daemon/src/rog.rs): the performance profile, the
// battery charge limit, the keyboard light, the GPU mode and the panel's
// firmware options. Settings → Laptop and two control-center tiles.
//
// Nothing here on a machine without asusd: `available` stays false and the
// pane and tiles are not shown.
Singleton {
    id: root

    property bool available: false
    property string error: ""
    property var platform: null      // { profile, choices, chargeLimit, … }
    property var kbd: null           // the first keyboard: { brightness, modes, effect, … }
    property var attrs: ({})         // firmware attributes by name
    property var gpu: null           // { mode, pending, choices }

    readonly property bool hasProfiles: !!platform && (platform.choices || []).length > 0
    readonly property bool hasCharge: !!platform && platform.chargeLimit !== null && platform.chargeLimit !== undefined
    readonly property bool hasKbd: !!kbd
    readonly property bool hasGpu: !!gpu && gpu.mode !== ""

    readonly property var profileNames: ({ 0: "Balanced", 1: "Performance", 2: "Quiet", 3: "Low power", 4: "Custom" })
    function profileName(p) { return root.profileNames[p] || "Profile " + p; }
    // Quiet, Balanced, Performance — the order people think in, not asusd's.
    readonly property var profiles: {
        const order = [3, 2, 0, 1, 4];
        const have = root.platform ? root.platform.choices || [] : [];
        return order.filter(p => have.indexOf(p) >= 0);
    }
    readonly property int profile: root.platform && root.platform.profile !== null ? root.platform.profile : -1

    readonly property var kbdModeNames: ({ 0: "Static", 1: "Breathe", 2: "Rainbow", 3: "Wave", 4: "Star", 5: "Rain",
                                           6: "Highlight", 7: "Laser", 8: "Ripple", 10: "Pulse", 11: "Comet", 12: "Flash" })
    readonly property var kbdLevels: ["Off", "Low", "Medium", "High"]
    readonly property int kbdBrightness: root.kbd && root.kbd.brightness !== null ? root.kbd.brightness : -1
    readonly property int kbdMode: root.kbd && root.kbd.effect ? root.kbd.effect.mode : -1

    readonly property var gpuNames: ({ integrated: "Integrated", hybrid: "Hybrid", ultimate: "Ultimate" })
    readonly property var gpuNotes: ({
        integrated: "Only the built-in graphics; the NVIDIA GPU is off. Longest battery life.",
        hybrid: "The built-in graphics, with the NVIDIA GPU for what asks for it.",
        ultimate: "The NVIDIA GPU drives the screen directly. Fastest, most power."
    })

    // The firmware switches worth a toggle, with what they are called.
    readonly property var attrNames: ({
        panel_overdrive: ["Panel overdrive", "Faster pixel response; can show faint ghosting"],
        mini_led_mode: ["MiniLED dimming", "Local dimming on a MiniLED panel"],
        boot_sound: ["Boot sound", "The chime at power on"],
        mcu_powersave: ["Low-power standby", "Less battery drain while suspended or off"],
        screen_auto_brightness: ["Automatic panel brightness", "The panel's own ambient adjustment"],
        panel_hd_mode: ["Panel HD mode", "The panel's high-resolution mode"]
    })
    readonly property var toggles: Object.keys(root.attrNames).filter(n => {
        const a = root.attrs[n];
        return !!a && a.value !== null && (a.possible || []).join(",") === "0,1";
    })

    function send(o) { Services.Daemon.send(o); }
    function setProfile(p) { send({ cmd: "rog-profile", profile: p }); }
    function cycleProfile() {
        const l = root.profiles;
        if (l.length === 0) return;
        setProfile(l[(l.indexOf(root.profile) + 1) % l.length]);
    }
    // A dragged slider sends its last value only.
    property int pendingCharge: -1
    function setCharge(v) { pendingCharge = Math.round(v); chargeSoon.restart(); }
    Timer { id: chargeSoon; interval: 350; onTriggered: root.send({ cmd: "rog-charge", limit: root.pendingCharge }) }
    function fullCharge() { send({ cmd: "rog-full-charge" }); }
    function setKbdBrightness(l) { send({ cmd: "rog-kbd-brightness", level: l }); }
    function cycleKbd() { setKbdBrightness((Math.max(0, root.kbdBrightness) + 1) % 4); }
    function setKbdMode(m, colour) {
        const e = root.kbd && root.kbd.effect ? root.kbd.effect : {};
        send({ cmd: "rog-kbd-mode", mode: m, colour: colour || e.colour || "#ffffff",
               colour2: e.colour2 || "#000000", speed: e.speed || "Med", direction: e.direction || "Right" });
    }
    function setAttr(name, v) { send({ cmd: "rog-attr", name: name, value: v }); }
    function setGpu(mode) { send({ cmd: "rog-gpu", mode: mode }); }

    // The keyboard in the accent colour, when chosen: set again whenever
    // the accent changes (a new swatch, the wallpaper, light to dark).
    readonly property bool followAccent: Config.Appearance.rogKbdAccent && root.hasKbd
    readonly property string accentHex: String(Config.Appearance.accent)
    onFollowAccentChanged: if (followAccent) accentSoon.restart()
    onAccentHexChanged: if (followAccent) accentSoon.restart()
    Timer {
        id: accentSoon
        interval: 300
        onTriggered: {
            const m = root.kbdMode === 1 ? 1 : 0; // keep Breathe; otherwise Static
            root.setKbdMode(m, root.accentHex);
        }
    }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "rog") {
                root.available = ev.available === true;
                if (!root.available) { root.platform = null; root.kbd = null; root.attrs = {}; root.gpu = null; return; }
                root.platform = ev.platform || null;
                root.kbd = (ev.aura || [])[0] || null;
                root.attrs = ev.attrs || {};
                root.gpu = ev.gpu || null;
                root.error = "";
            } else if (ev.ev === "rog-error") {
                root.error = ev.message || "";
                clearError.restart();
            } else if (ev.ev === "exited") {
                root.available = false;
            }
        }
    }
    Timer { id: clearError; interval: 8000; onTriggered: root.error = "" }
}
