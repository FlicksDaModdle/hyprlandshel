// Checks services/WeProps.js against Wallpaper Engine's own formats.
//
//   node tools/weprops-test.js
//
// The library is QML's (".pragma library"), so it is loaded as text here
// with that line taken out.
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "../services/WeProps.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
const W = new Function(src + "\nreturn { label, parseProps, visible, toArg, shareJson, importValues,"
    + " readConfig, writeConfig, keyOf, colorString, normalise, monitorProps };")();

let n = 0;
function test(name, fn) { fn(); n++; console.log("ok  " + name); }

// A project.json in the shape Workshop wallpapers have — the properties
// linux-wallpaperengine's README lists for 2370927443, with conditions.
const project = {
    title: "Rain", type: "scene", file: "scene.json",
    general: { properties: {
        schemecolor: { order: 0, text: "ui_browse_properties_scheme_color", type: "color", value: "0.14902 0.23137 0.4" },
        rain: { order: 1, text: "Rain", type: "bool", value: true },
        owl: { order: 2, text: "Owl", type: "bool", value: false },
        visualizer: { order: 3, text: "<hr>Add Visualizer<hr>", type: "bool", value: true },
        barcount: { order: 4, text: "Bar Count", type: "slider", min: 16, max: 64, step: 1, value: 64,
                    condition: "visualizer.value" },
        visualizeropacity: { order: 5, text: "Bar Opacity", type: "slider", min: 0, max: 1,
                             fraction: true, precision: 1, value: 1, condition: "visualizer.value == true" },
        frequency: { order: 6, text: "Frequency", type: "combo", value: 2, condition: "visualizer.value",
                     options: [{ label: "16", value: 1 }, { label: "32", value: 2 }, { label: "64", value: 3 }] },
        clockheader: { order: 7, text: "<b>Clock</b>", type: "text" },
        spacer: { order: 8, text: "", type: "text" },
        clockstyle: { order: 9, text: "Style", type: "combo", value: "digital",
                      options: [{ label: "Digital", value: "digital" }, { label: "Analog", value: "analog" }] },
        clockfont: { order: 10, text: "Font", type: "textinput", value: "Inter",
                     condition: "clockstyle.value == 'digital' && !owl.value" },
        bgimage: { order: 11, text: "Background image", type: "file", value: null },
        editortex: { order: 12, text: "Texture", type: "scenetexture", value: "x.tex" }
    } }
};

const props = W.parseProps(project);
const byName = Object.fromEntries(props.map(p => [p.name, p]));
const defaults = Object.fromEntries(props.filter(p => !p.caption).map(p => [p.name, p.value]));

test("reads every settable type, in order, and leaves editor-only ones out", () => {
    assert.deepStrictEqual(props.map(p => p.name),
        ["schemecolor", "rain", "owl", "visualizer", "barcount", "visualizeropacity", "frequency",
         "clockheader", "clockstyle", "clockfont", "bgimage"]);
});

test("labels: localisation keys, HTML, captions", () => {
    assert.strictEqual(byName.schemecolor.label, "Scheme color");
    assert.strictEqual(byName.visualizer.label, "Add Visualizer");
    assert.strictEqual(byName.clockheader.label, "Clock");
    assert.strictEqual(byName.clockheader.caption, true);
    assert.strictEqual(W.label("", "backgroundColor"), "Background Color");
});

test("sliders: whole steps, and fractions to their precision", () => {
    assert.strictEqual(byName.barcount.step, 1);
    assert.strictEqual(byName.visualizeropacity.step, 0.1);
    assert.strictEqual(byName.visualizeropacity.max, 1);
});

test("combo values are strings, whatever the file had", () => {
    assert.strictEqual(byName.frequency.value, "2");
    assert.deepStrictEqual(byName.frequency.options.map(o => o.value), ["1", "2", "3"]);
});

