#pragma once

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// The flight recorder: `hyprshell-tasks --record` samples the machine every
// few seconds in the background — as a systemd user service, so it runs
// whether or not this window is open — and writes one compact line per
// sample to a file per day in ~/.local/share/hyprshell-tasks/recorder.
// Afterwards the window replays a day, so a slowdown that has passed can
// still be scrubbed back to and looked at: what the processor, memory,
// disks and GPU were doing, how hot it was, and what was busiest.
//
// It also keeps App history's per-app totals across days.
class Recorder : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    Q_PROPERTY(bool running READ running NOTIFY changed)
    Q_PROPERTY(QVariantList days READ days NOTIFY changed)
    Q_PROPERTY(QVariantList appTotals READ appTotals NOTIFY changed)
    Q_PROPERTY(qint64 since READ since NOTIFY changed)
    Q_PROPERTY(int keepDays READ keepDays WRITE setKeepDays NOTIFY changed)

public:
    explicit Recorder(QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    bool running() const { return m_running; }
    QVariantList days() const { return m_days; }
    QVariantList appTotals() const { return m_apps; }
    qint64 since() const { return m_since; }
    int keepDays() const { return m_keep; }
    void setKeepDays(int d);

    // Install and start the service, or stop and remove it.
    Q_INVOKABLE void setEnabled(bool on);
    Q_INVOKABLE void refresh();
    // One day, between two times of it (ms since the epoch; 0 for all of
    // it), reduced to at most `buckets` points: { t: [], cpu: [], mem: [],
    // swap: [], psiCpu: [], psiMem: [], psiIo: [], diskRead: [], diskWrite:
    // [], netRx: [], netTx: [], gpu: [], temp: [], watts: [], top: [[name,
    // value], …] per point, topMem: … }. Each point is the bucket's
    // average, except `top`, which comes from its busiest sample.
    Q_INVOKABLE QVariantMap loadDay(const QString &day, qint64 from = 0, qint64 to = 0, int buckets = 600) const;

    static QString dir();
    // The recording process itself.
    static int run(int argc, char **argv);

signals:
    void changed();
    void actionDone(bool ok, const QString &message);

private:
    bool m_enabled = false, m_running = false;
    QVariantList m_days, m_apps;
    qint64 m_since = 0;
    int m_keep = 7;
};
