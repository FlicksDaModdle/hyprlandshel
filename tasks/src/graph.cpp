#include "graph.h"

#include "monitor.h"

#include <QPainter>
#include <QPainterPath>
#include <QQuickWindow>

#include <cmath>

Graph::Graph(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAntialiasing(true);
    setOpaquePainting(false);
    m_since.start();
}

void Graph::setSource(Monitor *m) {
    if (m == m_source) return;
    if (m_source) disconnect(m_source, nullptr, this, nullptr);
    m_source = m;
    if (m_source) connect(m_source, &Monitor::updated, this, &Graph::onSampled);
    update();
    emit changed();
}

void Graph::onSampled() {
    m_since.restart();
    if (isVisible()) update();
}

// Each frame while the newest point is still sliding in.
void Graph::onFrame() {
    if (m_animate && isVisible() && m_source && phase() < 1.0) update();
}

void Graph::itemChange(ItemChange change, const ItemChangeData &value) {
    if (change == ItemSceneChange) {
        disconnect(m_frameConn);
        if (value.window)
            m_frameConn = connect(value.window, &QQuickWindow::afterAnimating, this, &Graph::onFrame);
    } else if (change == ItemVisibleHasChanged && value.boolValue) {
        update();
    }
    QQuickPaintedItem::itemChange(change, value);
}

double Graph::phase() const {
    if (!m_animate || !m_source) return 1.0;
    return qBound(0.0, double(m_since.elapsed()) / double(qMax(1, m_source->interval())), 1.0);
}

QVector<float> Graph::data(const QString &key) const {
    if (!m_source) {
        QVector<float> v;
        const QVariantList &src = key == m_series2 && !m_series2.isEmpty() ? m_values2 : m_values;
        for (const QVariant &x : src) v << x.toFloat();
        return v;
    }
    return m_source->series(key);
}

namespace {
// The next round number above v: 1, 2, 5, 10, 20, 50…
double niceAbove(double v) {
    if (v <= 0) return 1;
    const double e = std::pow(10.0, std::floor(std::log10(v)));
    for (double m : {1.0, 2.0, 2.5, 5.0, 10.0}) if (m * e >= v) return m * e;
    return 10 * e;
}
} // namespace

void Graph::paint(QPainter *p) {
    const double w = width(), h = height();
    if (w < 2 || h < 2) return;
    p->setRenderHint(QPainter::Antialiasing, true);

    const QVector<float> a = data(m_series);
    const QVector<float> b = m_series2.isEmpty() ? QVector<float>() : data(m_series2);
    const double ph = phase();
    const int n = m_points;
    const double step = w / double(n - 1);
    const double shift = (1.0 - ph) * step;

    // The scale: fixed, or the visible maximum rounded up to something
    // that reads well on an axis.
    double scale = m_max;
    if (scale <= 0) {
        double peak = 0;
        for (int i = qMax(0, a.size() - n - 1); i < a.size(); ++i) peak = qMax(peak, double(a[i]));
        for (int i = qMax(0, b.size() - n - 1); i < b.size(); ++i) peak = qMax(peak, double(b[i]));
        scale = niceAbove(qMax(m_minScale, peak * 1.08));
    }
    if (!qFuzzyCompare(scale, m_scale)) { m_scale = scale; QMetaObject::invokeMethod(this, "scaleChanged", Qt::QueuedConnection); }

    if (m_grid) {
        p->setPen(QPen(m_gridColor, 1));
        for (int i = 1; i < 4; ++i) {
            const double y = std::round(h * i / 4.0) + 0.5;
            p->drawLine(QPointF(0, y), QPointF(w, y));
        }
        // Vertical lines that travel with the data, every ten samples.
        const quint64 ticks = m_source ? m_source->ticks() : 0;
        const int phaseCol = int(ticks % 10);
        for (int k = 0; k <= n / 10 + 1; ++k) {
            const double x = w - (double(phaseCol) + 10.0 * k) * step + shift;
            if (x > 0 && x < w) p->drawLine(QPointF(std::round(x) + 0.5, 0), QPointF(std::round(x) + 0.5, h));
        }
    }

    auto line = [&](const QVector<float> &v, const QColor &c, bool dashed, bool filled) {
        if (v.isEmpty()) return;
        QPainterPath path;
        const int count = qMin(v.size(), n + 1);
        for (int j = 0; j < count; ++j) {
            const double x = w - j * step + shift;
            const double val = qBound(0.0, double(v[v.size() - 1 - j]), scale);
            const double y = h - (val / scale) * (h - m_lineWidth) - m_lineWidth / 2;
            if (j == 0) path.moveTo(x, y); else path.lineTo(x, y);
        }
        if (filled) {
            QPainterPath area = path;
            const double lastX = w - (count - 1) * step + shift;
            area.lineTo(lastX, h);
            area.lineTo(w + shift, h);
            area.closeSubpath();
            QLinearGradient g(0, 0, 0, h);
            QColor top = c, bottom = c;
            top.setAlphaF(0.28 * c.alphaF());
            bottom.setAlphaF(0.04 * c.alphaF());
            g.setColorAt(0, top);
            g.setColorAt(1, bottom);
            p->fillPath(area, g);
        }
        QPen pen(c, m_lineWidth);
        pen.setJoinStyle(Qt::RoundJoin);
        pen.setCapStyle(Qt::RoundCap);
        if (dashed) pen.setDashPattern({3, 2.5});
        p->strokePath(path, pen);
    };
    line(b, m_color2, true, false);
    line(a, m_color, false, m_fill);
}