test("conditions", () => {
    assert.strictEqual(W.visible(byName.barcount, defaults), true);
    assert.strictEqual(W.visible(byName.barcount, Object.assign({}, defaults, { visualizer: false })), false);
    assert.strictEqual(W.visible(byName.visualizeropacity, Object.assign({}, defaults, { visualizer: false })), false);
    assert.strictEqual(W.visible(byName.clockfont, defaults), true);
    assert.strictEqual(W.visible(byName.clockfont, Object.assign({}, defaults, { owl: true })), false);
    assert.strictEqual(W.visible(byName.clockfont, Object.assign({}, defaults, { clockstyle: "analog" })), false);
    const p = c => ({ condition: c });
    assert.strictEqual(W.visible(p("frequency.value == 2"), defaults), true);   // "2" == 2
    assert.strictEqual(W.visible(p("frequency.value > 2"), defaults), false);
    assert.strictEqual(W.visible(p("(owl.value || rain.value) && barcount.value >= 64"), defaults), true);
    // Not code: anything unreadable shows the property rather than hiding it.
    assert.strictEqual(W.visible(p("require('fs')"), defaults), true);
    assert.strictEqual(W.visible(p("nosuch.value"), defaults), true);
    assert.strictEqual(W.visible(p("a.value =="), defaults), true);
});

test("command-line values", () => {
    assert.strictEqual(W.toArg(byName.rain, false), "rain=0");
    assert.strictEqual(W.toArg(byName.schemecolor, "#ff8000"), "schemecolor=1 0.50196 0");
    assert.strictEqual(W.toArg(byName.visualizeropacity, 0.4), "visualizeropacity=0.4");
    assert.strictEqual(W.toArg(byName.frequency, "3"), "frequency=3");
});

test("Share JSON out: typed like Wallpaper Engine writes it", () => {
    const out = W.shareJson(props, defaults);
    assert.deepStrictEqual(out, {
        schemecolor: "0.14902 0.23137 0.4", rain: true, owl: false, visualizer: true,
        barcount: 64, visualizeropacity: 1, frequency: 2, clockstyle: "digital",
        clockfont: "Inter", bgimage: null
    });
});

test("Share JSON in: a real preset's shape, checked against the wallpaper", () => {
    const r = W.importValues(props, { rain: false, frequency: 3, schemecolor: "1 0 0",
        barcount: "32", nosuchthing: 5, clockstyle: "sundial", visualizeropacity: 0.25 });
    assert.deepStrictEqual(r.values, { rain: false, frequency: "3", schemecolor: "1 0 0",
        barcount: 32, visualizeropacity: 0.25 });
    assert.strictEqual(r.applied, 5);
    assert.strictEqual(r.skipped, 2);
});

test("in: a properties block, and a whole project.json", () => {
    assert.deepStrictEqual(W.importValues(props, { owl: { type: "bool", value: true } }).values, { owl: true });
    const again = W.importValues(props, project);
    assert.strictEqual(again.values.frequency, "2");
    assert.strictEqual(again.applied, 10);
});

// config.json as Wallpaper Engine writes it on Windows.
const config = {
    "?installdirectory": "C:\\Program Files (x86)\\Steam\\steamapps\\common\\wallpaper_engine",
    steamuser: {
        general: {
            browser: { resultsperpage: 50 },
            playlists: [{
                name: "Evenings",
                items: [
                    "D:/SteamLibrary/steamapps/workshop/content/431960/1845706469/project.json",
                    "D:\\SteamLibrary\\steamapps\\workshop\\content\\431960\\2667198601\\project.json",
                    "D:/SteamLibrary/steamapps/common/wallpaper_engine/projects/defaultprojects/techno/project.json"
                ],
                settings: { delay: 30, mode: "timer", order: "random", transition: true,
                            updateonpause: true, videosequence: false }
            }]
        },
        wallpaperconfig: { selectedwallpapers: {
            "\\\\?\\DISPLAY#GSM5B09#5&1d2&0&UID4353#{e6f07b5f}": {
                file: "D:/SteamLibrary/steamapps/workshop/content/431960/2667198601/project.json"
            }
        } },
        other: { kept: true }
    }
};

test("config.json in: playlists and the selected wallpaper, by what survives machines", () => {
    const r = W.readConfig(config);
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.playlists[0].name, "Evenings");
    assert.deepStrictEqual(r.playlists[0].keys, ["ws:1845706469", "ws:2667198601", "we:defaultprojects/techno"]);
    assert.strictEqual(r.playlists[0].settings.delay, 30);
    assert.strictEqual(r.selected[0].key, "ws:2667198601");
    assert.strictEqual(W.keyOf("/home/u/.local/share/Steam/steamapps/workshop/content/431960/2667198601"), "ws:2667198601");
});

