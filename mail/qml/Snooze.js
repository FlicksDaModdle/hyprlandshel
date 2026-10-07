.pragma library

// When "later" is: the choices offered for snoozing and for sending later,
// each { n, at } with `at` in milliseconds.
function choices(now) {
    var d = new Date(now);
    var out = [];
    var later = new Date(d.getTime() + 3 * 3600 * 1000);
    later.setMinutes(0, 0, 0);
    if (later.getHours() < 21 && later.getDate() === d.getDate())
        out.push({ n: "Later today", at: later.getTime() });
    var tmr = new Date(d); tmr.setDate(d.getDate() + 1); tmr.setHours(8, 0, 0, 0);
    out.push({ n: "Tomorrow morning", at: tmr.getTime() });
    var tmrA = new Date(tmr); tmrA.setHours(13, 0, 0, 0);
    out.push({ n: "Tomorrow afternoon", at: tmrA.getTime() });
    var day = d.getDay(); // 0 Sunday
    if (day >= 1 && day <= 4) {
        var sat = new Date(d); sat.setDate(d.getDate() + (6 - day)); sat.setHours(9, 0, 0, 0);
        out.push({ n: "This weekend", at: sat.getTime() });
    }
    var mon = new Date(d); mon.setDate(d.getDate() + ((8 - day) % 7 || 7)); mon.setHours(8, 0, 0, 0);
    out.push({ n: "Next week", at: mon.getTime() });
    return out;
}

// "2026-10-07 14:30" (or with T) → ms; NaN when it is not a time.
function parse(text) {
    var m = /^\s*(\d{4})-(\d{1,2})-(\d{1,2})[ T]+(\d{1,2}):(\d{2})\s*$/.exec(text || "");
    if (!m) return NaN;
    return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]).getTime();
}
