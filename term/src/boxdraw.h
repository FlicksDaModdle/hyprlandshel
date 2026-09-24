#pragma once

#include <QPainter>
#include <QRectF>

// Box-drawing characters, drawn rather than typeset.
//
// A TUI's frames are only continuous if each piece exactly meets the
// next, and a font cannot promise that: the glyphs come out of whatever
// face the system falls back to for U+2500, at whatever advance and
// stroke that face happens to use, and the result is a frame with gaps
// at every corner — which is precisely what it looked like.
//
// So these are drawn from the cell's own geometry: a line from the
// centre to the edge for each arm, at a thickness scaled to the font.
// Two adjacent cells then meet at their shared edge by construction, at
// any size and in any font.
//
// Anything not in the table falls through to the font, which is the
// right answer for the half-dozen shading and diagonal characters where
// drawing them would be worse than what a font already has.
namespace BoxDraw {

// Does this codepoint get drawn here?
bool handles(char32_t ch);

// Draws it into `cell`. `weight` is the font's stem width, which is what
// keeps a frame looking like it belongs to the text around it.
void draw(QPainter *painter, const QRectF &cell, char32_t ch,
          const QColor &colour, qreal weight);

}
