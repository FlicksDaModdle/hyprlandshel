#include "termview.h"
#include "boxdraw.h"

#include <QClipboard>
#include <QCursor>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPainter>
#include <QLineF>
#include <QStyleHints>
#include <QWheelEvent>

TermView::TermView(QQuickItem *parent) : QQuickPaintedItem(parent) {
    m_autoScroll.setInterval(40);
    connect(&m_autoScroll, &QTimer::timeout, this, &TermView::autoScrollTick);

    setFlag(ItemHasContents, true);
    // The right button too, for the context menu. A QQuickItem is only
    // sent the buttons it names here — the menu's press handler was
    // written and correct and simply never called, because the item was
    // not listening for that button.
    setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton | Qt::RightButton);
    // Hover events on, for the pointer shape.
    //
    // A QQuickItem's cursor is applied as the pointer moves over it, and
    // an item that accepts no hover events is not somewhere the window
    // looks. Nothing here handles hover for its own sake — there is no
    // override — so this costs an event nobody reads and buys an I-beam
    // that actually appears.
    setAcceptHoverEvents(true);
    setCursor(QCursor(Qt::IBeamCursor));
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

    // Half a second on, half a second off, which is roughly what every
    // text box on the desktop does. Off entirely when the program says so
    // — some ask for a steady cursor, and a full-screen program redrawing
    // under a blinking caret looks like a fault.
    m_blink.setInterval(530);
    connect(&m_blink, &QTimer::timeout, this, [this] {
        if (!m_term || !m_term->cursorBlink() || !m_focused) {
            m_blinkOn = true;
            m_blink.stop();
            update();
            return;
        }
        // It stops blinking once you have stopped working.
        //
        // A caret that blinks for ever is a thing moving in the corner of
        // your eye in a window you are only reading. Ten seconds after
        // the last keystroke it goes solid and stays there — still
        // visible, still saying where typing would go, no longer asking
        // for attention. The next key starts it again.
        if (m_idle.hasExpired(10000)) {
            m_blinkOn = true;
            m_blink.stop();
            update();
            return;
        }
        m_blinkOn = !m_blinkOn;
        update();
    });

    remeasure();
}

// Solid, and counting again from now.
void TermView::wake() {
    m_blinkOn = true;
    m_idle.restart();
    if (m_term && m_term->cursorBlink() && m_focused) m_blink.start();
    else m_blink.stop();
    update();
}

// An I-beam over text, an arrow once a program has asked for the mouse:
// in `less` or `htop` the pointer is a pointing device again, not a way
// of selecting words, and an I-beam there would be promising something
// that does not happen.
void TermView::refreshCursor() {
    setCursor(QCursor((m_term && m_term->mouseEnabled()) ? Qt::ArrowCursor
                                                         : Qt::IBeamCursor));
}

