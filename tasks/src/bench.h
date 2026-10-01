#pragma once

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <atomic>

// Quick, repeatable benchmarks of this machine — processor (one thread and
// all of them), memory (bandwidth and latency) and a disk (sequential and
// 4K random) — each run on a thread of its own, with every result kept so
// a change (a new kernel, a power profile, a cleaned fan) shows up as a
// number against the last one.
class Bench : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString current READ current NOTIFY runningChanged)
    Q_PROPERTY(double progress READ progress NOTIFY progressChanged)
    Q_PROPERTY(QString stage READ stage NOTIFY progressChanged)
    Q_PROPERTY(QVariantList results READ results NOTIFY resultsChanged)

public:
    explicit Bench(QObject *parent = nullptr);
    ~Bench() override;

    bool running() const { return m_running; }
    QString current() const { return m_current; }
    double progress() const { return m_progress; }
    QString stage() const { return m_stage; }
    QVariantList results() const { return m_results; }

    // kind: "cpu" | "memory" | "disk"; for "disk", `path` is the folder to
    // write the test file in.
    Q_INVOKABLE void run(const QString &kind, const QString &path = QString());
    Q_INVOKABLE void cancel() { m_cancel = true; }
    Q_INVOKABLE void clearResults();

signals:
    void runningChanged();
    void progressChanged();
    void resultsChanged();
    void finished(const QVariantMap &result);
    void failed(const QString &message);

private:
    void setProgress(double p, const QString &stage);
    void save();
    QVariantMap cpu();
    QVariantMap memory();
    QVariantMap disk(const QString &path, QString *error);

    bool m_running = false;
    QString m_current, m_stage;
    double m_progress = 0;
    QVariantList m_results;
    std::atomic<bool> m_cancel{false};
};
