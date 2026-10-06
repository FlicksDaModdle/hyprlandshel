pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config

// Focus: when notifications are quiet, and how each app is treated.
//
//   quiet       Do not disturb switched on, or a schedule running now
//               (and not set aside with the bell for the rest of it).
//   schedules   [{ id, name, from: "22:00", to: "07:00", days: [0..6],
//                  on }] — Sunday is 0; a window that crosses midnight
//               belongs to the day it starts on.
//   rules       { app: "always" | "normal" | "silent" | "mute" }
//                 always  a banner even while quiet
//                 normal  the default
//                 silent  never a banner; kept in the center
//                 mute    neither; only the history keeps it
//
// While quiet, urgent (critical) notifications — alarms, a battery about
// to run out — still show unless that is switched off.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance

    readonly property var schedules: parse(prefs.focusSchedules, [])
    readonly property var rules: parse(prefs.notifRules, ({}))
    readonly property var apps: parse(prefs.notifApps, [])
    readonly property bool allowUrgent: prefs.focusUrgent

    property real now: Date.now()
    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    // The schedule running now, if any: { schedule, endsAt }.
    readonly property var current: {
        const t = new Date(now);
        for (const s of schedules) {
            if (!s.on) continue;
            const w = windowAround(s, t);
            if (w) return { schedule: s, endsAt: w.end };
        }
        return null;
    }
    // Bell pressed during a scheduled window: quiet stops until it ends.
    property real setAsideUntil: 0
    readonly property bool scheduled: current !== null && now >= setAsideUntil
    readonly property bool quiet: prefs.dnd || scheduled

    readonly property string reason: prefs.dnd ? "Do not disturb"
        : scheduled ? (current.schedule.name || "Focus") + " until " + hm(new Date(current.endsAt))
        : ""

    function parse(text, fallback) {
        try { const v = JSON.parse(text || ""); return v === null || v === undefined ? fallback : v; }
        catch (e) { return fallback; }
    }
    function minutes(hhmm) {
        const m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || ""));
        return m ? Math.min(23, +m[1]) * 60 + Math.min(59, +m[2]) : 0;
    }
    function hm(d) {
        return Qt.formatTime(d, Config.Appearance.clock24 ? "HH:mm" : "h:mm AP");
    }
    // The window of schedule s containing time t, as { start, end } in ms,
    // or null. Checked from yesterday's start too, for windows that cross
    // midnight.
    function windowAround(s, t) {
        const from = minutes(s.from), to = minutes(s.to);
        const len = ((to - from) + 1440) % 1440 || 1440;
        for (const back of [0, 1]) {
            const day = new Date(t.getFullYear(), t.getMonth(), t.getDate() - back);
            if (s.days && s.days.length > 0 && s.days.indexOf(day.getDay()) < 0) continue;
            const start = day.getTime() + from * 60000;
            const end = start + len * 60000;
            if (t.getTime() >= start && t.getTime() < end) return { start: start, end: end };
        }
        return null;
    }

    // The bell: off if anything has it quiet, else on.
    function toggle() {
        if (prefs.dnd) { prefs.dnd = false; return; }
        if (scheduled) { setAsideUntil = current.endsAt; return; }
        // On again during a set-aside schedule: the schedule resumes.
        if (current && now < setAsideUntil) { setAsideUntil = 0; return; }
        prefs.dnd = true;
    }

    // ── per app ──────────────────────────────────────────────────────────
    function rule(app) { return rules[app] || "normal"; }
    function setRule(app, r) {
        const next = Object.assign({}, rules);
        if (r === "normal") delete next[app]; else next[app] = r;
        prefs.notifRules = JSON.stringify(next);
    }
    // Every app that has sent something, so Settings can list them.
    function noteApp(app) {
        if (!app || apps.indexOf(app) >= 0) return;
        prefs.notifApps = JSON.stringify(apps.concat([app]).sort((a, b) => a.localeCompare(b)).slice(0, 200));
    }
    function forgetApp(app) {
        prefs.notifApps = JSON.stringify(apps.filter(a => a !== app));
        setRule(app, "normal");
    }

    // Whether a notification gets a banner.
    function banner(app, urgent) {
        const r = rule(app);
        if (r === "mute" || r === "silent") return false;
        if (r === "always") return true;
        if (!quiet) return true;
        return urgent && allowUrgent;
    }

    // ── schedules ────────────────────────────────────────────────────────
    function saveSchedules(list) { prefs.focusSchedules = JSON.stringify(list); }
    function addSchedule() {
        const id = schedules.reduce((m, s) => Math.max(m, s.id || 0), 0) + 1;
        saveSchedules(schedules.concat([{ id: id, name: "Night", from: "22:00", to: "07:00",
                                          days: [0, 1, 2, 3, 4, 5, 6], on: true }]));
    }
    function updateSchedule(id, change) {
        saveSchedules(schedules.map(s => s.id === id ? Object.assign({}, s, change) : s));
    }
    function removeSchedule(id) { saveSchedules(schedules.filter(s => s.id !== id)); }
}
