.pragma library

// Wallpaper Engine's own formats, read and written without Wallpaper Engine.
//
//   parseProps      a wallpaper's user properties, from its project.json
//   visible         whether a property's "condition" holds
//   toArg           a value as linux-wallpaperengine's --set-property takes it
//   shareJson       Wallpaper Engine's "Share JSON": { name: value, … }
//   importValues    Share JSON, a properties block, or a whole project.json
//   readConfig      playlists and chosen wallpapers from its config.json
//   writeConfig     the same, merged into a config.json
//
// Plain functions over plain data, so they can be run outside QML — see
// tools/weprops-test.js.

// ── properties ─────────────────────────────────────────────────────────────

// The types a person sets. "text" is a caption with nothing to set, and
// "group" a heading; both are kept so the list reads as it does in
// Wallpaper Engine. "scenetexture" and "usershortcut" are left out:
// Wallpaper Engine's editor sets those, not the person using the wallpaper.
const SETTABLE = ["bool", "slider", "color", "combo", "textinput", "file", "directory"];

// Labels are HTML in places ("<hr>Add Visualizer<hr>", "<b>Clock</b>") and
// localisation keys in others ("ui_browse_properties_scheme_color", which
// Wallpaper Engine turns into "Scheme color" from its own table).
function label(text, name) {
    let t = String(text === undefined || text === null ? "" : text)
        .replace(/<br\s*\/?>/gi, " ")
        .replace(/<[^>]*>/g, "")
        .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
        .replace(/\s+/g, " ").trim();
    if (/^ui_[a-z0-9_]+$/i.test(t))
        t = t.replace(/^ui_browse_properties_/i, "").replace(/^ui_/i, "").replace(/_/g, " ");
    if (t === "") t = String(name || "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ");
    return t.charAt(0).toUpperCase() + t.slice(1);
}

function num(v, fallback) {
    const n = typeof v === "number" ? v : parseFloat(v);
    return isFinite(n) ? n : fallback;
}

// project.json → [{ name, type, label, value, min, max, step, options,
// condition }], in the order Wallpaper Engine shows them: by "order", then
// as written.
function parseProps(project) {
    const props = project && project.general && project.general.properties;
    if (!props || typeof props !== "object") return [];
    const out = [];
    let i = 0;
    for (const name in props) {
        const d = props[name];
        i++;
        if (!d || typeof d !== "object") continue;
        const type = String(d.type || "").toLowerCase();
        const p = {
            name: name,
            type: type,
            label: label(d.text, name),
            condition: typeof d.condition === "string" ? d.condition : "",
            order: num(d.order, 1e6 + i),
            index: i
        };
        if (type === "text" || type === "group") {
            // A caption with no words is Wallpaper Engine's spacer.
            if (label(d.text, "") === "") continue;
            p.caption = true;
        } else if (SETTABLE.indexOf(type) < 0) {
            continue;
        }
        if (type === "bool") p.value = asBool(d.value);
        else if (type === "slider") {
            p.min = num(d.min, 0);
            p.max = num(d.max, 100);
            if (p.max <= p.min) p.max = p.min + 1;
            // "step" when given; otherwise whole numbers, unless "fraction"
            // says otherwise, to "precision" places (2 by default).
            const places = d.precision !== undefined ? Math.max(0, Math.min(6, num(d.precision, 2))) : 2;
            p.step = num(d.step, 0) > 0 ? num(d.step, 1)
                   : (d.fraction ? Math.pow(10, -places) : 1);
            p.value = num(d.value, p.min);
        } else if (type === "color") p.value = colorString(d.value);
        else if (type === "combo") {
            p.options = (Array.isArray(d.options) ? d.options : [])
                .filter(o => o && typeof o === "object" && o.value !== undefined)
                .map(o => ({ label: label(o.label, String(o.value)), value: String(o.value),
                             numeric: typeof o.value === "number" }));
            if (p.options.length === 0) continue;
            p.value = d.value === undefined || d.value === null ? p.options[0].value : String(d.value);
        } else if (type === "textinput" || type === "file" || type === "directory") {
            p.value = d.value === undefined || d.value === null ? "" : String(d.value);
        }
        out.push(p);
    }
    out.sort((a, b) => a.order - b.order || a.index - b.index);
    return out;
}

