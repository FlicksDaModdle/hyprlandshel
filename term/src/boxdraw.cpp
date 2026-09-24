#include "boxdraw.h"

#include <QPainterPath>

namespace {

// Each arm's weight: 0 none, 1 light, 2 heavy, 3 double.
struct Arms { int l, u, r, d; };

bool armsFor(char32_t ch, Arms *out) {
    switch (ch) {
    // ── straight ──
    case 0x2500: *out = {1,0,1,0}; return true;   // ─
    case 0x2501: *out = {2,0,2,0}; return true;   // ━
    case 0x2502: *out = {0,1,0,1}; return true;   // │
    case 0x2503: *out = {0,2,0,2}; return true;   // ┃
    // ── corners, every light/heavy combination ──
    case 0x250C: *out = {0,0,1,1}; return true;   // ┌
    case 0x250D: *out = {0,0,2,1}; return true;
    case 0x250E: *out = {0,0,1,2}; return true;
    case 0x250F: *out = {0,0,2,2}; return true;   // ┏
    case 0x2510: *out = {1,0,0,1}; return true;   // ┐
    case 0x2511: *out = {2,0,0,1}; return true;
    case 0x2512: *out = {1,0,0,2}; return true;
    case 0x2513: *out = {2,0,0,2}; return true;   // ┓
    case 0x2514: *out = {0,1,1,0}; return true;   // └
    case 0x2515: *out = {0,1,2,0}; return true;
    case 0x2516: *out = {0,2,1,0}; return true;
    case 0x2517: *out = {0,2,2,0}; return true;   // ┗
    case 0x2518: *out = {1,1,0,0}; return true;   // ┘
    case 0x2519: *out = {2,1,0,0}; return true;
    case 0x251A: *out = {1,2,0,0}; return true;
    case 0x251B: *out = {2,2,0,0}; return true;   // ┛
    // ── tees and crosses ──
    case 0x251C: *out = {0,1,1,1}; return true;   // ├
    case 0x2523: *out = {0,2,2,2}; return true;   // ┣
    case 0x2524: *out = {1,1,0,1}; return true;   // ┤
    case 0x252B: *out = {2,2,0,2}; return true;   // ┫
    case 0x252C: *out = {1,0,1,1}; return true;   // ┬
    case 0x2533: *out = {2,0,2,2}; return true;   // ┳
    case 0x2534: *out = {1,1,1,0}; return true;   // ┴
    case 0x253B: *out = {2,2,2,0}; return true;   // ┻
    case 0x253C: *out = {1,1,1,1}; return true;   // ┼
    case 0x254B: *out = {2,2,2,2}; return true;   // ╋
    // ── double ──
    case 0x2550: *out = {3,0,3,0}; return true;   // ═
    case 0x2551: *out = {0,3,0,3}; return true;   // ║
    case 0x2554: *out = {0,0,3,3}; return true;   // ╔
    case 0x2557: *out = {3,0,0,3}; return true;   // ╗
    case 0x255A: *out = {0,3,3,0}; return true;   // ╚
    case 0x255D: *out = {3,3,0,0}; return true;   // ╝
    case 0x2560: *out = {0,3,3,3}; return true;   // ╠
    case 0x2563: *out = {3,3,0,3}; return true;   // ╣
    case 0x2566: *out = {3,0,3,3}; return true;   // ╦
    case 0x2569: *out = {3,3,3,0}; return true;   // ╩
    case 0x256C: *out = {3,3,3,3}; return true;   // ╬
    default: return false;
    }
}

bool isRounded(char32_t ch) { return ch >= 0x256D && ch <= 0x2570; }
bool isBlock(char32_t ch) {
    return (ch >= 0x2580 && ch <= 0x2590) || (ch >= 0x2591 && ch <= 0x2593);
}

qreal armWidth(int weight, qreal base) {
    switch (weight) {
    case 2: return qMax<qreal>(2, qRound(base * 2));
    default: return qMax<qreal>(1, qRound(base));
    }
}

}

namespace BoxDraw {

bool handles(char32_t ch) {
    Arms a;
    return armsFor(ch, &a) || isRounded(ch) || isBlock(ch);
}

void draw(QPainter *painter, const QRectF &cell, char32_t ch,
          const QColor &colour, qreal weight) {
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, false);
    painter->setPen(Qt::NoPen);
    painter->setBrush(colour);

    const qreal cx = qRound(cell.center().x());
    const qreal cy = qRound(cell.center().y());

