#include "termview.h"
#include "boxdraw.h"

#include <QClipboard>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPainter>
#include <QWheelEvent>

TermView::TermView(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setFlag(ItemHasContents, true);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton);
    setAcceptHoverEvents(false);
    setFocus(true);
    // The grid is opaque and painted edge to edge, so the item does not
    // need the alpha channel it would otherwise composite through.
    setOpaquePainting(true);
    setRenderTarget(QQuickPaintedItem::FramebufferObject);

    m_font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    m_font.setPixelSize(14);
    m_font.setStyleHint(QFont::Monospace);
    // Kerning and letter-spacing tricks are for prose. A terminal is a
    // grid, and a character that advances by anything other than one cell
    // puts the rest of the line in the wrong place.
    m_font.setKerning(false);
    m_font.setFixedPitch(true);
    remeasure();
}

void TermView::setTerm(Term *t) {
    if (m_term == t) return;
    if (m_term) m_term->disconnect(this);
    m_term = t;
    if (m_term) {
        connect(m_term, &Term::damaged, this, [this] { update(); });
        connect(m_term, &Term::cursorChanged, this, [this] { update(); });
        connect(m_term, &Term::scrollOffsetChanged, this, [this] { update(); });
        relayout();
    }
    emit termChanged();
    update();
}

void TermView::setFontFamily(const QString &f) {
    if (f.isEmpty() || f == m_font.family()) return;
    m_font.setFamily(f);
    remeasure();
}

void TermView::setFontSize(qreal px) {
    if (px <= 0 || qFuzzyCompare(px, static_cast<qreal>(m_font.pixelSize()))) return;
    m_font.setPixelSize(qRound(px));
    remeasure();
}

void TermView::setLineHeight(qreal h) {
    if (h <= 0 || qFuzzyCompare(h, m_lineHeight)) return;
    m_lineHeight = h;
    remeasure();
}

void TermView::setFocused(bool f) {
    if (f == m_focused) return;
    m_focused = f;
    emit focusedChanged();
    update();
}

void TermView::remeasure() {
    const QFontMetricsF fm(m_font);
    // The advance of a wide-but-ordinary glyph, not averageCharWidth():
    // on a font that is not really monospaced the average is a fraction
    // of a pixel out, and a fraction of a pixel times eighty columns is
    // a visibly ragged right edge.
    // Rounded to whole pixels. A fractional cell leaves a seam between
    // one cell and the next — invisible in prose, and a broken line
    // wherever box-drawing characters are supposed to join up.
    m_cellW = qMax<qreal>(1, qRound(fm.horizontalAdvance(QStringLiteral("M"))));
    m_cellH = qMax<qreal>(1, qRound(fm.height() * m_lineHeight));
    m_baseline = (m_cellH - fm.height()) / 2 + fm.ascent();
    // What a line drawn here should weigh, taken from the font so that a
    // frame looks like it belongs to the text inside it. The underline
    // position is the closest thing a font says about its own stems.
    m_stemWidth = qMax<qreal>(1, qRound(fm.lineWidth() > 0 ? fm.lineWidth()
                                                           : m_font.pixelSize() / 14.0));
    emit fontChanged();
    relayout();
    update();
}

void TermView::relayout() {
    if (!m_term || m_cellW <= 0 || m_cellH <= 0) return;
    const int cols = qMax(1, static_cast<int>(width() / m_cellW));
    const int rows = qMax(1, static_cast<int>(height() / m_cellH));
    m_term->setSize(rows, cols);
}

void TermView::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) {
    QQuickPaintedItem::geometryChange(newGeometry, oldGeometry);
    relayout();
}