function asBool(v) {
    return v === true || v === 1 || v === "1" || v === "true";
}

// Colours are "r g b" in 0–1, as project.json writes them; "#rrggbb", commas,
// arrays and 0–255 are read as well, since hand-written presets use them.
function colorParts(v) {
    let parts;
    if (Array.isArray(v)) parts = v.map(Number);
    else if (v && typeof v === "object") parts = [v.r, v.g, v.b].map(Number);
    else {
        const s = String(v === undefined || v === null ? "" : v).trim();
        const hex = /^#?([0-9a-f]{6})$/i.exec(s) || /^#([0-9a-f]{3})$/i.exec(s);
        if (hex) {
            let h = hex[1];
            if (h.length === 3) h = h.split("").map(c => c + c).join("");
            parts = [0, 2, 4].map(k => parseInt(h.substr(k, 2), 16) / 255);
        } else parts = s.split(/[\s,]+/).filter(x => x !== "").map(Number);
    }
    parts = parts.slice(0, 3);
    while (parts.length < 3) parts.push(0);
    if (parts.some(x => !isFinite(x))) return [0, 0, 0];
    if (parts.some(x => x > 1)) parts = parts.map(x => x / 255);
    return parts.map(x => Math.max(0, Math.min(1, x)));
}

function colorString(v) {
    return colorParts(v).map(x => String(Math.round(x * 100000) / 100000)).join(" ");
}

// A value as it is stored and passed on: booleans as true/false, numbers as
// numbers, everything else as the string Wallpaper Engine writes.
function normalise(p, raw) {
    switch (p.type) {
    case "bool": return asBool(raw);
    case "slider": {
        const n = num(raw, NaN);
        return isFinite(n) ? n : undefined;
    }
    case "color": return raw === undefined || raw === null ? undefined : colorString(raw);
    case "combo": {
        const s = String(raw);
        return p.options.some(o => o.value === s) ? s : undefined;
    }
    default: return raw === null || raw === undefined ? "" : String(raw);
    }
}

function same(p, a, b) {
    if (p.type === "slider") return Math.abs(num(a, 0) - num(b, 0)) < 1e-9;
    return String(a) === String(b);
}

// --set-property name=value. Booleans as 1/0, which is what its boolean
// property reads as true and false.
function toArg(p, v) {
    if (p.type === "bool") return p.name + "=" + (asBool(v) ? "1" : "0");
    if (p.type === "color") return p.name + "=" + colorString(v);
    return p.name + "=" + String(v);
}

// ── conditions ─────────────────────────────────────────────────────────────
// Wallpaper Engine hides a property while its "condition" is false:
// "visualizer.value", "!clock.value", "background_type.value == 2",
// "a.value && (b.value == 'x' || c.value > 3)". This reads that much —
// comparisons, !, &&, ||, brackets — and nothing else: a condition is text
// from a Workshop download, and is never run as code. One it cannot read
// counts as true, so a property is shown rather than lost.

function tokens(s) {
    const out = [];
    let i = 0;
    while (i < s.length) {
        const c = s[i];
        if (/\s/.test(c)) { i++; continue; }
        const two = s.substr(i, 3) === "===" || s.substr(i, 3) === "!==" ? s.substr(i, 3) : s.substr(i, 2);
        if (["===", "!==", "==", "!=", "<=", ">=", "&&", "||"].indexOf(two) >= 0) {
            out.push({ t: "op", v: two.length === 3 ? two.slice(0, 2) : two });
            i += two.length;
        } else if ("()!<>".indexOf(c) >= 0) { out.push({ t: "op", v: c }); i++; }
        else if (c === "'" || c === '"') {
            const j = s.indexOf(c, i + 1);
            if (j < 0) throw new Error("unterminated string");
            out.push({ t: "lit", v: s.slice(i + 1, j) });
            i = j + 1;
        } else {
            const m = /^[A-Za-z0-9_.$-]+/.exec(s.slice(i));
            if (!m) throw new Error("unexpected " + c);
            const w = m[0];
            if (w === "true" || w === "false") out.push({ t: "lit", v: w === "true" });
            else if (/^-?\d+(\.\d+)?$/.test(w)) out.push({ t: "lit", v: parseFloat(w) });
            else out.push({ t: "id", v: w });
            i += w.length;
        }
    }
    return out;
}