    if (isBlock(ch)) {
        painter->setRenderHint(QPainter::Antialiasing, false);
        switch (ch) {
        case 0x2580: painter->fillRect(QRectF(cell.left(), cell.top(),
                                              cell.width(), cell.height() / 2), colour); break;
        case 0x2584: painter->fillRect(QRectF(cell.left(), cy,
                                              cell.width(), cell.height() / 2), colour); break;
        case 0x2588: painter->fillRect(cell, colour); break;
        case 0x258C: painter->fillRect(QRectF(cell.left(), cell.top(),
                                              cell.width() / 2, cell.height()), colour); break;
        case 0x2590: painter->fillRect(QRectF(cx, cell.top(),
                                              cell.width() / 2, cell.height()), colour); break;
        case 0x2591:
        case 0x2592:
        case 0x2593: {
            // The shades, as a stipple rather than a flat wash: the point
            // of three of them is that they are distinguishable.
            const int step = ch == 0x2591 ? 4 : (ch == 0x2592 ? 2 : 1);
            const int skip = ch == 0x2593 ? 4 : 0;
            for (int y = 0; y < cell.height(); y += 1)
                for (int x = 0; x < cell.width(); x += 1)
                    if (((x + y) % (step + 1) == 0) || (skip && (x + y) % 4 != 0))
                        painter->fillRect(QRectF(cell.left() + x, cell.top() + y, 1, 1), colour);
            break;
        }
        default: break;
        }
        painter->restore();
        return;
    }

    if (isRounded(ch)) {
        // ╭ ╮ ╯ ╰ — an arc of a quarter circle, meeting the straight arms
        // of its neighbours exactly where they end.
        const qreal w = armWidth(1, weight);
        const qreal r = qMin(cell.width(), cell.height()) / 2;
        QPainterPath path;
        const bool right = (ch == 0x256D || ch == 0x2570);
        const bool down  = (ch == 0x256D || ch == 0x256E);
        const qreal ex = right ? cell.right() : cell.left();
        const qreal ey = down ? cell.bottom() : cell.top();
        path.moveTo(ex, cy);
        path.quadTo(QPointF(cx, cy), QPointF(cx, ey));
        painter->setPen(QPen(colour, w, Qt::SolidLine, Qt::FlatCap));
        painter->setBrush(Qt::NoBrush);
        painter->setRenderHint(QPainter::Antialiasing, true);
        painter->drawPath(path);
        painter->restore();
        Q_UNUSED(r);
        return;
    }

    Arms a;
    if (!armsFor(ch, &a)) { painter->restore(); return; }

    // Each arm runs from the cell's centre to its edge, so the arm of the
    // cell next door starts exactly where this one stops.
    const auto arm = [&](int w, qreal x0, qreal y0, qreal x1, qreal y1) {
        if (w == 0) return;
        const qreal t = armWidth(w, weight);
        if (w == 3) {
            // A double line is two lines a gap apart, and the gap is what
            // makes it read as double at 13px.
            const qreal off = qMax<qreal>(1, qRound(weight));
            if (qFuzzyCompare(y0, y1)) {
                painter->fillRect(QRectF(qMin(x0, x1), y0 - off - t, qAbs(x1 - x0) + t, t), colour);
                painter->fillRect(QRectF(qMin(x0, x1), y0 + off, qAbs(x1 - x0) + t, t), colour);
            } else {
                painter->fillRect(QRectF(x0 - off - t, qMin(y0, y1), t, qAbs(y1 - y0) + t), colour);
                painter->fillRect(QRectF(x0 + off, qMin(y0, y1), t, qAbs(y1 - y0) + t), colour);
            }
            return;
        }
        if (qFuzzyCompare(y0, y1))
            painter->fillRect(QRectF(qMin(x0, x1), y0 - t / 2, qAbs(x1 - x0), t), colour);
        else
            painter->fillRect(QRectF(x0 - t / 2, qMin(y0, y1), t, qAbs(y1 - y0)), colour);
    };

    // Horizontal arms run a half-thickness past the centre so that a
    // corner has no notch where the two meet.
    arm(a.l, cell.left(), cy, cx + armWidth(qMax(a.u, a.d), weight) / 2, cy);
    arm(a.r, cx - armWidth(qMax(a.u, a.d), weight) / 2, cy, cell.right(), cy);
    arm(a.u, cx, cell.top(), cx, cy + armWidth(qMax(a.l, a.r), weight) / 2);
    arm(a.d, cx, cy - armWidth(qMax(a.l, a.r), weight) / 2, cx, cell.bottom());

    painter->restore();
}

}