void TermView::paint(QPainter *painter) {
    if (!m_term) {
        painter->fillRect(QRectF(0, 0, width(), height()), QColor("#1a1a18"));
        return;
    }

    const QColor defaultBg = m_term->defaultBg();
    painter->fillRect(QRectF(0, 0, width(), height()), defaultBg);
    painter->setFont(m_font);

    const int rows = qMin(m_term->rows() + m_term->scrollOffset(),
                          static_cast<int>(height() / m_cellH) + 1);
    const int cols = m_term->cols();

    // Runs, not cells.
    //
    // Every cell painted on its own would be eighty drawText calls a line
    // and as many fills, for a line that is usually one colour. A run is
    // extended while the colours and the weight hold, and drawn when they
    // change — which for ordinary output is once or twice a line.
    for (int row = 0; row < rows; ++row) {
        const qreal y = row * m_cellH;
        if (y > height()) break;

        int col = 0;
        while (col < cols) {
            VTermScreenCell cell;
            if (!m_term->cellAt(row, col, &cell)) { col++; continue; }

            const bool selected = inSelection(row, col);
            QColor fg = m_term->toColor(cell.fg, false);
            QColor bg = m_term->toColor(cell.bg, true);
            if (cell.attrs.reverse) std::swap(fg, bg);
            if (cell.attrs.conceal) fg = bg;

            QString run;
            QVector<int> widths;    // cells per entry in the run
            const int runStart = col;
            int width = 0;
            // Collect while everything that affects how it is drawn holds.
            while (col < cols) {
                VTermScreenCell next;
                if (!m_term->cellAt(row, col, &next)) break;
                QColor nfg = m_term->toColor(next.fg, false);
                QColor nbg = m_term->toColor(next.bg, true);
                if (next.attrs.reverse) std::swap(nfg, nbg);
                if (next.attrs.conceal) nfg = nbg;
                if (nfg != fg || nbg != bg
                    || next.attrs.bold != cell.attrs.bold
                    || next.attrs.italic != cell.attrs.italic
                    || next.attrs.underline != cell.attrs.underline
                    || next.attrs.strike != cell.attrs.strike
                    || inSelection(row, col) != selected)
                    break;

                const int w = next.width > 0 ? next.width : 1;
                QString glyph;
                if (next.chars[0] == 0) glyph = QStringLiteral(" ");
                else for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && next.chars[i]; ++i)
                    glyph.append(QString::fromUcs4(&next.chars[i], 1));
                run.append(glyph);
                // What each entry in the run is worth, in cells. A CJK
                // character is two, and drawing it as one put every
                // glyph after it half a cell to the left — the line
                // ended up a compressed smear rather than a row.
                widths.append(w);
                width += w;
                col += w;
            }
            if (width == 0) { col++; continue; }

            const QRectF cellRect(runStart * m_cellW, y, width * m_cellW, m_cellH);
            if (selected) {
                painter->fillRect(cellRect, m_selectionColor);
            } else if (bg != defaultBg) {
                painter->fillRect(cellRect, bg);
            }

            if (!run.trimmed().isEmpty()) {
                QFont f = m_font;
                if (cell.attrs.bold) f.setBold(true);
                if (cell.attrs.italic) f.setItalic(true);
                if (cell.attrs.underline != VTERM_UNDERLINE_OFF) f.setUnderline(true);
                if (cell.attrs.strike) f.setStrikeOut(true);
                painter->setFont(f);
                painter->setPen(fg);
                // Drawn glyph by glyph at exact cell positions rather than
                // as one string: a font that is not perfectly monospaced —
                // and a line with a box-drawing character or an emoji in it
                // never is — would otherwise drift out of the grid and take
                // the rest of the line with it.
                qreal x = runStart * m_cellW;
                int idx = 0;
                for (int i = 0; i < run.size() && idx < widths.size(); ) {
                    // One cell's worth of text may be several code points
                    // — a letter and its combining accent — and is drawn
                    // as one glyph in one cell.
                    int len = 1;
                    while (i + len < run.size() && run.at(i + len).isMark()) len++;
                    const QString piece = run.mid(i, len);
                    const int cells = widths.at(idx);
                    const QList<uint> ucs = piece.toUcs4();
                    if (ucs.size() == 1 && BoxDraw::handles(ucs.first())) {
                        // Drawn from the cell's geometry rather than set
                        // in the font, so frames join. See boxdraw.cpp.
                        BoxDraw::draw(painter,
                                      QRectF(x, y, cells * m_cellW, m_cellH),
                                      ucs.first(), fg, m_stemWidth);
                    } else if (cells > 1) {
                        // Centred in the cells it owns: a wide glyph that
                        // does not quite fill two cells looks wrong jammed
                        // against the left of them.
                        const qreal advance = QFontMetricsF(painter->font()).horizontalAdvance(piece);
                        painter->drawText(QPointF(x + (cells * m_cellW - advance) / 2,
                                                  y + m_baseline), piece);
                    } else {
                        painter->drawText(QPointF(x, y + m_baseline), piece);
                    }
                    x += cells * m_cellW;
                    i += len;
                    idx++;
                }
            }
        }
    }

    // The cursor, on the live screen only: a block where it is, hollow
    // when the window does not have the keyboard, which is how you tell
    // at a glance whether typing will go here.
    if (m_term->cursorVisible() && m_term->scrollOffset() == 0) {
        const QRectF c(m_term->cursorCol() * m_cellW,
                       m_term->cursorRow() * m_cellH, m_cellW, m_cellH);
        if (m_focused) {
            painter->save();
            painter->setCompositionMode(QPainter::CompositionMode_Difference);
            painter->fillRect(c, Qt::white);
            painter->restore();
        } else {
            painter->setPen(m_cursorColor);
            painter->drawRect(c.adjusted(0.5, 0.5, -0.5, -0.5));
        }
    }
}