function evaluate(expr, values) {
    const ts = tokens(expr);
    let k = 0;
    const peek = () => ts[k];
    const take = v => { const t = ts[k]; if (!t || (v !== undefined && t.v !== v)) throw new Error("expected " + v); k++; return t; };
    function lookup(id) {
        const parts = id.split(".");
        const name = parts[0];
        if (!(name in values)) throw new Error("unknown " + name);
        return values[name];
    }
    function primary() {
        const t = peek();
        if (!t) throw new Error("end");
        if (t.t === "op" && t.v === "(") { k++; const v = or(); take(")"); return v; }
        if (t.t === "op" && t.v === "!") { k++; return !truthy(primary()); }
        if (t.t === "lit") { k++; return t.v; }
        if (t.t === "id") { k++; return lookup(t.v); }
        throw new Error("unexpected " + t.v);
    }
    function cmp() {
        const a = primary();
        const t = peek();
        if (t && t.t === "op" && ["==", "!=", "<", ">", "<=", ">="].indexOf(t.v) >= 0) {
            k++;
            return compare(a, t.v, primary());
        }
        return a;
    }
    function and() { let v = cmp(); while (peek() && peek().v === "&&") { k++; const r = cmp(); v = truthy(v) && truthy(r); } return v; }
    function or() { let v = and(); while (peek() && peek().v === "||") { k++; const r = and(); v = truthy(v) || truthy(r); } return v; }
    const v = or();
    if (k !== ts.length) throw new Error("trailing");
    return truthy(v);
}

function numeric(v) {
    return typeof v === "number" || (typeof v === "string" && /^\s*-?\d+(\.\d+)?\s*$/.test(v));
}

function truthy(v) {
    if (typeof v === "string") return v !== "" && v !== "0" && v !== "false";
    return !!v;
}

function compare(a, op, b) {
    let x = a, y = b;
    if (typeof x === "boolean" || typeof y === "boolean") { x = truthy(x); y = truthy(y); }
    else if (numeric(x) && numeric(y)) { x = parseFloat(x); y = parseFloat(y); }
    else { x = String(x); y = String(y); }
    switch (op) {
    case "==": return x === y;
    case "!=": return x !== y;
    case "<": return x < y;
    case ">": return x > y;
    case "<=": return x <= y;
    case ">=": return x >= y;
    }
    return true;
}

function visible(p, values) {
    if (!p.condition) return true;
    try { return evaluate(p.condition, values); } catch (e) { return true; }
}

// ── Share JSON ─────────────────────────────────────────────────────────────
// What Wallpaper Engine's "Share JSON" gives and takes: one flat object of
// every settable property, with the value in the type the property has —
// true/false, a number, "r g b", a combo's value as a number when its
// options are numbers.
function shareJson(props, values) {
    const out = {};
    for (const p of props) {
        if (p.caption) continue;
        const v = values[p.name];
        if (p.type === "combo") {
            const o = p.options.find(x => x.value === String(v));
            out[p.name] = o && o.numeric ? parseFloat(o.value) : String(v);
        } else if (p.type === "color") out[p.name] = colorString(v);
        else if ((p.type === "file" || p.type === "directory") && v === "") out[p.name] = null;
        else out[p.name] = v;
    }
    return out;
}

// Share JSON ({ name: value }), a properties block ({ name: { value } }),
// or a whole project.json. Values are checked against the wallpaper's own
// properties: names it does not have and values it would not take are
// left out, and counted.
function importValues(props, data) {
    let src = data;
    if (src && src.general && src.general.properties) src = src.general.properties;
    const values = {};
    let applied = 0, skipped = 0;
    if (!src || typeof src !== "object" || Array.isArray(src)) return { values, applied, skipped: 0, ok: false };
    for (const key in src) {
        const p = props.find(x => x.name === key && !x.caption);
        if (!p) { skipped++; continue; }
        let raw = src[key];
        if (raw && typeof raw === "object" && !Array.isArray(raw) && "value" in raw) raw = raw.value;
        const v = normalise(p, raw);
        if (v === undefined) { skipped++; continue; }
        values[key] = v;
        applied++;
    }
    return { values, applied, skipped, ok: true };
}