test("config.json out: merged, other settings kept, paths for that machine's library", () => {
    const local = "/home/u/.local/share/Steam/steamapps/workshop/content/431960/";
    // Everything the file had is installed here too, and was taken out.
    const out = W.writeConfig(config, { name: "Evenings", dirs: [local + "111", local + "222"],
        localKeys: ["ws:1845706469", "ws:2667198601", "we:defaultprojects/techno", "ws:111", "ws:222"],
        delay: 15, order: "sequential", current: local + "111", rotate: true });
    const pl = out.steamuser.general.playlists;
    assert.strictEqual(pl.length, 1);
    assert.deepStrictEqual(pl[0].items, [
        "D:/SteamLibrary/steamapps/workshop/content/431960/111/project.json",
        "D:/SteamLibrary/steamapps/workshop/content/431960/222/project.json"]);
    assert.strictEqual(pl[0].settings.delay, 15);
    assert.strictEqual(pl[0].settings.updateonpause, true);           // theirs, kept
    assert.strictEqual(pl[0].settings.order, "sequential");
    const sel = out.steamuser.wallpaperconfig.selectedwallpapers;
    const mon = Object.keys(sel)[0];
    assert.ok(mon.indexOf("DISPLAY#GSM5B09") > 0);                    // their monitor, not a new one
    assert.strictEqual(sel[mon].file, "D:/SteamLibrary/steamapps/workshop/content/431960/111/project.json");
    assert.strictEqual(sel[mon].playlist.name, "Evenings");
    assert.deepStrictEqual(out.steamuser.other, { kept: true });
    assert.strictEqual(out.steamuser.general.browser.resultsperpage, 50);
    assert.strictEqual(config.steamuser.general.playlists[0].settings.delay, 30);  // input untouched
    // and it reads back as what was written
    const back = W.readConfig(out);
    assert.deepStrictEqual(back.playlists[0].keys, ["ws:111", "ws:222"]);
});

test("config.json out: wallpapers only the other machine has stay in its playlist", () => {
    const local = "/home/u/.local/share/Steam/steamapps/workshop/content/431960/";
    // Here: 1845706469 and techno are installed, the rest are not.
    const out = W.writeConfig(config, { name: "Evenings",
        dirs: [local + "555", local + "1845706469"],
        localKeys: ["ws:1845706469", "ws:555", "we:defaultprojects/techno"],
        delay: 30, order: "random", current: "", rotate: false });
    assert.deepStrictEqual(out.steamuser.general.playlists[0].items, [
        "D:/SteamLibrary/steamapps/workshop/content/431960/1845706469/project.json",  // theirs, still in
        "D:\\SteamLibrary\\steamapps\\workshop\\content\\431960\\2667198601\\project.json", // not here: kept as written
        "D:/SteamLibrary/steamapps/workshop/content/431960/555/project.json"]);      // new here
    // techno is installed here and was taken out here, so it goes.
});

test("config.json out: a new file, in current Wallpaper Engine's layout", () => {
    const out = W.writeConfig(null, { name: "Hyprshell", dirs: ["/x/431960/5", "/x/431960/6"],
        delay: 60, order: "random", current: "/x/431960/5", rotate: false });
    // general.playlists, which linux-wallpaperengine's --playlist reads too
    assert.strictEqual(out.steamuser.general.playlists[0].items[0],
        "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/5/project.json");
    assert.strictEqual(out.steamuser.general.wallpaperconfig.selectedwallpapers.Monitor0.playlist, undefined);
});