// ── selection ────────────────────────────────────────────────────────────
void TermView::cellFor(const QPointF &p, int *row, int *col) const {
    *row = qBound(0, static_cast<int>(p.y() / m_cellH),
                  m_term ? m_term->rows() + m_term->scrollOffset() - 1 : 0);
    *col = qBound(0, static_cast<int>(p.x() / m_cellW),
                  m_term ? m_term->cols() - 1 : 0);
}

bool TermView::inSelection(int row, int col) const {
    if (!m_hasSelection) return false;
    int r0 = m_selRow0, c0 = m_selCol0, r1 = m_selRow1, c1 = m_selCol1;
    if (r1 < r0 || (r1 == r0 && c1 < c0)) { std::swap(r0, r1); std::swap(c0, c1); }
    if (row < r0 || row > r1) return false;
    if (row == r0 && col < c0) return false;
    if (row == r1 && col > c1) return false;
    return true;
}

QString TermView::selectedText() const {
    if (!m_hasSelection || !m_term) return QString();
    return m_term->textOfRange(m_selRow0, m_selCol0, m_selRow1, m_selCol1);
}

void TermView::clearSelection() {
    if (!m_hasSelection) return;
    m_hasSelection = false;
    emit selectionChanged();
    update();
}

void TermView::selectAll() {
    if (!m_term) return;
    m_selRow0 = 0; m_selCol0 = 0;
    m_selRow1 = m_term->rows() + m_term->scrollOffset() - 1;
    m_selCol1 = m_term->cols() - 1;
    m_hasSelection = true;
    emit selectionChanged();
    update();
}

void TermView::mousePressEvent(QMouseEvent *event) {
    forceActiveFocus();
    if (event->button() == Qt::MiddleButton) {
        // The primary selection, pasted — the oldest gesture on this
        // desktop and the one people miss most when it is absent.
        const QString text =
            QGuiApplication::clipboard()->text(QClipboard::Selection);
        if (m_term && !text.isEmpty()) m_term->sendText(text);
        event->accept();
        return;
    }
    cellFor(event->position(), &m_selRow0, &m_selCol0);
    m_selRow1 = m_selRow0;
    m_selCol1 = m_selCol0;
    m_selecting = true;
    if (m_hasSelection) { m_hasSelection = false; emit selectionChanged(); update(); }
    event->accept();
}

void TermView::mouseMoveEvent(QMouseEvent *event) {
    if (!m_selecting) return;
    cellFor(event->position(), &m_selRow1, &m_selCol1);
    const bool had = m_hasSelection;
    m_hasSelection = (m_selRow1 != m_selRow0 || m_selCol1 != m_selCol0);
    if (had != m_hasSelection) emit selectionChanged();
    update();
    event->accept();
}

void TermView::mouseReleaseEvent(QMouseEvent *event) {
    m_selecting = false;
    if (m_hasSelection) {
        // Selecting puts it on the primary selection, which is what the
        // middle button pastes. Nothing is put on the clipboard until
        // someone asks for it.
        QGuiApplication::clipboard()->setText(selectedText(), QClipboard::Selection);
    }
    event->accept();
}

void TermView::wheelEvent(QWheelEvent *event) {
    if (!m_term) return;
    const int steps = event->angleDelta().y() / 40;
    if (steps != 0) m_term->scrollBy(steps);
    event->accept();
}

void TermView::keyPressEvent(QKeyEvent *event) {
    if (!m_term) return;
    const Qt::KeyboardModifiers mods = event->modifiers();

    // The two bindings a terminal has to answer itself, because ^C and ^V
    // are already taken by the program on the other end.
    if ((mods & Qt::ControlModifier) && (mods & Qt::ShiftModifier)) {
        if (event->key() == Qt::Key_C) {
            if (m_hasSelection)
                QGuiApplication::clipboard()->setText(selectedText());
            event->accept();
            return;
        }
        if (event->key() == Qt::Key_V) {
            m_term->sendText(QGuiApplication::clipboard()->text());
            event->accept();
            return;
        }
        if (event->key() == Qt::Key_A) { selectAll(); event->accept(); return; }
    }

    // Shift+PageUp/Down is scrollback everywhere else; it should be here.
    if ((mods & Qt::ShiftModifier)
        && (event->key() == Qt::Key_PageUp || event->key() == Qt::Key_PageDown)) {
        m_term->scrollBy(event->key() == Qt::Key_PageUp ? m_term->rows() / 2
                                                        : -m_term->rows() / 2);
        event->accept();
        return;
    }

    if (m_hasSelection) clearSelection();
    m_term->sendKey(event->key(), static_cast<int>(mods), event->text());
    event->accept();
}
