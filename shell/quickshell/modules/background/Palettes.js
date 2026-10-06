.pragma library

// Colour sets for the animated wallpapers: two for the ground (bg1 the top
// or low end, bg2 the bottom or high end) and three for what moves on it.
// "theme" and "custom" are worked out in AnimatedWallpaper.qml.

var presets = [
    { key: "aurora",  name: "Aurora",  bg1: "#040c18", bg2: "#0b2536", c1: "#3cffb4", c2: "#3fa7ff", c3: "#b46cff" },
    { key: "sunset",  name: "Sunset",  bg1: "#160a2b", bg2: "#5b1f4f", c1: "#ff7a59", c2: "#ffb347", c3: "#ff3d7f" },
    { key: "ocean",   name: "Ocean",   bg1: "#021526", bg2: "#063b5b", c1: "#2ec4ff", c2: "#57f0d4", c3: "#1b6dff" },
    { key: "forest",  name: "Forest",  bg1: "#0b1a12", bg2: "#1e3a2a", c1: "#8ad86b", c2: "#e8d36b", c3: "#3fbf9b" },
    { key: "neon",    name: "Neon",    bg1: "#0a0014", bg2: "#1b0033", c1: "#ff2bd6", c2: "#00f0ff", c3: "#fff200" },
    { key: "ember",   name: "Ember",   bg1: "#120604", bg2: "#2b0f08", c1: "#ff5a1f", c2: "#ffb000", c3: "#ff2a2a" },
    { key: "rose",    name: "Rosé",    bg1: "#1d1016", bg2: "#3a1d2a", c1: "#ff9ec4", c2: "#ffd1dc", c3: "#c27dff" },
    { key: "mono",    name: "Mono",    bg1: "#0f1011", bg2: "#1d1f21", c1: "#e8e8e8", c2: "#9a9a9a", c3: "#5f5f5f" },
    { key: "paper",   name: "Paper",   bg1: "#f4efe6", bg2: "#e3d8c5", c1: "#b04a2f", c2: "#2f6f8f", c3: "#3a3a3a" },
    { key: "mint",    name: "Mint",    bg1: "#eef7f2", bg2: "#cfe8dc", c1: "#16a37a", c2: "#3f7fd9", c3: "#0f5c45" }
];

function find(key) {
    for (var i = 0; i < presets.length; i++) if (presets[i].key === key) return presets[i];
    return null;
}

// The styles, in the order the gallery shows them, with what their two
// style-specific sliders mean.
var styles = [
    { key: "topo",   name: "Topographic", density: "",           glow: "" },
    { key: "aurora", name: "Aurora",      density: "Curtains",   glow: "Height" },
    { key: "blobs",  name: "Blobs",       density: "Pools",      glow: "Softness" },
    { key: "waves",  name: "Waves",       density: "Lines",      glow: "Glow" },
    { key: "stars",  name: "Starfield",   density: "Stars",      glow: "Nebula" },
    { key: "synth",  name: "Synthwave",   density: "Grid",       glow: "Haze" },
    { key: "cells",  name: "Cells",       density: "Cells",      glow: "Glow" }
];

function style(key) {
    for (var i = 0; i < styles.length; i++) if (styles[i].key === key) return styles[i];
    return null;
}
