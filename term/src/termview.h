#pragma once

#include <QColor>
#include <QFont>
#include <QQuickPaintedItem>
#include <QElapsedTimer>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

#include "term.h"

// The grid, drawn.
//
// QPainter rather than a scene-graph node of its own: a terminal is a
// few thousand cells of text, and the thing that makes it fast is not
// the drawing API but coalescing cells into runs that share a colour and
// a weight. That is done here, and it is why a screenful of `ls` output
// is a handful of drawText calls rather than one per character.
//
// The item owns the grid's geometry: the cell size comes from the font's
// metrics, and the number of rows and columns from the item's size, so
// resizing the window is what resizes the terminal.
class TermView : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(Term *term READ term WRITE setTerm NOTIFY termChanged)
    Q_PROPERTY(QString fontFamily READ fontFamily WRITE setFontFamily NOTIFY fontChanged)
    Q_PROPERTY(qreal fontSize READ fontSize WRITE setFontSize NOTIFY fontChanged)
    Q_PROPERTY(qreal lineHeight READ lineHeight WRITE setLineHeight NOTIFY fontChanged)
    Q_PROPERTY(QColor selectionColor MEMBER m_selectionColor NOTIFY paletteChanged)
    Q_PROPERTY(QColor cursorColor MEMBER m_cursorColor NOTIFY paletteChanged)
    Q_PROPERTY(bool focused READ focused WRITE setFocused NOTIFY focusedChanged)
    Q_PROPERTY(qreal cellWidth READ cellWidth NOTIFY fontChanged)
    Q_PROPERTY(qreal cellHeight READ cellHeight NOTIFY fontChanged)
    Q_PROPERTY(bool hasSelection READ hasSelection NOTIFY selectionChanged)
    // The grid this item's size works out to. Every session in the window
    // is kept at this size, not only the one on screen: a program in a
    // background tab that thinks the window is still 80x24 redraws itself
    // wrongly the moment you switch back to it.
    Q_PROPERTY(int rows READ rows NOTIFY gridChanged)
    Q_PROPERTY(int cols READ cols NOTIFY gridChanged)

public:
    explicit TermView(QQuickItem *parent = nullptr);

    void paint(QPainter *painter) override;

    Term *term() const { return m_term; }
    void setTerm(Term *t);

    QString fontFamily() const { return m_font.family(); }
    void setFontFamily(const QString &f);
    qreal fontSize() const { return m_font.pointSizeF() > 0 ? m_font.pointSizeF()
                                                            : m_font.pixelSize(); }
    void setFontSize(qreal px);
    qreal lineHeight() const { return m_lineHeight; }
    void setLineHeight(qreal h);

    bool focused() const { return m_focused; }
    void setFocused(bool f);

    qreal cellWidth() const { return m_cellW; }
    qreal cellHeight() const { return m_cellH; }
    bool hasSelection() const { return m_hasSelection; }
    int rows() const { return m_rows; }
    int cols() const { return m_cols; }

    Q_INVOKABLE QString selectedText() const;
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void selectAll();

    // The same two things the keyboard shortcuts do, so the menu and the
    // shortcuts cannot drift apart — there is one copy and one paste.
    Q_INVOKABLE void copy();
    Q_INVOKABLE void paste();
    // What a paste would put in, so a menu can grey the entry out. Read
    // when the menu opens rather than watched: the clipboard is a shared
    // resource and polling it to keep a property warm means asking the
    // owning application for its contents on a timer.
    Q_INVOKABLE QString clipboardText() const;

signals:
    void termChanged();
    void fontChanged();
    void paletteChanged();
    void focusedChanged();
    void selectionChanged();
    void gridChanged();

    // Raised for the window to act on: a terminal's own tab keys are the
    // ones a program on the far side can never be given, because they are
    // how you get away from it.
    void newTabRequested();
    void closeTabRequested();
    void nextTabRequested();
    void previousTabRequested();
    void tabRequested(int index);

    // A right-click, in this item's coordinates. The menu is built in
    // QML, because it is a piece of the window's chrome and looks like
    // the rest of it.
    void contextMenuRequested(qreal x, qreal y);