// ── config.json ────────────────────────────────────────────────────────────
// Wallpaper Engine keeps playlists in steamuser.general.playlists and what
// each monitor shows in steamuser.wallpaperconfig.selectedwallpapers, each
// { file, playlist? } — the same shape linux-wallpaperengine's --playlist
// reads. Paths there are Windows paths to project.json files; a wallpaper is
// matched by what does not change between machines: its Workshop id, or
// which of Wallpaper Engine's project folders it is in and its name.

// Any file in a wallpaper's folder names it: Wallpaper Engine writes the
// project.json, the scene.pkg or the video, depending on how it was opened.
function keyOf(path) {
    const s = String(path || "").replace(/\\/g, "/").replace(/\/+$/, "");
    let m = /\/431960\/([^/]+)(\/|$)/.exec(s);
    if (m) return "ws:" + m[1];
    m = /\/projects\/(defaultprojects|myprojects)\/([^/]+)(\/|$)/i.exec(s);
    if (m) return "we:" + m[1].toLowerCase() + "/" + m[2];
    return "path:" + s.replace(/\/project\.json$/i, "");
}

// Monitor0, Monitor1, … in order, and anything else after them.
function monitorOrder(keys) {
    const n = k => { const m = /^Monitor(\d+)$/.exec(k); return m ? parseInt(m[1]) : 1e6; };
    return keys.slice().sort((a, b) => n(a) - n(b));
}

// → { selected: [{ monitor, key, playlist }], playlists: [{ name, keys,
//     settings }], props: { key: { monitor: { name: value } } },
//     presets: { key: [{ name, properties }] }, playback: { … } }
//
// Where things are, as Wallpaper Engine 2.x writes them (config version 5):
// everything under the account's name; the options changed on each
// wallpaper in <account>.wproperties, by the wallpaper's file and then by
// monitor, only the ones changed and its volume; named presets in
// <account>.general.wpresets; what each monitor shows in
// <account>.general.wallpaperconfig — older files have that at
// <account>.wallpaperconfig, where linux-wallpaperengine reads it.
function readConfig(cfg) {
    const user = cfg && (cfg.steamuser || firstUser(cfg));
    const res = { selected: [], playlists: [], ok: !!user };
    if (!user) return res;
    const pl = p => ({
        name: String(p.name || ""),
        keys: (Array.isArray(p.items) ? p.items : []).filter(x => typeof x === "string").map(keyOf),
        settings: p.settings && typeof p.settings === "object" ? p.settings : {}
    });
    const general = user.general || {};
    for (const p of Array.isArray(general.playlists) ? general.playlists : [])
        if (p && typeof p === "object") res.playlists.push(pl(p));
    const sel = user.wallpaperconfig && user.wallpaperconfig.selectedwallpapers
        || general.wallpaperconfig && general.wallpaperconfig.selectedwallpapers || {};
    for (const monitor of monitorOrder(Object.keys(sel))) {
        const e = sel[monitor];
        if (!e || typeof e !== "object") continue;
        res.selected.push({ monitor: monitor, key: e.file ? keyOf(e.file) : "",
                            playlist: e.playlist && typeof e.playlist === "object" ? pl(e.playlist) : null });
    }

    res.props = {};
    const wp = user.wproperties && typeof user.wproperties === "object" ? user.wproperties : {};
    for (const path in wp) {
        const byMonitor = wp[path];
        if (!byMonitor || typeof byMonitor !== "object") continue;
        const k = keyOf(path);
        res.props[k] = Object.assign(res.props[k] || {}, byMonitor);
    }

    res.presets = {};
    const pr = general.wpresets && typeof general.wpresets === "object" ? general.wpresets : {};
    for (const path in pr) {
        const list = pr[path] && Array.isArray(pr[path].presets) ? pr[path].presets : [];
        const k = keyOf(path);
        res.presets[k] = (res.presets[k] || []).concat(list
            .filter(x => x && typeof x.name === "string" && x.properties && typeof x.properties === "object")
            .map(x => ({ name: x.name, properties: x.properties })));
    }

    const u = general.user && typeof general.user === "object" ? general.user : null;
    res.playback = u ? {
        fps: typeof u.fps === "number" ? u.fps : 0,
        focus: String(u.playbackfocus || ""),
        maximized: String(u.playbackmaximized || ""),
        fullscreen: String(u.playbackfullscreen || ""),
        battery: String(u.playbackonbattery || "")
    } : null;

    // Names, for saying which wallpaper could not be brought over: the
    // file does not keep a wallpaper's title beside it, but its list of
    // recent choices does, for each one chosen alone.
    res.titles = {};
    const recent = general.wallpaperconfigrecent || user.wallpaperconfigrecent;
    for (const r of Array.isArray(recent) ? recent : []) {
        const sw = r && r.config && r.config.selectedwallpapers;
        if (!sw || typeof r.title !== "string") continue;
        const ks = Object.keys(sw).map(m => sw[m] && sw[m].file ? keyOf(sw[m].file) : "").filter(k => k);
        const distinct = ks.filter((k, i) => ks.indexOf(k) === i);
        if (distinct.length !== 1 || res.titles[distinct[0]]) continue;
        // On n monitors the title is the name n times, joined by ", " —
        // and a name can have a comma of its own, so it is not split there.
        const n = ks.length;
        const len = (r.title.length - 2 * (n - 1)) / n;
        const one = Number.isInteger(len) ? r.title.slice(0, len) : "";
        res.titles[distinct[0]] = one && Array(n).fill(one).join(", ") === r.title ? one : r.title;
    }
    return res;
}

