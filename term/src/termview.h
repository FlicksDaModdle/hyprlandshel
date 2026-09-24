#pragma once

#include <QColor>
#include <QFont>
#include <QQuickPaintedItem>
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

protected:
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void keyPressEvent(QKeyEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;

private:
    void remeasure();
    void relayout();
    // Cell under a point, clamped into the grid.
    void cellFor(const QPointF &p, int *row, int *col) const;
    bool inSelection(int row, int col) const;

    Term *m_term = nullptr;
    QFont m_font;
    qreal m_lineHeight = 1.35;
    qreal m_cellW = 8;
    qreal m_cellH = 16;
    qreal m_baseline = 12;
    qreal m_stemWidth = 1;
    bool m_focused = true;
    int m_rows = 0;
    int m_cols = 0;

    QColor m_selectionColor { 120, 160, 255, 90 };
    QColor m_cursorColor { "#ec3013" };

    bool m_hasSelection = false;
    bool m_selecting = false;
    int m_selRow0 = 0, m_selCol0 = 0, m_selRow1 = 0, m_selCol1 = 0;
};