protected:
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void keyPressEvent(QKeyEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;

private:
    void remeasure();
    // Make the cursor solid and restart the blink from now.
    void wake();
    void relayout();
    // Cell under a point, as a line id and a column. For selection,
    // which has to outlive scrolling.
    void cellFor(const QPointF &p, qint64 *line, int *col) const;
    // The same point as a row of the view. For everything the program
    // on the far side is told about — mouse reports and cursor
    // placement are about where something is on screen now, and mean
    // nothing in terms of a line that scrolled past an hour ago.
    void viewCellFor(const QPointF &p, int *row, int *col) const;
    // Takes a view row, because that is what painting has.
    bool inSelection(int row, int col) const;
    // The pointer says what it does: an I-beam over text, an arrow when
    // a program has asked for the mouse and the pointer is its to use.
    void refreshCursor();
    // The far end of a drag follows whatever is under the pointer now.
    void extendSelection();
    // A drag held past the top or bottom edge scrolls, faster the further
    // out the pointer is, so a selection can run past what fits.
    void autoScrollTick();
    // Double-click: the word under the pointer; triple: the whole line.
    void selectWordAt(qint64 line, int col);
    void selectLineAt(qint64 line);

    // ── smooth scrolling ──
    // How far the text is drawn below where the grid's rows put it: the
    // part of a line the view is between two scroll positions, in pixels.
    qreal scrollShift() const;
    // Puts the view at `lines` up from the live screen, fractions and all;
    // the whole part is the terminal's own scroll offset.
    void scrollTo(qreal lines);
    // Glides there instead, as a wheel notch or Shift+PageUp does.
    void glideBy(qreal lines);
    void glideTick();

    // ── selecting from the keyboard ──
    // Shift with the arrows, Home and End; Ctrl with them goes by words or
    // to either end. Returns whether the key was taken.
    bool keySelect(int key, Qt::KeyboardModifiers mods);
    // A caret position — between characters, not on one — on a line.
    struct Caret { qint64 line; int col; };
    // The selection as an anchor and a moving caret (an editor's model),
    // and back to the cells it covers.
    void caretsFromSelection(Caret *anchor, Caret *caret) const;
    void selectBetween(Caret anchor, Caret caret);
    // Where the text on a line ends (trailing blanks are not text).
    int lineEnd(qint64 line) const;
    uint charOn(qint64 line, int col) const;
    // Scroll so that a line is on screen.
    void reveal(qint64 line);

    Term *m_term = nullptr;
    QFont m_font;
    qreal m_lineHeight = 1.35;
    qreal m_cellW = 8;
    qreal m_cellH = 16;
    qreal m_baseline = 12;
    qreal m_stemWidth = 1;
    qreal m_caretWidth = 2;
    QTimer m_blink;
    QElapsedTimer m_idle;
    bool m_blinkOn = true;
    bool m_focused = true;
    int m_rows = 0;
    int m_cols = 0;

    QColor m_selectionColor { 120, 160, 255, 90 };
    QColor m_cursorColor { "#ec3013" };

    bool m_hasSelection = false;
    bool m_selecting = false;
    // This press was forwarded to the program, so the release and any
    // movement in between belong to it as well.
    bool m_mouseToTerm = false;
    // Line ids, not view rows. A selection kept in view rows travels up
    // the screen as you scroll, because view row 4 is a different line
    // after every wheel click — see Term::lineIdFor.
    qint64 m_selRow0 = 0, m_selRow1 = 0;
    int m_selCol0 = 0, m_selCol1 = 0;
    // Where the pointer last was, so that scrolling in the middle of a
    // drag can extend the selection to whatever is now under it without
    // waiting for the mouse to move.
    QPointF m_lastPointer;
    QTimer m_autoScroll;
    // Smooth scrolling: where the view is (lines up from the live screen,
    // fractional), where it is gliding to, and the glide's clock.
    qreal m_pos = 0;
    qreal m_target = 0;
    QTimer m_glide;
    QElapsedTimer m_glideClock;
    bool m_movingOffset = false;
    // Where a keyboard selection was started: its fixed end.
    // and its moving end — kept, not worked out again from the cells,
    // which can't say which side of a one-character selection it is on.
    Caret m_kbAnchor { 0, 0 };
    Caret m_kbCaret { 0, 0 };
    bool m_kbActive = false;
    // Clicks in quick succession on the same spot: 1, 2 (word), 3 (line).
    int m_clicks = 0;
    QElapsedTimer m_lastClick;
    QPointF m_lastClickPos;
};
