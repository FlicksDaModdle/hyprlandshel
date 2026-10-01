pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Typing into whatever window has the focus.
//
// The on-screen keyboard is a layer surface that deliberately never
// takes the keyboard, so pressing a key on it cannot reach the
// application the way a real keypress would. Something has to inject
// the event, and Quickshell has no way to do it — there is no binding
// for the virtual-keyboard protocol.
//
// So it shells out, and it tries two things in order:
//
//   wtype    Wayland's own answer. It speaks zwp_virtual_keyboard_v1,
//            which Hyprland implements, and it can send arbitrary text —
//            including characters that are not on any key of the real
//            keyboard. This is the one to have.
//
//   hyprctl  Hyprland's `sendshortcut` dispatcher, which is already
//            installed by definition. It sends a keysym rather than
//            text, so it reaches letters, digits and the named keys but
//            not much else — and it is here so that a machine without
//            wtype gets a keyboard that mostly works rather than one
//            that does nothing at all.
//
// Which one answered is remembered, so the notice in the keyboard can
// say when it is running on the lesser of the two.
Singleton {
    id: root

    // "", "wtype", "hyprctl", or "none" once a send has failed both ways.
    property string backend: ""
    readonly property bool limited: backend === "hyprctl"
    readonly property bool broken: backend === "none"

    // Modifiers currently held down by the on-screen keyboard. Latched
    // rather than held: there is one pointer and it cannot press shift
    // and a letter at the same time.
    property var held: []

    function isHeld(m) { return root.held.indexOf(m) >= 0; }

    function hold(m) {
        const next = root.held.slice();
        const at = next.indexOf(m);
        if (at >= 0) next.splice(at, 1);
        else next.push(m);
        root.held = next;
    }

    function releaseAll() {
        // Caps is the one that stays: it is a lock, which is the whole
        // difference between it and shift.
        root.held = root.isHeld("caps") ? ["caps"] : [];
    }

    // Everything except caps, which is not a modifier to send — it is a
    // state this keyboard keeps for itself and spends on the next letter.
    function sendMods() {
        return root.held.filter(m => m !== "caps");
    }

    function sendText(text) {
        if (!text) return;
        root.run("text", text);
    }

    function sendKey(keysym) {
        if (!keysym) return;
        root.run("key", keysym);
    }

    function run(mode, payload) {
        // The text goes in on stdin rather than in the argument list. It
        // is whatever someone is typing — a password as often as not — and
        // /proc/PID/cmdline is readable by anyone on the machine. (Not the
        // environment either: Process.environment will not take an object
        // assigned at run time on every Qt.)
        proc.pending = String(payload).replace(/\n/g, " ");
        proc.command = ["sh", "-c", root.script, "osk", mode,
                        root.sendMods().join(" ")];
        proc.running = true;
        root.releaseAll();
    }

    // Prints the name of whichever tool did the work, so `backend` can
    // say which one is in use without a separate probe.
    readonly property string script:
        'IFS= read -r text || text=""\n'
      + 'mode="$1"; mods="$2"\n'
      + 'if command -v wtype >/dev/null 2>&1; then\n'
      + '  set --\n'
      + '  for m in $mods; do set -- "$@" -M "$m"; done\n'
      + '  if [ "$mode" = key ]; then set -- "$@" -k "$text"\n'
      + '  else set -- "$@" -- "$text"; fi\n'
        // The modifiers have to be let go again, or wtype leaves them
        // pressed and the next thing typed anywhere arrives shifted.
      + '  for m in $mods; do set -- "$@" -m "$m"; done\n'
      + '  if wtype "$@"; then echo wtype; exit 0; fi\n'
      + 'fi\n'
      + 'if command -v hyprctl >/dev/null 2>&1; then\n'
        // Hyprland spells its modifiers in capitals and joins them with
        // spaces; it wants a keysym, so a character has to already have
        // been turned into one by the caller.
      + '  hmods=""\n'
      + '  for m in $mods; do\n'
      + '    up=$(printf "%s" "$m" | tr "[:lower:]" "[:upper:]")\n'
      + '    hmods="${hmods:+$hmods }$up"\n'
      + '  done\n'
      + '  if hyprctl dispatch sendshortcut "$hmods,$text,activewindow" >/dev/null; then\n'
      + '    echo hyprctl; exit 0\n'
      + '  fi\n'
      + 'fi\n'
      + 'echo none\n'
      + 'exit 1\n'

    Process {
        id: proc
        property string pending: ""
        stdinEnabled: true
        onStarted: proc.write(proc.pending + "\n")
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t === "wtype" || t === "hyprctl" || t === "none")
                    root.backend = t;
            }
        }
    }
}