// The options changed on one monitor, from readConfig's props: the first
// monitor there is, in order. `differs` says whether another had others.
function monitorProps(byMonitor) {
    const keys = monitorOrder(Object.keys(byMonitor || {}));
    if (keys.length === 0) return { values: {}, differs: false };
    const first = byMonitor[keys[0]] || {};
    const differs = keys.slice(1).some(k => JSON.stringify(byMonitor[k]) !== JSON.stringify(first));
    return { values: first, differs: differs };
}

// Older files keep everything under the Steam account's name rather than
// "steamuser"; the section is the one with "general" in it.
function firstUser(cfg) {
    for (const k in cfg)
        if (cfg[k] && typeof cfg[k] === "object" && cfg[k].general) return cfg[k];
    return null;
}

// Where Steam is on the machine the file is for, taken from a path already
// in it, so exported items point at that machine's library. A path to a
// wallpaper is the one that says where wallpapers are kept; Wallpaper
// Engine's own install folder ("?installdirectory") can be on another drive.
function steamPrefix(cfg) {
    let item = "", any = "";
    (function walk(v) {
        if (item) return;
        if (typeof v === "string") {
            const s = v.replace(/\\/g, "/");
            const i = s.toLowerCase().indexOf("/steamapps/");
            if (i <= 0) return;
            if (/\/(431960|projects)\//i.test(s)) item = s.slice(0, i);
            else if (!any) any = s.slice(0, i);
        } else if (v && typeof v === "object") for (const k in v) walk(v[k]);
    })(cfg);
    return item || any || "C:/Program Files (x86)/Steam";
}

function pathFor(prefix, key, localDir) {
    if (key.indexOf("ws:") === 0)
        return prefix + "/steamapps/workshop/content/431960/" + key.slice(3) + "/project.json";
    if (key.indexOf("we:") === 0)
        return prefix + "/steamapps/common/wallpaper_engine/projects/" + key.slice(3) + "/project.json";
    return localDir + "/project.json";
}

// Merges into `existing` (a parsed config.json, or null for a new file):
// the playlist, by name, in general.playlists; and the first monitor's
// entry in wallpaperconfig.selectedwallpapers — its file, and the playlist
// when it rotates. Everything else in the file is kept as it was.
function writeConfig(existing, opts) {
    const cfg = existing && typeof existing === "object" ? JSON.parse(JSON.stringify(existing)) : {};
    const userKey = cfg.steamuser ? "steamuser"
        : (Object.keys(cfg).find(k => cfg[k] && typeof cfg[k] === "object" && cfg[k].general) || "steamuser");
    const user = cfg[userKey] = cfg[userKey] || {};
    const general = user.general = user.general || {};
    const prefix = steamPrefix(existing || {});
    const lists = Array.isArray(general.playlists) ? general.playlists : [];
    const old = lists.find(p => p && p.name === opts.name) || {};
    // Its items, merged with the playlist of that name already there: what
    // this machine has is as the playlist here says, in the order the file
    // had it; what this machine does not have (`localKeys` are the ones it
    // does) is left in, as it was written. Taking a playlist there and
    // back does not lose the wallpapers only the other machine has.
    const ours = opts.dirs.map(keyOf);
    const local = opts.localKeys || [];
    const merged = [];
    const has = k => merged.some(m => m.key === k);
    for (const it of Array.isArray(old.items) ? old.items : []) {
        if (typeof it !== "string") continue;
        const k = keyOf(it);
        if (has(k)) continue;
        if (ours.indexOf(k) >= 0 || local.indexOf(k) < 0) merged.push({ key: k, path: it });
    }
    ours.forEach((k, i) => { if (!has(k)) merged.push({ key: k, path: pathFor(prefix, k, opts.dirs[i]) }); });
    const items = merged.map(m => m.path);
    const playlist = {
        items: items,
        name: opts.name,
        settings: Object.assign({ transition: true, updateonpause: false, videosequence: false },
                                old.settings || {},
                                { delay: opts.delay, mode: "timer", order: opts.order })
    };
    if (items.length > 0) {
        const at = lists.indexOf(old);
        if (at >= 0) lists[at] = playlist; else lists.push(playlist);
        general.playlists = lists;
    }
    // What each monitor shows, where this file keeps it: general's in
    // current files, the account's in older ones.
    const screens = opts.screens && opts.screens.length ? opts.screens : (opts.current ? [opts.current] : []);
    if (screens.length > 0) {
        const wc = user.wallpaperconfig && user.wallpaperconfig.selectedwallpapers
            ? user.wallpaperconfig
            : (general.wallpaperconfig = general.wallpaperconfig || {});
        const sel = wc.selectedwallpapers = wc.selectedwallpapers || {};
        const names = monitorOrder(Object.keys(sel));
        screens.forEach((dir, i) => {
            if (!dir) return;
            const monitor = names[i] || ("Monitor" + i);
            const entry = Object.assign({}, sel[monitor] || {});
            // The file it already names, when that is this wallpaper — it
            // may be the scene.pkg or the video rather than project.json.
            if (!entry.file || keyOf(entry.file) !== keyOf(dir))
                entry.file = pathFor(prefix, keyOf(dir), dir);
            if (i === 0 && opts.rotate && items.length > 1) entry.playlist = playlist;
            else delete entry.playlist;
            sel[monitor] = entry;
        });
    }

    // A path already in this section for the same wallpaper, or a new one.
    function pathIn(section, dir) {
        const k = keyOf(dir);
        for (const p in section) if (keyOf(p) === k) return p;
        return pathFor(prefix, k, dir);
    }

    // The options changed, per wallpaper, on each monitor. Options the
    // wallpaper has that are not changed any more are taken out; anything
    // else there (its volume, say) stays.
    if (opts.props) {
        const wp = user.wproperties = user.wproperties || {};
        const count = Math.max(1, opts.monitors || 1);
        for (const dir in opts.props) {
            const e = opts.props[dir];
            const path = pathIn(wp, dir);
            const byMonitor = wp[path] = Object.assign({}, wp[path] || {});
            for (let i = 0; i < count; i++) {
                const m = "Monitor" + i;
                const next = Object.assign({}, byMonitor[m] || {});
                for (const name of e.names || []) delete next[name];
                Object.assign(next, e.values || {});
                if (Object.keys(next).length > 0) byMonitor[m] = next; else delete byMonitor[m];
            }
            if (Object.keys(byMonitor).length === 0) delete wp[path];
        }
    }

    // Named presets, by name: one of the same name is replaced, the rest
    // are kept.
    if (opts.presets) {
        const pr = general.wpresets = general.wpresets || {};
        for (const dir in opts.presets) {
            const path = pathIn(pr, dir);
            const had = pr[path] && Array.isArray(pr[path].presets) ? pr[path].presets : [];
            const ours = opts.presets[dir];
            const kept = had.filter(x => !ours.some(o => o.name === (x && x.name)));
            pr[path] = Object.assign({}, pr[path] || {}, { presets: kept.concat(ours) });
        }
    }

    if (opts.playback) {
        const u = general.user = general.user || {};
        if (opts.playback.fps > 0) u.fps = opts.playback.fps;
        for (const k of ["focus", "maximized", "fullscreen", "onbattery"])
            if (opts.playback[k]) u["playback" + k] = opts.playback[k];
    }
    return cfg;
}
