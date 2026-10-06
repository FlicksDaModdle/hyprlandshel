pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Timers, the pomodoro and alarms.
//
// Kept in ~/.local/state/hyprshell/timers.json with absolute end times, so
// a running timer survives the shell restarting; one that ran out while
// the shell was down rings as soon as it is back. When one is up it says
// so as a notification (with Again, or Snooze for an alarm) and a sound.
// Alarms ring through Do not disturb — that is what an alarm is for.
//
// The bar shows the soonest countdown while anything runs (TimerPill),
// and the panel (TimersPanel) is where they are set.
Singleton {
    id: root

    // [{ id, label, total, endsAt, left, running }] — total and left in
    // seconds, endsAt in ms since the epoch while running.
    property var timers: []
    // { phase: "idle" | "work" | "short" | "long", endsAt, left, running,
    //   done (work sessions finished), day (the date they count for) }
    property var pomo: ({ phase: "idle", endsAt: 0, left: 0, running: false, done: 0, day: "" })
    // Minutes.
    property int pomoWork: 25
    property int pomoShort: 5
    property int pomoLong: 15
    property int pomoEvery: 4
    // [{ id, h, m, days: [0..6] (Sunday first; empty is once), label, on,
    //   last ("YYYY-MM-DD HH:MM" it last rang) }]
    property var alarms: []
    property bool sound: true

    property bool ready: false
    property real now: Date.now()
    property int nextId: 1

    readonly property var running: timers.filter(t => t.running)
    readonly property bool pomoActive: pomo.phase !== "idle"
    readonly property bool anyActive: running.length > 0 || (pomoActive && pomo.running)
    readonly property bool anyPaused: timers.some(t => !t.running) || (pomoActive && !pomo.running)
    readonly property var nextAlarm: {
        let best = null;
        for (const a of alarms) {
            if (!a.on) continue;
            const at = nextRing(a, now);
            if (at && (!best || at < best.at)) best = { alarm: a, at: at };
        }
        return best;
    }

    // What the bar shows: the countdown that ends first.
    readonly property var soonest: {
        let best = null;
        for (const t of running)
            if (!best || t.endsAt < best.endsAt) best = { kind: "timer", label: t.label, endsAt: t.endsAt };
        if (pomoActive && pomo.running && (!best || pomo.endsAt < best.endsAt))
            best = { kind: "pomodoro", label: phaseName(pomo.phase), endsAt: pomo.endsAt };
        return best;
    }

    function leftOf(t) {
        return t.running ? Math.max(0, Math.round((t.endsAt - now) / 1000)) : t.left;
    }
    function clock(secs) {
        secs = Math.max(0, Math.round(secs));
        const h = Math.floor(secs / 3600), m = Math.floor(secs / 60) % 60, s = secs % 60;
        const two = n => (n < 10 ? "0" : "") + n;
        return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s);
    }
    function phaseName(p) {
        return p === "work" ? "Focus" : p === "short" ? "Short break" : p === "long" ? "Long break" : "";
    }

    // ── timers ────────────────────────────────────────────────────────────
    function addTimer(seconds, label) {
        seconds = Math.round(seconds);
        if (!(seconds > 0)) return;
        const t = { id: nextId++, label: label || defaultLabel(seconds), total: seconds,
                    endsAt: Date.now() + seconds * 1000, left: seconds, running: true };
        timers = timers.concat([t]);
        tick();
        save();
    }
    function defaultLabel(seconds) {
        if (seconds % 3600 === 0) return (seconds / 3600) + " h timer";
        if (seconds % 60 === 0) return (seconds / 60) + " min timer";
        return clock(seconds) + " timer";
    }
    function pauseTimer(id) {
        timers = timers.map(t => t.id === id && t.running
            ? Object.assign({}, t, { running: false, left: leftOf(t) }) : t);
        save();
    }
    function resumeTimer(id) {
        timers = timers.map(t => t.id === id && !t.running
            ? Object.assign({}, t, { running: true, endsAt: Date.now() + t.left * 1000 }) : t);
        tick();
        save();
    }
    function cancelTimer(id) {
        timers = timers.filter(t => t.id !== id);
        save();
    }
    // "10", "10m", "1h30", "90s", "1:30", "2 min" → seconds; 0 if unreadable.
    function parseDuration(text) {
        const s = String(text || "").trim().toLowerCase();
        if (s === "") return 0;
        let m = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/.exec(s);
        if (m) return m[3] !== undefined ? (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]) : (+m[1]) * 60 + (+m[2]);
        if (/^\d+(\.\d+)?$/.test(s)) return Math.round(parseFloat(s) * 60);
        let total = 0, any = false;
        const re = /(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)?/g;
        let rest = s;
        while ((m = re.exec(s)) !== null) {
            if (m[0] === "") { re.lastIndex++; continue; }
            const n = parseFloat(m[1]);
            const u = (m[2] || "m")[0];
            total += u === "h" ? n * 3600 : u === "s" ? n : n * 60;
            any = true;
            rest = rest.replace(m[0], "");
        }
        if (!any || rest.replace(/\band\b|[\s,]+/g, "") !== "") return 0;
        return Math.round(total);
    }

    // ── pomodoro ─────────────────────────────────────────────────────────
    function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd"); }
    function pomoStart() {
        const done = pomo.day === today() ? pomo.done : 0;
        setPhase("work", done);
    }
    function setPhase(phase, done) {
        const mins = phase === "work" ? pomoWork : phase === "short" ? pomoShort : pomoLong;
        pomo = { phase: phase, endsAt: Date.now() + mins * 60000, left: mins * 60, running: true,
                 done: done, day: today() };
        tick();
        save();
    }
    function pomoPause() {
        if (!pomo.running) return;
        pomo = Object.assign({}, pomo, { running: false, left: leftOf(pomo) });
        save();
    }
    function pomoResume() {
        if (pomo.running || pomo.phase === "idle") return;
        pomo = Object.assign({}, pomo, { running: true, endsAt: Date.now() + pomo.left * 1000 });
        tick();
        save();
    }
    // On to the next phase now, as if this one had run out (without the
    // ring).
    function pomoSkip() { advancePomo(false); }
    function pomoStop() {
        pomo = Object.assign({}, pomo, { phase: "idle", running: false, endsAt: 0, left: 0 });
        save();
    }
    function advancePomo(ring) {
        const was = pomo.phase;
        let done = pomo.day === today() ? pomo.done : 0;
        let next;
        if (was === "work") {
            done += 1;
            next = done % Math.max(1, pomoEvery) === 0 ? "long" : "short";
        } else {
            next = "work";
        }
        if (ring) {
            const body = was === "work"
                ? "Session " + done + " done. " + phaseName(next) + ", " + (next === "long" ? pomoLong : pomoShort) + " min."
                : "Break's over — " + pomoWork + " min of focus.";
            notify(phaseName(was) + " finished", body, "normal", []);
            chime(1);
        }
        setPhase(next, done);
    }
    function setPomoLengths(work, short_, long_, every) {
        pomoWork = Math.max(1, Math.round(work));
        pomoShort = Math.max(1, Math.round(short_));
        pomoLong = Math.max(1, Math.round(long_));
        pomoEvery = Math.max(1, Math.round(every));
        save();
    }

    // ── alarms ───────────────────────────────────────────────────────────
    function addAlarm(h, m, days, label) {
        alarms = alarms.concat([{ id: nextId++, h: h, m: m, days: days || [], label: label || "Alarm",
                                  on: true, last: "" }]);
        save();
    }
    function updateAlarm(id, change) {
        alarms = alarms.map(a => a.id === id ? Object.assign({}, a, change) : a);
        save();
    }
    function removeAlarm(id) {
        alarms = alarms.filter(a => a.id !== id);
        save();
    }
    function alarmTime(a) {
        const two = n => (n < 10 ? "0" : "") + n;
        if (Config.Appearance.clock24) return two(a.h) + ":" + two(a.m);
        return ((a.h + 11) % 12 + 1) + ":" + two(a.m) + (a.h < 12 ? " AM" : " PM");
    }
    readonly property var dayNames: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    function daysText(days) {
        if (!days || days.length === 0) return "Once";
        if (days.length === 7) return "Every day";
        const d = days.slice().sort();
        if (d.join() === "1,2,3,4,5") return "Weekdays";
        if (d.join() === "0,6") return "Weekends";
        return d.map(i => dayNames[i]).join(" ");
    }
    // When it next rings, in ms since the epoch.
    function nextRing(a, from) {
        const base = new Date(from);
        for (let add = 0; add < 8; ++add) {
            const d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + add, a.h, a.m, 0, 0);
            if (d.getTime() <= from) continue;
            if (a.days && a.days.length > 0 && a.days.indexOf(d.getDay()) < 0) continue;
            return d.getTime();
        }
        return 0;
    }
    function untilText(ms) {
        const mins = Math.max(0, Math.round((ms - now) / 60000));
        if (mins < 60) return "in " + mins + " min";
        const h = Math.floor(mins / 60), m = mins % 60;
        return "in " + h + " h" + (m ? " " + m + " min" : "");
    }

    // ── keeping time ─────────────────────────────────────────────────────
    // Every second while something counts down, otherwise twice a minute
    // for the alarms.
    Timer {
        interval: root.anyActive ? 1000 : 20000
        running: root.ready
        repeat: true
        triggeredOnStart: true
        onTriggered: root.tick()
    }

    function tick() {
        now = Date.now();
        // Timers that ran out.
        const out = timers.filter(t => t.running && t.endsAt <= now);
        if (out.length > 0) {
            timers = timers.filter(t => !(t.running && t.endsAt <= now));
            for (const t of out) {
                const late = now - t.endsAt > 60000 ? " (while the shell was not running)" : "";
                notify(t.label, "Time's up" + late + ".", "normal", [["again", "Again"]], t.total);
            }
            chime(2);
            save();
        }
        if (pomoActive && pomo.running && pomo.endsAt <= now) advancePomo(true);
        // Alarms: one that falls in the minute just gone (or that was
        // missed by less than ten minutes, as across a suspend) rings once.
        const d = new Date(now);
        for (const a of alarms) {
            if (!a.on) continue;
            const at = new Date(d.getFullYear(), d.getMonth(), d.getDate(), a.h, a.m, 0, 0);
            const late = now - at.getTime();
            if (late < 0 || late > 600000) continue;
            if (a.days && a.days.length > 0 && a.days.indexOf(at.getDay()) < 0) continue;
            const key = Qt.formatDateTime(at, "yyyy-MM-dd HH:mm");
            if (a.last === key) continue;
            const change = { last: key };
            if (!a.days || a.days.length === 0) change.on = false;   // a one-off is done
            updateAlarm(a.id, change);
            ring(a);
        }
    }

    function ring(a) {
        notify(a.label || "Alarm", alarmTime(a), "critical", [["snooze", "Snooze 5 min"], ["stop", "Stop"]], 0, a.id);
        chime(4);
    }

    // ── telling you ──────────────────────────────────────────────────────
    // As a notification from the shell's own server, so it is in the
    // center and the history too, with the actions answered here.
    component Note: Process {
        id: note
        property int total: 0
        property int alarmId: 0
        stdout: StdioCollector {
            onStreamFinished: {
                const act = text.trim();
                if (act === "again" && note.total > 0) root.addTimer(note.total);
                else if (act === "snooze") {
                    const a = root.alarms.find(x => x.id === note.alarmId);
                    root.addTimer(300, (a ? a.label : "Alarm") + " · snoozed");
                }
            }
        }
        onExited: note.destroy()
    }
    Component { id: noteComp; Note {} }
    function notify(title, body, urgency, actions, total, alarmId) {
        const args = ["notify-send", "-a", "Timers", "-i", "alarm-clock", "-u", urgency || "normal"];
        for (const a of (actions || [])) args.push("-A", a[0] + "=" + a[1]);
        if (actions && actions.length > 0) args.push("--wait");
        args.push(title, body);
        const p = noteComp.createObject(root, { command: args, total: total || 0, alarmId: alarmId || 0 });
        p.running = true;
    }
    // The desktop's own sounds, through PipeWire or Pulse, whichever is
    // there.
    Process { id: chimeProc }
    function chime(times) {
        if (!sound) return;
        chimeProc.command = ["sh", "-c",
            'f=""; for c in /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga '
            + '/usr/share/sounds/freedesktop/stereo/complete.oga /usr/share/sounds/freedesktop/stereo/bell.oga; '
            + 'do [ -f "$c" ] && { f=$c; break; }; done; '
            + 'i=0; while [ $i -lt "$1" ]; do i=$((i+1)); '
            + 'if [ -n "$f" ]; then pw-play "$f" 2>/dev/null || paplay "$f" 2>/dev/null; '
            + 'else canberra-gtk-play -i alarm-clock-elapsed 2>/dev/null || printf "\\a"; sleep 0.6; fi; done',
            "chime", String(times)];
        chimeProc.running = true;
    }

    // ── kept on disk ─────────────────────────────────────────────────────
    readonly property string path: {
        const base = Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state");
        return base + "/hyprshell/timers.json";
    }
    function serialise() {
        return JSON.stringify({
            timers: timers, pomo: pomo, alarms: alarms, sound: sound, nextId: nextId,
            pomoWork: pomoWork, pomoShort: pomoShort, pomoLong: pomoLong, pomoEvery: pomoEvery
        }, null, 1);
    }
    function save() {
        if (!ready) return;
        mkdir.running = true;
        file.setText(serialise());
    }
    function adopt(text) {
        try {
            const j = JSON.parse(text || "{}");
            timers = Array.isArray(j.timers) ? j.timers : [];
            alarms = Array.isArray(j.alarms) ? j.alarms : [];
            if (j.pomo && j.pomo.phase) pomo = j.pomo;
            if (typeof j.sound === "boolean") sound = j.sound;
            if (j.nextId > 0) nextId = j.nextId;
            for (const k of ["pomoWork", "pomoShort", "pomoLong", "pomoEvery"])
                if (j[k] > 0) root[k] = j[k];
        } catch (e) {
            console.warn("Timers: could not read " + path + ": " + e);
        }
        ready = true;
        tick();
    }
    Process { id: mkdir; command: ["mkdir", "-p", root.path.replace(/\/[^/]*$/, "")] }
    FileView {
        id: file
        path: root.path
        printErrors: false
        preload: true
        blockWrites: true
        onLoaded: if (!root.ready) root.adopt(file.text())
        onLoadFailed: error => {
            // First run: nothing kept yet.
            if (error === FileViewError.FileNotFound) { root.ready = true; root.tick(); }
            else console.warn("Timers: could not read " + root.path);
        }
    }
}