void TermView::setTerm(Term *t) {
    if (m_term == t) return;
    if (m_term) m_term->disconnect(this);
    m_term = t;
    if (m_term) {
        connect(m_term, &Term::damaged, this, [this] { update(); });
        // A cursor that moved is a cursor you are looking at: the blink
        // starts again from solid, the way a caret does when you type.
        connect(m_term, &Term::cursorChanged, this, [this] { wake(); });
        connect(m_term, &Term::cursorStyleChanged, this, [this] { wake(); });
        connect(m_term, &Term::scrollOffsetChanged, this, [this] { update(); });
        connect(m_term, &Term::mouseEnabledChanged, this,
                &TermView::refreshCursor);
        refreshCursor();
        relayout();
        wake();
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
    if (m_term) m_term->setFocused(f);
    emit focusedChanged();
    wake();
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
    // A caret, not a rule: thin enough to sit between two characters,
    // thick enough to see. Two pixels at the default size.
    m_caretWidth = qMax<qreal>(2, qRound(m_font.pixelSize() / 7.0));
    emit fontChanged();
    relayout();
    update();
}

void TermView::relayout() {
    if (m_cellW <= 0 || m_cellH <= 0) return;
    const int cols = qMax(1, static_cast<int>(width() / m_cellW));
    const int rows = qMax(1, static_cast<int>(height() / m_cellH));
    if (cols != m_cols || rows != m_rows) {
        m_cols = cols;
        m_rows = rows;
        emit gridChanged();
    }
    if (m_term) {
        m_term->setCellPixels(qRound(m_cellW), qRound(m_cellH));
        m_term->setSize(rows, cols);
    }
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
            HtCell cell;
            if (!m_term->cellAt(row, col, &cell)) { col++; continue; }

            const bool selected = inSelection(row, col);
            QColor fg = m_term->fgOf(cell);
            QColor bg = m_term->bgOf(cell);
            if (cell.reverse) std::swap(fg, bg);
            if (cell.conceal) fg = bg;

            QString run;
            QVector<int> widths;    // cells per entry in the run
            const int runStart = col;
            int width = 0;
            // Collect while everything that affects how it is drawn holds.
            while (col < cols) {
                HtCell next;
                if (!m_term->cellAt(row, col, &next)) break;
                QColor nfg = m_term->fgOf(next);
                QColor nbg = m_term->bgOf(next);
                if (next.reverse) std::swap(nfg, nbg);
                if (next.conceal) nfg = nbg;
                if (nfg != fg || nbg != bg
                    || next.bold != cell.bold
                    || next.italic != cell.italic
                    || next.underline != cell.underline
                    || next.strike != cell.strike
                    || inSelection(row, col) != selected)
                    break;

                const int w = next.width > 0 ? next.width : 1;
                QString glyph;
                if (next.chars[0] == 0) glyph = QStringLiteral(" ");
                else for (int i = 0; i < HT_MAX_CHARS && next.chars[i]; ++i)
                    glyph.append(QChar::fromUcs4(next.chars[i]));
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
                if (cell.bold) f.setBold(true);
                if (cell.italic) f.setItalic(true);
                if (cell.underline) f.setUnderline(true);
                if (cell.strike) f.setStrikeOut(true);
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

    // The cursor, on the live screen only.
    //
    // A thin bar at the left of the cell by default — a caret, sitting
    // between characters, which is where the next one goes and is what
    // every other text box on the machine draws. A block covers the
    // character it is on and says less. The program can still ask for
    // something else: vim wants a block in normal mode, where the cursor
    // really is *on* a character rather than between two.
    //
    // Hollow when the window does not have the keyboard, which is how you
    // tell at a glance whether typing will go here.
    if (m_term->cursorVisible() && m_term->scrollOffset() == 0 && m_blinkOn) {
        const QRectF cell(m_term->cursorCol() * m_cellW,
                          m_term->cursorRow() * m_cellH, m_cellW, m_cellH);
        const int shape = m_term->cursorShape();

        if (!m_focused) {
            // The same caret, dimmed — not a hollow block.
            //
            // A hollow block is the usual way to say "this window is not
            // where typing goes", but it is a thick rectangle around a
            // character, and drawing a thin cursor in one state and a fat
            // one in the other is the shape changing for a reason nobody
            // asked about. Dimmer says the same thing and stays a caret.
            QColor dim = m_cursorColor;
            dim.setAlphaF(0.45);
            if (shape == 1)
                painter->fillRect(cell, dim);
            else if (shape == 2)
                painter->fillRect(QRectF(cell.left(), cell.bottom() - m_caretWidth,
                                         cell.width(), m_caretWidth), dim);
            else
                painter->fillRect(QRectF(cell.left(), cell.top(),
                                         m_caretWidth, cell.height()), dim);
        } else if (shape == 1) {
            // A block, drawn by inverting what is under it, so the
            // character it covers stays readable.
            painter->save();
            painter->setCompositionMode(QPainter::CompositionMode_Difference);
            painter->fillRect(cell, Qt::white);
            painter->restore();
        } else if (shape == 2) {
            painter->fillRect(QRectF(cell.left(), cell.bottom() - m_caretWidth,
                                     cell.width(), m_caretWidth), m_cursorColor);
        } else {
            painter->fillRect(QRectF(cell.left(), cell.top(),
                                     m_caretWidth, cell.height()), m_cursorColor);
        }
    }
}

// ── selection ────────────────────────────────────────────────────────────
void TermView::viewCellFor(const QPointF &p, int *row, int *col) const {
    if (!m_term) { *row = 0; *col = 0; return; }
    *row = qBound(0, static_cast<int>(p.y() / m_cellH),
                  m_term->rows() + m_term->scrollOffset() - 1);
    *col = qBound(0, static_cast<int>(p.x() / m_cellW), m_term->cols() - 1);
}

void TermView::cellFor(const QPointF &p, qint64 *line, int *col) const {
    if (!m_term) { *line = 0; *col = 0; return; }
    const int viewRow = qBound(0, static_cast<int>(p.y() / m_cellH),
                               m_term->rows() + m_term->scrollOffset() - 1);
    *line = qBound(m_term->firstLineId(), m_term->lineIdFor(viewRow),
                   m_term->lastLineId());
    *col = qBound(0, static_cast<int>(p.x() / m_cellW), m_term->cols() - 1);
}

bool TermView::inSelection(int row, int col) const {
    if (!m_hasSelection || !m_term) return false;
    // `row` is where the line is now; the selection is which lines.
    const qint64 id = m_term->lineIdFor(row);
    qint64 r0 = m_selRow0, r1 = m_selRow1;
    int c0 = m_selCol0, c1 = m_selCol1;
    if (r1 < r0 || (r1 == r0 && c1 < c0)) { std::swap(r0, r1); std::swap(c0, c1); }
    if (id < r0 || id > r1) return false;
    if (id == r0 && col < c0) return false;
    if (id == r1 && col > c1) return false;
    return true;
}

QString TermView::selectedText() const {
    // HYPRSHELL_TERM_SELLOG=1 prints what is selected and where.
    //
    // A selection is two numbers and a highlight, and a highlight looks
    // the same whichever line it is on — so "the selection moved when I
    // scrolled" cannot be told from "it did not" by looking. This says
    // which lines, by id, and what scrolling state they were read in.
    if (qEnvironmentVariableIsSet("HYPRSHELL_TERM_SELLOG") && m_term)
        fprintf(stderr, "[sel] lines %lld:%d..%lld:%d  view=%d off=%d sb=%d\n",
                (long long) m_selRow0, m_selCol0, (long long) m_selRow1, m_selCol1,
                m_term->viewRowFor(m_selRow0), m_term->scrollOffset(),
                m_term->scrollbackLines());

    if (!m_hasSelection || !m_term) return QString();
    return m_term->textOfLines(m_selRow0, m_selCol0, m_selRow1, m_selCol1);
}

void TermView::clearSelection() {
    if (!m_hasSelection) return;
    m_hasSelection = false;
    emit selectionChanged();
    update();
}

void TermView::selectAll() {
    if (!m_term) return;
    m_selRow0 = m_term->firstLineId(); m_selCol0 = 0;
    m_selRow1 = m_term->lastLineId();
    m_selCol1 = m_term->cols() - 1;
    m_hasSelection = true;
    emit selectionChanged();
    update();
}

void TermView::mousePressEvent(QMouseEvent *event) {
    forceActiveFocus();

    // A program that asked for the mouse gets the mouse. vim, less and
    // htop all do, and inventing arrow keys for them would be answering a
    // question they did not ask.
    // Shift is the way past that: a program can have the mouse and you
    // can still select its text, as in every other terminal.
    if (m_term && m_term->mouseEnabled() && event->button() == Qt::LeftButton
        && !(event->modifiers() & Qt::ShiftModifier)) {
        int row, col;
        viewCellFor(event->position(), &row, &col);
        m_term->sendMouse(row, col, 1, true, static_cast<int>(event->modifiers()));
        m_mouseToTerm = true;
        event->accept();
        return;
    }
    m_mouseToTerm = false;

    if (event->button() == Qt::RightButton) {
        // The selection is left exactly as it is: the first thing most
        // people do with this menu is right-click text they have just
        // dragged over and choose Copy, and starting a fresh selection
        // under the pointer — which is what the code below does — would
        // throw away what they meant to copy.
        //
        // It is not forwarded to a program that asked for the mouse,
        // unlike the left button. Nothing was forwarding it before
        // either, so no program loses anything, and a menu that appears
        // everywhere except inside vim would be worse than one that does
        // not appear at all.
        emit contextMenuRequested(event->position().x(), event->position().y());
        event->accept();
        return;
    }

    if (event->button() == Qt::MiddleButton) {
        // The primary selection, pasted — the oldest gesture on this
        // desktop and the one people miss most when it is absent.
        const QString text =
            QGuiApplication::clipboard()->text(QClipboard::Selection);
        if (m_term && !text.isEmpty()) m_term->paste(text);
        event->accept();
        return;
    }
    if (event->button() != Qt::LeftButton) { event->ignore(); return; }

    // Counting clicks here rather than trusting double-click events: a
    // triple click has no event of its own.
    const QPointF pos = event->position();
    const bool quick = m_lastClick.isValid()
        && m_lastClick.elapsed() < QGuiApplication::styleHints()->mouseDoubleClickInterval()
        && QLineF(pos, m_lastClickPos).length() < 6;
    m_clicks = quick ? (m_clicks % 3) + 1 : 1;
    m_lastClick.start();
    m_lastClickPos = pos;

    m_lastPointer = pos;
    qint64 line; int col;
    cellFor(pos, &line, &col);
    if (m_clicks == 2) { selectWordAt(line, col); event->accept(); return; }
    if (m_clicks == 3) { selectLineAt(line); event->accept(); return; }

    m_selRow0 = m_selRow1 = line;
    m_selCol0 = m_selCol1 = col;
    m_selecting = true;
    if (m_hasSelection) { m_hasSelection = false; emit selectionChanged(); update(); }
    event->accept();
}

// ── selecting by word and line, and past the edges ──────────────────────
void TermView::extendSelection() {
    // Kept inside the grid: the pointer may be well above or below it
    // during an auto-scroll, and the end of the selection is then the
    // first or last visible line.
    const QPointF p(m_lastPointer.x(), qBound(0.0, m_lastPointer.y(), height() - 1));
    cellFor(p, &m_selRow1, &m_selCol1);
    const bool had = m_hasSelection;
    m_hasSelection = (m_selRow1 != m_selRow0 || m_selCol1 != m_selCol0);
    if (had != m_hasSelection) emit selectionChanged();
    update();
}

void TermView::autoScrollTick() {
    if (!m_selecting || !m_term) { m_autoScroll.stop(); return; }
    const qreal y = m_lastPointer.y();
    const qreal over = y < 0 ? -y : y - height();
    if (over <= 0) { m_autoScroll.stop(); return; }
    // A line a tick just past the edge, up to a screenful a second and
    // more the further out the hand goes.
    const int lines = qBound(1, 1 + static_cast<int>(over / qMax<qreal>(m_cellH, 1)), 12);
    m_term->scrollBy(y < 0 ? lines : -lines);
    extendSelection();
}

// What a double-click takes as one word: anything but spaces and the
// brackets and quotes around things. Paths, URLs, flags and addresses
// come out whole — they are what people double-click in a terminal.
static bool isWordChar(uint c) {
    if (c == 0 || c == ' ' || c == '\t') return false;
    static const QString breaks = QStringLiteral("()[]{}<>\"'`|,;");
    return c > 0xffff || !breaks.contains(QChar(static_cast<char16_t>(c)));
}

void TermView::selectWordAt(qint64 line, int col) {
    if (!m_term) return;
    const int row = m_term->viewRowFor(line);
    const int cols = m_term->cols();
    auto charAt = [&](int c) -> uint {
        HtCell cell;
        if (!m_term->cellAt(row, c, &cell)) return 0;
        // The second half of a wide character belongs to the first.
        if (cell.width == 0 && c > 0 && m_term->cellAt(row, c - 1, &cell)) return cell.chars[0];
        return cell.chars[0];
    };
    if (!isWordChar(charAt(col))) { selectLineAt(-1); return; }
    int a = col, b = col;
    while (a > 0 && isWordChar(charAt(a - 1))) --a;
    while (b < cols - 1 && isWordChar(charAt(b + 1))) ++b;
    m_selRow0 = m_selRow1 = line;
    m_selCol0 = a;
    m_selCol1 = b;
    m_selecting = false;
    m_hasSelection = true;
    emit selectionChanged();
    QGuiApplication::clipboard()->setText(selectedText(), QClipboard::Selection);
    update();
}

void TermView::selectLineAt(qint64 line) {
    if (!m_term || line < 0) {
        if (m_hasSelection) { m_hasSelection = false; emit selectionChanged(); update(); }
        return;
    }
    m_selRow0 = m_selRow1 = line;
    m_selCol0 = 0;
    m_selCol1 = m_term->cols() - 1;
    m_selecting = false;
    m_hasSelection = true;
    emit selectionChanged();
    QGuiApplication::clipboard()->setText(selectedText(), QClipboard::Selection);
    update();
}

void TermView::mouseMoveEvent(QMouseEvent *event) {
    if (m_mouseToTerm) {
        if (!m_term) return;
        int row, col;
        viewCellFor(event->position(), &row, &col);
        m_term->sendMouse(row, col, 0, false, static_cast<int>(event->modifiers()));
        event->accept();
        return;
    }
    if (!m_selecting) return;
    m_lastPointer = event->position();
    extendSelection();
    // Past the top or bottom: keep going without the mouse having to.
    const qreal y = m_lastPointer.y();
    if ((y < 0 || y > height()) && !m_autoScroll.isActive()) {
        autoScrollTick();
        m_autoScroll.start();
    }
    event->accept();
}

void TermView::mouseReleaseEvent(QMouseEvent *event) {
    if (m_mouseToTerm) {
        if (m_term) {
            int row, col;
            viewCellFor(event->position(), &row, &col);
            m_term->sendMouse(row, col, 1, false, static_cast<int>(event->modifiers()));
        }
        m_mouseToTerm = false;
        event->accept();
        return;
    }

    m_autoScroll.stop();
    // A double or triple click has already chosen what it selects.
    if (!m_selecting) { event->accept(); return; }
    const bool dragged = m_hasSelection;
    m_selecting = false;
    if (dragged) {
        // Selecting puts it on the primary selection, which is what the
        // middle button pastes. Nothing is put on the clipboard until
        // someone asks for it.
        QGuiApplication::clipboard()->setText(selectedText(), QClipboard::Selection);
    } else if (m_term && event->button() == Qt::LeftButton) {
        // A click that did not become a drag is a click, and a click in a
        // line of text means "put the cursor here" everywhere else.
        int row, col;
        viewCellFor(event->position(), &row, &col);
        m_term->placeCursor(row, col);
    }
    event->accept();
}

void TermView::copy() {
    if (!m_hasSelection) return;
    QGuiApplication::clipboard()->setText(selectedText());
}

void TermView::paste() {
    if (!m_term) return;
    const QString text = QGuiApplication::clipboard()->text();
    if (!text.isEmpty()) m_term->paste(text);
}

QString TermView::clipboardText() const {
    return QGuiApplication::clipboard()->text();
}

void TermView::wheelEvent(QWheelEvent *event) {
    if (!m_term) return;
    const int steps = event->angleDelta().y() / 40;
    if (steps != 0) {
        m_term->scrollBy(steps);
        // Scrolling in the middle of a drag is "select more", so the far
        // end follows whatever has arrived under the pointer. Without
        // this it waits for the mouse to move, which it is not doing —
        // the hand is on the wheel.
        if (m_selecting) extendSelection();
    }
    event->accept();
}

void TermView::keyPressEvent(QKeyEvent *event) {
    if (!m_term) return;
    const Qt::KeyboardModifiers mods = event->modifiers();

    // Set HYPRSHELL_TERM_KEYLOG=1 to see what the widget is actually
    // given. Key bindings are the one part of this that cannot be read
    // off the screen: a shortcut that does nothing looks identical
    // whether it never arrived, arrived with different modifiers, or
    // arrived and was handled by something above.
    static const bool keylog = qEnvironmentVariableIsSet("HYPRSHELL_TERM_KEYLOG");
    if (keylog)
        fprintf(stderr, "[key] key=0x%x mods=0x%x text=%s sel=%d\n",
                event->key(), static_cast<unsigned>(mods),
                event->text().toUtf8().toPercentEncoding().constData(),
                int(m_hasSelection));

    // A modifier on its own is not a keystroke. It arrives here as a key
    // press like any other and, left alone, ran off the end of this
    // function — which clears the selection and sends the key to the
    // shell. So holding Ctrl to press Ctrl-Shift-C deleted the selection
    // before the C ever arrived, and the clipboard was set from nothing:
    //
    //   [key] key=Control mods=Ctrl       sel=1
    //   [key] key=Shift   mods=Ctrl|Shift sel=0   <- already gone
    //   [key] key=C       mods=Ctrl|Shift sel=0
    //
    // Every copy shortcut in the program was destroying the thing it was
    // about to copy.
    switch (event->key()) {
    case Qt::Key_Control:
    case Qt::Key_Shift:
    case Qt::Key_Alt:
    case Qt::Key_AltGr:
    case Qt::Key_Meta:
    case Qt::Key_Super_L:
    case Qt::Key_Super_R:
    case Qt::Key_Hyper_L:
    case Qt::Key_Hyper_R:
    case Qt::Key_CapsLock:
    case Qt::Key_NumLock:
    case Qt::Key_ScrollLock:
        event->accept();
        return;
    default:
        break;
    }

    // The two bindings a terminal has to answer itself, because ^C and ^V
    // are already taken by the program on the other end.
    // Ctrl-C with something selected copies it, and interrupts when
    // nothing is. ^C has to keep working — it is the only way to stop a
    // program — but a selection on screen is someone who has just
    // finished dragging over text, and for them ^C means copy. The
    // selection is cleared, so the next ^C interrupts.
    if ((mods & Qt::ControlModifier) && !(mods & Qt::ShiftModifier)
        && event->key() == Qt::Key_C && m_hasSelection) {
        copy();
        clearSelection();
        event->accept();
        return;
    }

    // Shift-Insert is the X11 paste, and it is what a great many people
    // still press.
    if ((mods & Qt::ShiftModifier) && event->key() == Qt::Key_Insert) {
        paste();
        event->accept();
        return;
    }

    if ((mods & Qt::ControlModifier) && (mods & Qt::ShiftModifier)) {
        switch (event->key()) {
        case Qt::Key_T: emit newTabRequested();      event->accept(); return;
        case Qt::Key_W: emit closeTabRequested();    event->accept(); return;
        case Qt::Key_Tab:
        case Qt::Key_Backtab: emit previousTabRequested(); event->accept(); return;
        default: break;
        }
        if (event->key() == Qt::Key_C) {
            copy();
            event->accept();
            return;
        }
        if (event->key() == Qt::Key_V) {
            paste();
            event->accept();
            return;
        }
        if (event->key() == Qt::Key_A) { selectAll(); event->accept(); return; }
    }

    if (mods & Qt::ControlModifier) {
        if (event->key() == Qt::Key_Tab) { emit nextTabRequested(); event->accept(); return; }
        if (event->key() == Qt::Key_PageDown) { emit nextTabRequested(); event->accept(); return; }
        if (event->key() == Qt::Key_PageUp) { emit previousTabRequested(); event->accept(); return; }
    }
    // Alt and a digit goes straight to that tab, counting from one, which
    // is where every browser and terminal puts it.
    if ((mods & Qt::AltModifier) && event->key() >= Qt::Key_1 && event->key() <= Qt::Key_9) {
        emit tabRequested(event->key() - Qt::Key_1);
        event->accept();
        return;
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
    wake();
    event->accept();
}