// Shaped like Wallpaper Engine 2.x's own file (config version 5): the
// account's name as the section, what is on screen under general, option
// values in wproperties by file and monitor, presets in general.wpresets.
const v5 = {
    "?installdirectory": "C:/Program Files (x86)/Steam/steamapps/common/wallpaper_engine",
    someone: {
        general: {
            browser: { resultsperpage: 100 },
            user: { fps: 25, playbackfocus: "run", playbackmaximized: "pause",
                    playbackfullscreen: "run", msaa: "x2" },
            wallpaperconfig: { profile: null, selectedwallpapers: {
                Monitor1: { file: "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/300/project.json" },
                Monitor0: { file: "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/100/scene.pkg" }
            } },
            wpresets: { "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/300/project.json": {
                presets: [{ name: "bluelines", properties: { first_color: "0 0.56 0.85", grid: true } },
                          { name: "bw", properties: { first_color: "1 1 1", grid: false } }] } }
        },
        version: 5,
        wproperties: {
            "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/200/Some Video 8K.mp4":
                { Monitor0: { volume: 0 } },
            "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/300/project.json": {
                Monitor0: { first_color: "1 1 1", flux: 3, grid: false },
                Monitor1: { first_color: "1 1 1" } }
        }
    }
};

test("config.json v5 in: screens, option values by file and monitor, presets, playback", () => {
    const r = W.readConfig(v5);
    assert.deepStrictEqual(r.selected.map(e => [e.monitor, e.key]), [["Monitor0", "ws:100"], ["Monitor1", "ws:300"]]);
    assert.deepStrictEqual(Object.keys(r.props).sort(), ["ws:200", "ws:300"]);   // an .mp4 and a project.json
    assert.deepStrictEqual(r.props["ws:200"].Monitor0, { volume: 0 });
    const mp = W.monitorProps(r.props["ws:300"]);
    assert.deepStrictEqual(mp.values, { first_color: "1 1 1", flux: 3, grid: false });
    assert.strictEqual(mp.differs, true);
    assert.deepStrictEqual(r.presets["ws:300"].map(p => p.name), ["bluelines", "bw"]);
    assert.deepStrictEqual(r.playback, { fps: 25, focus: "run", maximized: "pause", fullscreen: "run" });
    assert.strictEqual(W.keyOf("C:/x/steamapps/workshop/content/431960/3679305145/scene.pkg"), "ws:3679305145");
});

test("config.json v5 out: into the file's own places, keeping its paths and the rest", () => {
    const local = "/home/u/.local/share/Steam/steamapps/workshop/content/431960/";
    const out = W.writeConfig(v5, { name: "Hyprshell", dirs: [], delay: 30, order: "sequential",
        screens: [local + "100", local + "400"], rotate: false, monitors: 2,
        props: { [local + "300"]: { names: ["first_color", "flux", "grid", "scale"], values: { scale: 0.7 } },
                 [local + "400"]: { names: ["speed"], values: { speed: 2 } } },
        presets: { [local + "300"]: [{ name: "bw", properties: { first_color: "0.9 0.9 0.9" } },
                                     { name: "mine", properties: { grid: true } }] },
        playback: { fps: 60, maximized: "pause" } });
    const g = out.someone.general;
    assert.strictEqual(out.steamuser, undefined);                              // their account, not a new one
    const sel = g.wallpaperconfig.selectedwallpapers;
    assert.strictEqual(sel.Monitor0.file, "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/100/scene.pkg");
    assert.strictEqual(sel.Monitor1.file, "C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/400/project.json");
    const wp = out.someone.wproperties;
    const p300 = wp["C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/300/project.json"];
    assert.deepStrictEqual(p300.Monitor0, { scale: 0.7 });                     // reset ones gone
    assert.deepStrictEqual(p300.Monitor1, { scale: 0.7 });
    assert.deepStrictEqual(wp["C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/200/Some Video 8K.mp4"],
                           { Monitor0: { volume: 0 } });                        // untouched
    assert.deepStrictEqual(wp["C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/400/project.json"].Monitor0,
                           { speed: 2 });
    const pr = g.wpresets["C:/Program Files (x86)/Steam/steamapps/workshop/content/431960/300/project.json"].presets;
    assert.deepStrictEqual(pr.map(p => p.name), ["bluelines", "bw", "mine"]);
    assert.strictEqual(pr[1].properties.first_color, "0.9 0.9 0.9");
    assert.strictEqual(g.user.fps, 60);
    assert.strictEqual(g.user.msaa, "x2");                                     // theirs, kept
    assert.strictEqual(g.browser.resultsperpage, 100);
    const back = W.readConfig(out);
    assert.deepStrictEqual(back.selected.map(e => e.key), ["ws:100", "ws:400"]);
});

console.log(n + " passed");
