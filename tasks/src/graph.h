#pragma once

#include <QColor>
#include <QElapsedTimer>
#include <QPointer>
#include <QQuickPaintedItem>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

#include "monitor.h"

// A history graph: one series (or two — read and write, received and sent)
// from Monitor, drawn as a filled line.
//
// Between samples it slides left at the display's own rate rather than
// jumping once a second, the newest point coming in from the right edge
// over the interval: the "60 Hz" meters. That costs a repaint per frame
// while it is on screen, so it can be turned off (`animate`), and it only
// runs while the graph is visible and something is moving.
//
// Given `values` instead of a source, it draws those — the flight
// recorder's replay.
class Graph : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(Monitor *source READ source WRITE setSource NOTIFY changed)
    Q_PROPERTY(QString series READ series WRITE setSeries NOTIFY changed)
    Q_PROPERTY(QString series2 READ series2 WRITE setSeries2 NOTIFY changed)
    Q_PROPERTY(QVariantList values READ values WRITE setValues NOTIFY changed)
    Q_PROPERTY(QVariantList values2 READ values2 WRITE setValues2 NOTIFY changed)
    Q_PROPERTY(qreal maxValue READ maxValue WRITE setMaxValue NOTIFY changed)
    Q_PROPERTY(qreal minScale READ minScale WRITE setMinScale NOTIFY changed)
    Q_PROPERTY(qreal scaleMax READ scaleMax NOTIFY scaleChanged)
    Q_PROPERTY(int points READ points WRITE setPoints NOTIFY changed)
    Q_PROPERTY(bool animate READ animate WRITE setAnimate NOTIFY changed)
    Q_PROPERTY(bool grid READ grid WRITE setGrid NOTIFY changed)
    Q_PROPERTY(bool fill READ fill WRITE setFill NOTIFY changed)
    Q_PROPERTY(qreal lineWidth READ lineWidth WRITE setLineWidth NOTIFY changed)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY changed)
    Q_PROPERTY(QColor color2 READ color2 WRITE setColor2 NOTIFY changed)
    Q_PROPERTY(QColor gridColor READ gridColor WRITE setGridColor NOTIFY changed)

public:
    explicit Graph(QQuickItem *parent = nullptr);

    void paint(QPainter *p) override;

    Monitor *source() const { return m_source; }
    void setSource(Monitor *m);
    QString series() const { return m_series; }
    void setSeries(const QString &s) { if (s != m_series) { m_series = s; update(); emit changed(); } }
    QString series2() const { return m_series2; }
    void setSeries2(const QString &s) { if (s != m_series2) { m_series2 = s; update(); emit changed(); } }
    QVariantList values() const { return m_values; }
    void setValues(const QVariantList &v) { m_values = v; update(); emit changed(); }
    QVariantList values2() const { return m_values2; }
    void setValues2(const QVariantList &v) { m_values2 = v; update(); emit changed(); }
    qreal maxValue() const { return m_max; }
    void setMaxValue(qreal v) { if (v != m_max) { m_max = v; update(); emit changed(); } }
    qreal minScale() const { return m_minScale; }
    void setMinScale(qreal v) { if (v != m_minScale) { m_minScale = v; update(); emit changed(); } }
    qreal scaleMax() const { return m_scale; }
    int points() const { return m_points; }
    void setPoints(int n) { n = qMax(2, n); if (n != m_points) { m_points = n; update(); emit changed(); } }
    bool animate() const { return m_animate; }
    void setAnimate(bool a) { if (a != m_animate) { m_animate = a; update(); emit changed(); } }
    bool grid() const { return m_grid; }
    void setGrid(bool g) { if (g != m_grid) { m_grid = g; update(); emit changed(); } }
    bool fill() const { return m_fill; }
    void setFill(bool f) { if (f != m_fill) { m_fill = f; update(); emit changed(); } }
    qreal lineWidth() const { return m_lineWidth; }
    void setLineWidth(qreal w) { if (w != m_lineWidth) { m_lineWidth = w; update(); emit changed(); } }
    QColor color() const { return m_color; }
    void setColor(const QColor &c) { if (c != m_color) { m_color = c; update(); emit changed(); } }
    QColor color2() const { return m_color2; }
    void setColor2(const QColor &c) { if (c != m_color2) { m_color2 = c; update(); emit changed(); } }
    QColor gridColor() const { return m_gridColor; }
    void setGridColor(const QColor &c) { if (c != m_gridColor) { m_gridColor = c; update(); emit changed(); } }

signals:
    void changed();
    void scaleChanged();

protected:
    void itemChange(ItemChange change, const ItemChangeData &value) override;

private:
    void onSampled();
    void onFrame();
    double phase() const;
    QVector<float> data(const QString &key) const;

    QPointer<Monitor> m_source;
    QString m_series, m_series2;
    QVariantList m_values, m_values2;
    qreal m_max = 0, m_minScale = 1, m_scale = 1;
    int m_points = 60;
    bool m_animate = true, m_grid = true, m_fill = true;
    qreal m_lineWidth = 1.5;
    QColor m_color = QColor("#ec3013"), m_color2 = QColor("#ec3013"), m_gridColor = QColor(128, 128, 128, 40);
    QElapsedTimer m_since;
    QMetaObject::Connection m_frameConn;
};
