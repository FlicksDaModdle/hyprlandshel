pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// A Kvantum theme, generated from whatever theme the shell is wearing.
//
// kdeglobals gets KDE applications to use the shell's *colours*; it cannot
// change how they are drawn. Kvantum can: it is a Qt style that takes its
// widget graphics from an SVG, so a button is whatever the SVG says a
// button is. This writes that SVG, and the .kvconfig that names its
// elements, into ~/.config/Kvantum/Hyprshell/.
//
// Kvantum resolves an element in three steps (Style::renderElement,
// style/rendering.cpp): the exact id, then the same id with "-inactive"
// dropped, then with "-toggled"/"-pressed"/"-focused" replaced by "-normal",
// and finally its own default SVG. So a theme only has to draw the normal
// state of everything it names, plus whichever other states it wants to
// differ — which is what makes generating one from a palette reasonable
// rather than an exercise in drawing 500 rectangles.
//
// The vocabulary below is deliberately small: flat interiors, hairline
// borders, the shell's radii, accent on focus. That is the design's own
// language, and it is what a file manager can actually be made to speak.
Singleton {
    id: root

    readonly property string kvDir: (Quickshell.env("XDG_CONFIG_HOME")
                                     || (Quickshell.env("HOME") + "/.config"))
                                    + "/Kvantum"
    readonly property string themeName: "Hyprshell"
    readonly property bool enabled: Config.Appearance.kvantumTheme

    function hex(c) {
        function two(n) {
            const s = Math.round(Math.max(0, Math.min(255, n * 255))).toString(16);
            return s.length < 2 ? "0" + s : s;
        }
        return "#" + two(c.r) + two(c.g) + two(c.b);
    }

    // Flatten a translucent token against what it sits on: an SVG fill with
    // an alpha would be honoured, but Kvantum stacks these, and two
    // half-transparent layers is not the colour the shell shows.
    function over(top, under) {
        const a = top.a;
        return Qt.rgba(top.r * a + under.r * (1 - a),
                       top.g * a + under.g * (1 - a),
                       top.b * a + under.b * (1 - a), 1);
    }

    // ── the SVG ───────────────────────────────────────────────────────────
    // Each element is a 9-slice: four corners carrying the rounding, four
    // edges carrying the border, and an interior. Kvantum stretches each
    // piece into its side of the widget, so the corner size is the radius
    // and the edge thickness is the frame width in the .kvconfig.
    // `under` is optional: an accent rule along the bottom edge. It is how
    // the design marks a selected thing — a quiet fill with a line under
    // it — rather than filling the whole row with accent, which is what
    // every state did before and which reads as a warning, not a selection.
    function slice(name, x, y, fill, border, radius, under) {
        const R = radius, S = 24, F = R;
        const U = under || "";
        const out = [];
        function rect(id, rx, ry, w, h, f) {
            out.push('<rect id="' + id + '" x="' + (x + rx) + '" y="' + (y + ry)
                     + '" width="' + w + '" height="' + h + '" fill="' + f + '"/>');
        }
        // A corner with no border is just the fill; with no fill, just the
        // line. "none" is a real answer for both — an item view's normal
        // state paints nothing at all.
        function corner(id, cx, cy, sweep, dx, dy) {
            // A quarter disc in the fill, with the arc stroked as the border.
            const px = x + cx, py = y + cy;
            // The rule carries on under the two bottom corners, or it would
            // stop short of them and look like a mistake.
            const bar = (U !== "" && dy < 0)
                ? '<rect x="' + (dx > 0 ? px : px - R) + '" y="' + (py - 2)
                  + '" width="' + R + '" height="2" fill="' + U + '"/>'
                : "";
            out.push('<g id="' + id + '">'
                     + '<path d="M' + px + ',' + (py + dy * R) + ' A' + R + ',' + R
                     + ' 0 0 ' + sweep + ' ' + (px + dx * R) + ',' + py
                     + ' L' + (px + dx * R) + ',' + (py + dy * R) + ' Z" fill="' + fill + '"/>'
                     + '<path d="M' + px + ',' + (py + dy * R) + ' A' + R + ',' + R
                     + ' 0 0 ' + sweep + ' ' + (px + dx * R) + ',' + py
                     + '" fill="none" stroke="' + border + '" stroke-width="1"/>'
                     + bar
                     + '</g>');
        }
        // corners: the arc always runs from the vertical edge to the
        // horizontal one, so the sweep flips with the quadrant.
        corner(name + "-topleft", 0, 0, 1, 1, 1);
        corner(name + "-topright", F + S + R, 0, 0, -1, 1);
        corner(name + "-bottomleft", 0, F + S + R, 0, 1, -1);
        corner(name + "-bottomright", F + S + R, F + S + R, 1, -1, -1);

        // Edges: the interior colour with a hairline along the outer side.
        //
        // Both inside one group, because Kvantum draws the element with that
        // id and nothing else — a border kept as a sibling rect would never
        // be rendered at all.
        function edge(id, rx, ry, w, h, lx, ly, lw, lh, isBottom) {
            const rule = (U !== "" && isBottom)
                ? '<rect x="' + (x + lx) + '" y="' + (y + F + S + F - 2) + '" width="' + lw
                  + '" height="2" fill="' + U + '"/>'
                : (border === "none" ? ""
                   : '<rect x="' + (x + lx) + '" y="' + (y + ly) + '" width="' + lw
                     + '" height="' + lh + '" fill="' + border + '"/>');
            out.push('<g id="' + id + '">'
                     + '<rect x="' + (x + rx) + '" y="' + (y + ry) + '" width="' + w
                     + '" height="' + h + '" fill="' + fill + '"/>'
                     + rule
                     + '</g>');
        }
        edge(name + "-top", F, 0, S, F, F, 0, S, 1);
        edge(name + "-bottom", F, F + S, S, F, F, F + S + F - 1, S, 1, true);
        edge(name + "-left", 0, F, F, S, 0, F, 1, S);
        edge(name + "-right", F + S, F, F, S, F + S + F - 1, F, 1, S);

        rect(name, F, F, S, S, fill);
        return out.join("\n");
    }

    // A flat element with no rounding, for grooves and separators.
    function flat(name, x, y, fill) {
        return '<rect id="' + name + '" x="' + x + '" y="' + y
             + '" width="24" height="24" fill="' + fill + '"/>';
    }

    // Chevrons and marks. Drawn rather than left to Kvantum's default SVG,
    // because the default's arrows are the one thing that would still look
    // like somebody else's theme.
    function arrow(name, x, y, dir, color) {
        const cx = x + 8, cy = y + 8;
        let d;
        if (dir === "down") d = "M" + (cx - 4) + "," + (cy - 2) + " L" + cx + "," + (cy + 3) + " L" + (cx + 4) + "," + (cy - 2);
        else if (dir === "up") d = "M" + (cx - 4) + "," + (cy + 2) + " L" + cx + "," + (cy - 3) + " L" + (cx + 4) + "," + (cy + 2);
        else if (dir === "left") d = "M" + (cx + 2) + "," + (cy - 4) + " L" + (cx - 3) + "," + cy + " L" + (cx + 2) + "," + (cy + 4);
        else d = "M" + (cx - 2) + "," + (cy - 4) + " L" + (cx + 3) + "," + cy + " L" + (cx - 2) + "," + (cy + 4);
        return '<path id="' + name + '" d="' + d + '" fill="none" stroke="' + color
             + '" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>';
    }

    // A check box or a radio, whole, in one element.
    //
    // Kvantum draws these from the *interior* element plus a state suffix —
    // `checkbox-checked-normal`, not the indicator named in the .kvconfig —
    // and it draws that one id into the whole indicator rect. So the box and
    // the mark inside it have to be the same element, and every suffix it
    // can ask for has to exist, or it falls through to its own default SVG
    // and one control comes out in somebody else's colours.
    function markBox(id, x, y, fill, border, radius, mark) {
        return '<g id="' + id + '">'
             + '<rect x="' + (x + 4) + '" y="' + (y + 4) + '" width="16" height="16"'
             + ' rx="' + radius + '" ry="' + radius + '" fill="' + fill + '"'
             + ' stroke="' + border + '" stroke-width="1"/>'
             + (mark || "")
             + '</g>';
    }

    // The mark itself, positioned for markBox's 16×16 interior.
    function tickPath(x, y, color) {
        const cx = x + 12, cy = y + 12;
        return '<path d="M' + (cx - 3.5) + ',' + cy
             + ' L' + (cx - 1) + ',' + (cy + 2.5)
             + ' L' + (cx + 3.5) + ',' + (cy - 2.5)
             + '" fill="none" stroke="' + color
             + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
    }

    function dashPath(x, y, color) {
        return '<rect x="' + (x + 8) + '" y="' + (y + 11) + '" width="8" height="2"'
             + ' rx="1" fill="' + color + '"/>';
    }

    function dotMark(x, y, color) {
        return '<circle cx="' + (x + 12) + '" cy="' + (y + 12) + '" r="3.5" fill="'
             + color + '"/>';
    }

    function tick(name, x, y, color) {
        const cx = x + 8, cy = y + 8;
        return '<path id="' + name + '" d="M' + (cx - 4) + "," + cy
             + " L" + (cx - 1) + "," + (cy + 3) + " L" + (cx + 4) + "," + (cy - 3)
             + '" fill="none" stroke="' + color
             + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
    }

    function dot(name, x, y, color) {
        return '<circle id="' + name + '" cx="' + (x + 8) + '" cy="' + (y + 8)
             + '" r="3.5" fill="' + color + '"/>';
    }

    readonly property string svg: {
        const A = Config.Appearance;
        const ground = root.hex(A.ground);
        const surface = root.hex(A.surface);
        const sheet = root.hex(root.over(A.sheet, A.ground));
        const line = root.hex(root.over(A.rule, A.ground));
        const edge = root.hex(root.over(A.edge, A.ground));
        const btn = root.hex(root.over(A.hover, A.surface));
        const btnHi = root.hex(root.over(A.sel, A.surface));
        const accent = root.hex(A.accent);
        const ink = root.hex(A.ink);
        const ink2 = root.hex(A.ink2);
        const ink3 = root.hex(A.ink3);
        const inkOnAccent = root.hex(A.inkOnAccent);

        const parts = [];
        let row = 0;
        function put(fn) { parts.push(fn(0, row * 56)); row++; }

        // Interactive things: normal, hovered, pressed, and focus as accent.
        function states(name, fill, hiFill, pressFill, radius) {
            parts.push(root.slice(name + "-normal", 0, row * 56, fill, line, radius));
            parts.push(root.slice(name + "-focused", 120, row * 56, hiFill, accent, radius));
            parts.push(root.slice(name + "-pressed", 240, row * 56, pressFill, accent, radius));
            parts.push(root.slice(name + "-toggled", 360, row * 56, accent, accent, radius));
            parts.push(root.slice(name + "-normal-inactive", 480, row * 56, fill, line, radius));
            row++;
        }
        // Selected things: the design marks them with a quiet fill and an
        // accent rule underneath — see the selected tile and the selected
        // sidebar row in the concept — not with a block of accent.
        function marked(name, fill, hiFill, selFill, border, radius) {
            parts.push(root.slice(name + "-normal", 0, row * 56, fill, border, radius));
            parts.push(root.slice(name + "-focused", 120, row * 56, hiFill, border, radius));
            parts.push(root.slice(name + "-pressed", 240, row * 56, selFill, border, radius, accent));
            parts.push(root.slice(name + "-toggled", 360, row * 56, selFill, border, radius, accent));
            parts.push(root.slice(name + "-normal-inactive", 480, row * 56, fill, border, radius));
            row++;
        }
        // Containers: one state is the whole story.
        function plain(name, fill, border, radius) {
            parts.push(root.slice(name + "-normal", 0, row * 56, fill, border, radius));
            row++;
        }

        states("button", btn, btnHi, btnHi, 6);
        states("lineedit", ground, ground, ground, 6);
        states("combo", btn, btnHi, btnHi, 6);
        marked("tab", surface, btn, btn, line, 6);
        // Checks and radios are not nine-slices: Kvantum paints one element
        // into the indicator rect, so each state is drawn whole below.
        states("scrollbarslider", root.hex(root.over(A.sel, A.ground)),
               root.hex(A.ink3), root.hex(A.ink3), 5);
        states("sliderhandle", accent, accent, accent, 8);
        marked("itemview", "none", btn, btnHi, "none", 5);

        plain("common", surface, line, 6);
        plain("toolbar", ground, line, 0);
        plain("menu", sheet, edge, 10);
        plain("menuitem", "none", "none", 5);
        plain("tabframe", surface, line, 6);
        plain("tooltip", surface, edge, 8);
        plain("dialog", ground, edge, 10);
        plain("window", ground, line, 0);
        plain("group", surface, line, 8);
        plain("dock", surface, line, 6);
        plain("header", root.hex(root.over(A.hover, A.ground)), line, 0);
        plain("progressbar", root.hex(root.over(A.hover, A.ground)), line, 5);
        plain("progress", accent, accent, 5);
        plain("scrollbargroove", ground, "none", 5);
        plain("slidergroove", root.hex(root.over(A.hover, A.ground)), "none", 2);
        plain("focus", "none", accent, 6);
        plain("tfocus", "none", accent, 6);

        // Check boxes and radios, every suffix Kvantum can ask for.
        // `-inactive` is left out on purpose: the renderer strips it and
        // retries, so the active element covers it.
        const cy0 = row * 56;
        let cx0 = 0;
        function control(base, radius, mark) {
            function one(suffix, fill, border, m) {
                parts.push(root.markBox(base + suffix, cx0, cy0, fill, border, radius, m));
                cx0 += 24;
            }
            one("-normal", ground, line, "");
            one("-focused", ground, accent, "");
            one("-pressed", ground, accent, "");
            one("-checked-normal", accent, accent, mark(cx0, cy0, inkOnAccent));
            one("-checked-focused", accent, accent, mark(cx0, cy0, inkOnAccent));
            one("-checked-pressed", accent, accent, mark(cx0, cy0, inkOnAccent));
        }
        control("checkbox", 4, (x, y, c) => root.tickPath(x, y, c));
        control("radio", 8, (x, y, c) => root.dotMark(x, y, c));
        // The third check state, which Qt calls partially checked.
        parts.push(root.markBox("checkbox-tristate-normal", cx0, cy0, accent, accent, 4,
                                root.dashPath(cx0, cy0, inkOnAccent)));
        cx0 += 24;
        parts.push(root.markBox("checkbox-tristate-focused", cx0, cy0, accent, accent, 4,
                                root.dashPath(cx0, cy0, inkOnAccent)));
        row++;

        // Indicators. -normal covers the rest by Kvantum's own fallback.
        const iy = row * 56;
        let ix = 0;
        function ind(fn) { parts.push(fn(ix, iy)); ix += 24; }
        ind((x, y) => root.arrow("arrow-down-normal", x, y, "down", ink2));
        ind((x, y) => root.arrow("arrow-up-normal", x, y, "up", ink2));
        ind((x, y) => root.arrow("arrow-left-normal", x, y, "left", ink2));
        ind((x, y) => root.arrow("arrow-right-normal", x, y, "right", ink2));
        ind((x, y) => root.arrow("b-arrow-down-normal", x, y, "down", ink));
        ind((x, y) => root.arrow("b-arrow-up-normal", x, y, "up", ink));
        ind((x, y) => root.arrow("b-arrow-left-normal", x, y, "left", ink));
        ind((x, y) => root.arrow("b-arrow-right-normal", x, y, "right", ink));
        ind((x, y) => root.arrow("s-arrow-down-normal", x, y, "down", ink2));
        ind((x, y) => root.arrow("s-arrow-up-normal", x, y, "up", ink2));

        // Kvantum also asks for the bare element with no direction — the
        // "there is more this way" mark on a menu item or a combo — and for
        // the empty states of a check and a radio, which are nothing at all
        // but must exist or it falls through to its own default SVG.
        ind((x, y) => root.arrow("arrow-normal", x, y, "right", ink2));
        ind((x, y) => root.arrow("b-arrow-normal", x, y, "down", ink));
        ind((x, y) => root.arrow("s-arrow-normal", x, y, "down", ink2));
        ind((x, y) => '<g id="splitter-normal"><rect x="' + (x + 7) + '" y="' + (y + 4)
                      + '" width="2" height="8" rx="1" fill="' + ink3 + '"/></g>');
        ind((x, y) => '<g id="resize-grip-normal">'
                      + '<circle cx="' + (x + 11) + '" cy="' + (y + 11) + '" r="1.2" fill="' + ink3 + '"/>'
                      + '<circle cx="' + (x + 7) + '" cy="' + (y + 11) + '" r="1.2" fill="' + ink3 + '"/>'
                      + '<circle cx="' + (x + 11) + '" cy="' + (y + 7) + '" r="1.2" fill="' + ink3 + '"/>'
                      + '</g>');

        const height = (row + 2) * 56;
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
             + '<!-- Generated by the shell from the current theme.\n'
             + '     Edit theme.json, or the shell\'s Settings, not this. -->\n'
             + '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="'
             + height + '" viewBox="0 0 640 ' + height + '">\n'
             + parts.join("\n") + "\n</svg>\n";
    }

    // ── the .kvconfig ─────────────────────────────────────────────────────
    readonly property string kvconfig: {
        const A = Config.Appearance;
        const ink = root.hex(A.ink);
        const ink2 = root.hex(A.ink2);
        const ink3 = root.hex(A.ink3);
        const inkOnAccent = root.hex(A.inkOnAccent);
        const accent = root.hex(A.accent);

        function group(name, body) { return "[" + name + "]\n" + body + "\n"; }
        function framed(el, f) {
            return "frame=true\nframe.element=" + el + "\n"
                 + "frame.top=" + f + "\nframe.bottom=" + f
                 + "\nframe.left=" + f + "\nframe.right=" + f + "\n"
                 + "interior=true\ninterior.element=" + el + "\n";
        }

        return "# Generated by the shell from the current theme.\n"
             + "# Edit theme.json, or the shell's Settings, not this file.\n\n"
             + group("%General",
                 "author=hyprshell\n"
                 + "comment=Generated from the shell's theme\n"
                 + "x11drag=all\n"
                 + "alt_mnemonic=true\n"
                 + "left_tabs=false\n"
                 + "attach_active_tab=true\n"
                 + "joined_inactive_tabs=true\n"
                 + "spread_progressbar=true\n"
                 + "progressbar_thickness=6\n"
                 + "composite=true\n"
                 + "menu_shadow_depth=6\n"
                 + "tooltip_shadow_depth=5\n"
                 + "splitter_width=6\n"
                 + "scroll_width=11\n"
                 + "scroll_arrows=false\n"
                 + "transient_scrollbar=true\n"
                 + "slider_width=4\n"
                 + "slider_handle_width=16\n"
                 + "slider_handle_length=16\n"
                 + "check_size=16\n"
                 + "textless_progressbar=false\n"
                 + "toolbutton_style=0\n"
                 + "translucent_windows=false\n"
                 + "blurring=false\n"
                 + "popup_blurring=true\n"
                 + "vertical_spin_indicators=false\n"
                 + "combo_as_lineedit=true\n"
                 + "combo_menu=true\n"
                 + "inline_spin_indicators=true\n"
                 + "layout_spacing=4\n"
                 + "layout_margin=6\n"
                 + "submenu_overlap=2\n"
                 + "tooltip_delay=-1\n"
                 + "small_icon_size=16\n"
                 + "large_icon_size=32\n"
                 + "button_icon_size=16\n"
                 + "toolbar_icon_size=18\n"
                 + "animate_states=true\n")
             + group("GeneralColors",
                 "window.color=" + root.hex(A.ground) + "\n"
                 + "base.color=" + root.hex(A.surface) + "\n"
                 + "alt.base.color=" + root.hex(root.over(A.hover, A.surface)) + "\n"
                 + "button.color=" + root.hex(root.over(A.hover, A.surface)) + "\n"
                 + "light.color=" + root.hex(root.over(A.hover, A.ground)) + "\n"
                 + "mid.light.color=" + root.hex(root.over(A.hover, A.ground)) + "\n"
                 + "dark.color=" + root.hex(root.over(A.rule, A.ground)) + "\n"
                 + "mid.color=" + root.hex(root.over(A.rule, A.ground)) + "\n"
                 + "highlight.color=" + accent + "\n"
                 + "inactive.highlight.color=" + accent + "\n"
                 + "text.color=" + ink + "\n"
                 + "window.text.color=" + ink + "\n"
                 + "button.text.color=" + ink + "\n"
                 + "disabled.text.color=" + ink3 + "\n"
                 + "tooltip.text.color=" + ink + "\n"
                 + "highlight.text.color=" + inkOnAccent + "\n"
                 + "link.color=" + accent + "\n"
                 + "link.visited.color=" + ink2 + "\n"
                 + "progress.indicator.text.color=" + inkOnAccent + "\n")
             + group("Hacks",
                 "transparent_ktitle_label=true\n"
                 + "transparent_dolphin_view=false\n"
                 + "blur_translucent=true\n"
                 + "transparent_menutitle=true\n"
                 + "respect_darkness=true\n"
                 + "disabled_icon_opacity=60\n"
                 + "iconless_menu=false\n"
                 + "iconless_pushbutton=false\n"
                 + "normal_default_pushbutton=true\n"
                 + "single_top_toolbar=true\n"
                 + "tint_on_mouseover=0\n"
                 + "no_selection_tint=true\n"
                 + "transparent_arrow_button=true\n")
             + group("PanelButtonCommand",
                 framed("button", 6)
                 + "indicator.element=b-arrow\nindicator.size=10\n"
                 + "text.normal.color=" + ink + "\n"
                 + "text.focus.color=" + ink + "\n"
                 + "text.press.color=" + ink + "\n"
                 + "text.toggle.color=" + inkOnAccent + "\n"
                 + "text.margin.top=3\ntext.margin.bottom=3\n"
                 + "text.margin.left=6\ntext.margin.right=6\n"
                 + "text.iconspacing=5\nframe.expansion=0\nmin_width=+0.2font\n")
             + group("PanelButtonTool", "inherits=PanelButtonCommand\n")
             + group("ToolbarButton", "inherits=PanelButtonCommand\nfocusRectElement=tfocus\n")
             + group("Dock", "inherits=PanelButtonCommand\n" + framed("dock", 6))
             + group("DockTitle", "inherits=PanelButtonCommand\nframe=false\ninterior=false\n"
                     + "text.bold=true\n")
             + group("IndicatorSpinBox", "inherits=PanelButtonCommand\n"
                     + "indicator.element=s-arrow\nindicator.size=10\n")
             // The mark is part of the interior element (see markBox), so
             // there is no separate indicator to name here.
             + group("RadioButton", "inherits=PanelButtonCommand\nframe=false\n"
                     + "interior.element=radio\nindicator.size=16\n")
             + group("CheckBox", "inherits=PanelButtonCommand\nframe=false\n"
                     + "interior.element=checkbox\nindicator.size=16\n")
             + group("GenericFrame", "inherits=PanelButtonCommand\n"
                     + "frame=true\ninterior=false\n"
                     + "frame.element=common\ninterior.element=common\n"
                     + "frame.top=6\nframe.bottom=6\nframe.left=6\nframe.right=6\n")
             + group("LineEdit", "inherits=PanelButtonCommand\n" + framed("lineedit", 6)
                     + "text.margin.left=6\ntext.margin.right=6\n")
             + group("ToolbarLineEdit", "inherits=LineEdit\n")
             + group("DropDownButton", "inherits=PanelButtonCommand\n"
                     + "indicator.element=b-arrow-down\n")
             + group("ComboBox", "inherits=PanelButtonCommand\n" + framed("combo", 6)
                     + "text.margin.left=6\ntext.margin.right=6\n")
             + group("ToolbarComboBox", "inherits=ComboBox\nfocusRectElement=tfocus\n")
             + group("IndicatorArrow", "indicator.element=arrow\nindicator.size=10\n")
             + group("ToolboxTab", "inherits=PanelButtonCommand\n")
             + group("Tab", "inherits=PanelButtonCommand\n" + framed("tab", 6)
                     + "text.margin.left=8\ntext.margin.right=8\n"
                     + "text.margin.top=4\ntext.margin.bottom=4\n"
                     // Same as ItemView: the selected tab is marked by the
                     // rule beneath it, not by an accent fill.
                     + "text.press.color=" + ink + "\n"
                     + "text.toggle.color=" + ink + "\n")
             + group("TabFrame", "inherits=PanelButtonCommand\n" + framed("tabframe", 6))
             + group("TreeExpander", "indicator.element=arrow\nindicator.size=10\n")
             + group("HeaderSection", "inherits=PanelButtonCommand\n"
                     + framed("header", 0) + "indicator.element=s-arrow\n"
                     + "text.normal.color=" + ink2 + "\ntext.bold=true\n")
             + group("SizeGrip", "indicator.element=resize-grip\nindicator.size=12\n")
             + group("Toolbar", "inherits=PanelButtonCommand\n" + framed("toolbar", 0))
             + group("Slider", "inherits=PanelButtonCommand\n"
                     + framed("slidergroove", 2) + "frame.expansion=0\n")
             + group("SliderCursor", "inherits=PanelButtonCommand\n"
                     + framed("sliderhandle", 8))
             + group("Progressbar", "inherits=PanelButtonCommand\n"
                     + framed("progressbar", 5)
                     + "text.normal.color=" + ink2 + "\ntext.bold=false\n")
             + group("ProgressbarContents", "inherits=PanelButtonCommand\n"
                     + framed("progress", 5))
             // A selected row is a quiet fill with an accent rule under it,
             // so its label stays the ordinary foreground. The inherited
             // colour here is the one for an accent-filled button, and on
             // this fill it would be white text on near-black.
             + group("ItemView", "inherits=PanelButtonCommand\n"
                     + framed("itemview", 5)
                     + "text.normal.color=" + ink + "\n"
                     + "text.focus.color=" + ink + "\n"
                     + "text.press.color=" + ink + "\n"
                     + "text.toggle.color=" + ink + "\n")
             + group("Splitter", "indicator.element=splitter\nindicator.size=16\n")
             + group("Scrollbar", "inherits=PanelButtonCommand\n"
                     + "indicator.element=arrow\nindicator.size=10\n")
             + group("ScrollbarGroove", "inherits=PanelButtonCommand\n"
                     + framed("scrollbargroove", 5))
             + group("ScrollbarSlider", "inherits=PanelButtonCommand\n"
                     + framed("scrollbarslider", 5))
             + group("MenuItem", "inherits=PanelButtonCommand\n"
                     + framed("menuitem", 5)
                     + "text.margin.left=8\ntext.margin.right=8\n"
                     + "text.normal.color=" + ink + "\n"
                     + "text.focus.color=" + inkOnAccent + "\n"
                     + "indicator.element=arrow\n")
             + group("MenuBarItem", "inherits=PanelButtonCommand\n"
                     + framed("menuitem", 5)
                     + "text.margin.left=8\ntext.margin.right=8\n")
             + group("Menu", "inherits=PanelButtonCommand\n" + framed("menu", 10))
             + group("MenuBar", "inherits=PanelButtonCommand\n" + framed("toolbar", 0))
             + group("TitleBar", "inherits=PanelButtonCommand\n"
                     + "frame=false\ninterior=false\n"
                     + "text.normal.color=" + ink + "\n")
             + group("ToolTip", "inherits=PanelButtonCommand\n" + framed("tooltip", 8))
             + group("StatusBar", "inherits=PanelButtonCommand\n"
                     + "frame=false\ninterior=false\n")
             + group("Window", "inherits=PanelButtonCommand\n" + framed("window", 0))
             + group("Dialog", "inherits=PanelButtonCommand\n" + framed("dialog", 0))
             + group("GroupBox", "inherits=PanelButtonCommand\n"
                     + "frame=false\ninterior=false\ntext.bold=true\n")
             + group("Focus", "frame=true\nframe.element=focus\n"
                     + "frame.top=6\nframe.bottom=6\nframe.left=6\nframe.right=6\n"
                     + "interior=false\n");
    }

    // ── writing it out ────────────────────────────────────────────────────
    FileView {
        id: svgFile
        path: root.kvDir + "/" + root.themeName + "/" + root.themeName + ".svg"
        preload: true
        printErrors: false
        atomicWrites: true
    }

    FileView {
        id: configFile
        path: root.kvDir + "/" + root.themeName + "/" + root.themeName + ".kvconfig"
        preload: true
        printErrors: false
        atomicWrites: true
    }

    // Which theme Kvantum is wearing. Only this key is written, so a
    // kvantum.kvconfig you have set up otherwise keeps the rest.
    FileView {
        id: selection
        path: root.kvDir + "/kvantum.kvconfig"
        preload: true
        printErrors: false
        atomicWrites: true
    }

    // The result has to be a fixed point: feed this its own output and it
    // must come back unchanged, or the file is rewritten on every theme
    // change even though nothing about it differs. That is why the blank
    // lines are trimmed before the key is appended and the ending is
    // normalised, rather than the lines simply being passed through.
    function selectionWanted() {
        const existing = selection.text() || "";
        const out = [];
        let inGeneral = false, wrote = false;

        function append() {
            while (out.length && out[out.length - 1].trim() === "") out.pop();
            out.push("theme=" + themeName);
            wrote = true;
        }

        for (const line of existing.split("\n")) {
            if (line.indexOf("[") === 0) {
                if (inGeneral && !wrote) { append(); out.push(""); }
                inGeneral = line.indexOf("[General]") === 0;
            }
            if (inGeneral && line.indexOf("theme=") === 0) continue;
            out.push(line);
        }
        if (inGeneral && !wrote) append();

        let body = out.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "");
        if (!wrote) body = "[General]\ntheme=" + themeName + (body === "" ? "" : "\n\n" + body);
        return body + "\n";
    }

    // The directory has to exist before a FileView can write into it.
    Process { id: mkdir }

    function apply() {
        if (!enabled) return;
        mkdir.command = ["mkdir", "-p", root.kvDir + "/" + root.themeName];
        mkdir.running = true;
        write.restart();
    }

    Timer {
        id: write
        interval: 120
        onTriggered: {
            if (svgFile.text() !== root.svg) svgFile.setText(root.svg);
            if (configFile.text() !== root.kvconfig) configFile.setText(root.kvconfig);
            const want = root.selectionWanted();
            if (selection.text() !== want) selection.setText(want);
        }
    }

    readonly property string watched: enabled ? svg + kvconfig : ""
    onWatchedChanged: apply()
}
