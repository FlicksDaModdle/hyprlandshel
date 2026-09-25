.pragma library

// The keyboard's layout, and the names the rest of the world calls its
// keys.
//
// A key on screen is three things at once: something to draw, a
// character to send, and — when it is not a character — an X keysym
// name. Those are not the same string. The comma key draws ",", sends
// "," and is called "comma"; shifted it draws "<", sends "<" and is
// called "less". Getting that table wrong is a key that types nothing,
// silently, which is why it is here as data rather than spread through
// the QML as special cases.
//
// A key is:
//
//   { c, s, w }        a character key: unshifted, shifted, width units
//   { k, label, w }    a named key: the keysym, what to draw
//   { mod, label, w }  a modifier: shift | ctrl | alt | super | caps
//
// Widths are in units of one standard key, so a row is laid out by
// summing them rather than by measuring text.

var ROWS = [
    [
        { c: "`", s: "~" }, { c: "1", s: "!" }, { c: "2", s: "@" },
        { c: "3", s: "#" }, { c: "4", s: "$" }, { c: "5", s: "%" },
        { c: "6", s: "^" }, { c: "7", s: "&" }, { c: "8", s: "*" },
        { c: "9", s: "(" }, { c: "0", s: ")" }, { c: "-", s: "_" },
        { c: "=", s: "+" },
        { k: "BackSpace", label: "⌫", w: 2 }
    ],
    [
        { k: "Tab", label: "tab", w: 1.5 },
        { c: "q", s: "Q" }, { c: "w", s: "W" }, { c: "e", s: "E" },
        { c: "r", s: "R" }, { c: "t", s: "T" }, { c: "y", s: "Y" },
        { c: "u", s: "U" }, { c: "i", s: "I" }, { c: "o", s: "O" },
        { c: "p", s: "P" }, { c: "[", s: "{" }, { c: "]", s: "}" },
        { c: "\\", s: "|", w: 1.5 }
    ],
    [
        { mod: "caps", label: "caps", w: 1.75 },
        { c: "a", s: "A" }, { c: "s", s: "S" }, { c: "d", s: "D" },
        { c: "f", s: "F" }, { c: "g", s: "G" }, { c: "h", s: "H" },
        { c: "j", s: "J" }, { c: "k", s: "K" }, { c: "l", s: "L" },
        { c: ";", s: ":" }, { c: "'", s: "\"" },
        { k: "Return", label: "⏎", w: 2.25 }
    ],
    [
        { mod: "shift", label: "shift", w: 2.25 },
        { c: "z", s: "Z" }, { c: "x", s: "X" }, { c: "c", s: "C" },
        { c: "v", s: "V" }, { c: "b", s: "B" }, { c: "n", s: "N" },
        { c: "m", s: "M" }, { c: ",", s: "<" }, { c: ".", s: ">" },
        { c: "/", s: "?" },
        { mod: "shift", label: "shift", w: 2.75 }
    ],
    [
        { mod: "ctrl", label: "ctrl", w: 1.25 },
        { mod: "super", label: "super", w: 1.25 },
        { mod: "alt", label: "alt", w: 1.25 },
        { c: " ", s: " ", label: "space", w: 6 },
        { k: "Escape", label: "esc", w: 1.25 },
        { k: "Left", label: "←" }, { k: "Down", label: "↓" },
        { k: "Up", label: "↑" }, { k: "Right", label: "→" }
    ]
];

// Characters that are not their own keysym name.
//
// A letter or a digit is called what it looks like; everything else has
// a name, and the shifted forms have names of their own rather than
// being "shift plus the unshifted one".
var KEYSYMS = {
    " ": "space",
    "`": "grave",        "~": "asciitilde",
    "1": "1",            "!": "exclam",
    "2": "2",            "@": "at",
    "3": "3",            "#": "numbersign",
    "4": "4",            "$": "dollar",
    "5": "5",            "%": "percent",
    "6": "6",            "^": "asciicircum",
    "7": "7",            "&": "ampersand",
    "8": "8",            "*": "asterisk",
    "9": "9",            "(": "parenleft",
    "0": "0",            ")": "parenright",
    "-": "minus",        "_": "underscore",
    "=": "equal",        "+": "plus",
    "[": "bracketleft",  "{": "braceleft",
    "]": "bracketright", "}": "braceright",
    "\\": "backslash",   "|": "bar",
    ";": "semicolon",    ":": "colon",
    "'": "apostrophe",   "\"": "quotedbl",
    ",": "comma",        "<": "less",
    ".": "period",       ">": "greater",
    "/": "slash",        "?": "question"
};

// The keysym for one character.
function keysymFor(ch) {
    if (KEYSYMS[ch] !== undefined) return KEYSYMS[ch];
    // A letter is its own name, upper or lower — and the case matters:
    // the keysym "A" is a different key from "a".
    if (/^[A-Za-z]$/.test(ch)) return ch;
    return "";
}

// What a key shows, given the modifier state.
function labelFor(key, shifted) {
    if (key.label !== undefined && key.c === undefined) return key.label;
    if (key.mod !== undefined) return key.label || key.mod;
    if (key.k !== undefined) return key.label || key.k;
    if (key.label !== undefined) return key.label;
    return shifted ? key.s : key.c;
}

// What a key sends. Either a character to type, or a keysym to press.
//
//   { text: "A" }          type this
//   { key: "BackSpace" }   press this
//   { mod: "shift" }       a modifier, which is the caller's to latch
//   null                   nothing (a spacer)
function actionFor(key, shifted) {
    if (!key) return null;
    if (key.mod !== undefined) return { mod: key.mod };
    if (key.k !== undefined) return { key: key.k };
    if (key.c !== undefined) return { text: shifted ? key.s : key.c };
    return null;
}

// How wide a row is, in key units — so a row can be laid out by
// proportion rather than by counting keys, which none of these rows
// agree on.
function rowUnits(row) {
    var total = 0;
    for (var i = 0; i < row.length; i++) total += (row[i].w || 1);
    return total;
}

function widestRow() {
    var w = 0;
    for (var i = 0; i < ROWS.length; i++) w = Math.max(w, rowUnits(ROWS[i]));
    return w;
}
