#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QtQml/qqmlregistration.h>

#include "procmodel.h"

class AppIndex;
class QLocalSocket;

// Everything the task manager shows about the machine, read from /proc and
// /sys once per interval: CPU (overall, per logical processor, frequencies,
// temperature), memory and pressure (PSI), every disk and network adapter,
// the GPUs, the battery, every temperature and fan the kernel reports, and
// the process list (ProcessModel), which it drives.
//
// Each value that can be graphed is also kept as a history — see history()
// and Graph — under a key like "cpu", "cpu/3", "mem", "disk/nvme0n1/read",
// "net/wlan0/rx", "gpu/0/busy", "bat/watts".
//
// Nothing here is privileged. A few things are only readable by root on
// most kernels (RAPL energy counters, other users' I/O counters) and are
// reported as unknown rather than guessed at.
class Monitor : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged)
    Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)
    Q_PROPERTY(int historySize READ historySize CONSTANT)
    Q_PROPERTY(qint64 sampledAt READ sampledAt NOTIFY updated)
    Q_PROPERTY(ProcessModel *processes READ processes CONSTANT)

    // CPU
    Q_PROPERTY(QVariantMap cpu READ cpu NOTIFY updated)
    Q_PROPERTY(QVariantList cores READ cores NOTIFY updated)
    // Memory, with pressure stall information
    Q_PROPERTY(QVariantMap memory READ memory NOTIFY updated)
    Q_PROPERTY(QVariantMap pressure READ pressure NOTIFY updated)
    // Devices
    Q_PROPERTY(QVariantList disks READ disks NOTIFY updated)
    Q_PROPERTY(QVariantList networks READ networks NOTIFY updated)
    Q_PROPERTY(QVariantList gpus READ gpus NOTIFY updated)
    Q_PROPERTY(QVariantMap battery READ battery NOTIFY updated)
    Q_PROPERTY(QVariantList sensors READ sensors NOTIFY updated)
    Q_PROPERTY(QVariantList fans READ fans NOTIFY updated)
    // Counts and the like
    Q_PROPERTY(QVariantMap system READ system NOTIFY updated)
    // Fixed facts: model names, cache sizes, the kernel, the board
    Q_PROPERTY(QVariantMap info READ info CONSTANT)
    // Hyprland's windows: [{ pid, class, title, address, workspace }]
    Q_PROPERTY(QVariantList windows READ windows NOTIFY windowsChanged)

public:
    explicit Monitor(QObject *parent = nullptr);
    ~Monitor() override;

    int interval() const { return m_interval; }
    void setInterval(int ms);
    bool paused() const { return m_paused; }
    void setPaused(bool p);
    int historySize() const { return kHistory; }
    qint64 sampledAt() const { return m_sampledAt; }
    quint64 ticks() const { return m_tick; }
    ProcessModel *processes() const { return m_procs; }
    AppIndex *apps() const { return m_apps; }

    QVariantMap cpu() const { return m_cpu; }
    QVariantList cores() const { return m_cores; }
    QVariantMap memory() const { return m_memory; }
    QVariantMap pressure() const { return m_pressure; }
    QVariantList disks() const { return m_disks; }
    QVariantList networks() const { return m_networks; }
    QVariantList gpus() const { return m_gpus; }
    QVariantMap battery() const { return m_battery; }
    QVariantList sensors() const { return m_sensors; }
    QVariantList fans() const { return m_fans; }
    QVariantMap system() const { return m_system; }
    QVariantMap info() const { return m_info; }
    QVariantList windows() const { return m_windows; }

    // A graphable series, oldest first, at most historySize long.
    const QVector<float> &series(const QString &key) const;
    Q_INVOKABLE QVariantList history(const QString &key) const;
    Q_INVOKABLE bool hasHistory(const QString &key) const { return m_history.contains(key); }

    // Take a sample now, rather than waiting out the interval.
    Q_INVOKABLE void refresh() { sample(); }

    // Where /sys is. Settable for testing, from HYPRSHELL_TASKS_SYSROOT.
    static QString sys(const QString &path);
    // A PCI vendor:device pair ("1002", "73ef") as a name.
    static QString pciName(const QString &vendor, const QString &device);

    static const int kHistory = 300;

signals:
    void intervalChanged();
    void pausedChanged();
    void updated();
    void windowsChanged();

private:
    void sample();
    void readStatic();
    void readCpu(double secs);
    void readMemory();
    void readPressure();
    void readDisks(double secs);
    void readNetworks(double secs);
    void readGpus();
    void readBattery();
    void readSensors();
    void readSystem();
    void pollWindows();
    void push(const QString &key, double v);

    int m_interval = 1000;
    bool m_paused = false;
    QTimer m_timer;
    QElapsedTimer m_clock;
    qint64 m_lastAt = 0;
    qint64 m_sampledAt = 0;
    quint64 m_tick = 0;

    ProcessModel *m_procs = nullptr;
    AppIndex *m_apps = nullptr;

    QVariantMap m_cpu, m_memory, m_pressure, m_battery, m_system, m_info;
    QVariantList m_cores, m_disks, m_networks, m_gpus, m_sensors, m_fans, m_windows;
    QHash<QString, QVector<float>> m_history;

    // Previous counters, for rates.
    struct CpuTimes { quint64 busy = 0, total = 0, user = 0, system = 0, iowait = 0; };
    QVector<CpuTimes> m_prevCpu;           // [0] is the total, then each core
    quint64 m_prevCtxt = 0, m_prevIntr = 0;
    struct DiskPrev { quint64 rd = 0, wr = 0, rdSect = 0, wrSect = 0, rdMs = 0, wrMs = 0, ioMs = 0; };
    QHash<QString, DiskPrev> m_prevDisk;
    struct NetPrev { quint64 rx = 0, tx = 0; };
    QHash<QString, NetPrev> m_prevNet;

    // NVIDIA, through nvidia-smi, which is the only unprivileged way in.
    QProcess *m_smi = nullptr;
    QVariantMap m_smiLast;
    QString m_nvidiaSlot;

    QLocalSocket *m_hypr = nullptr;
    QByteArray m_hyprBuf;
    int m_hyprPoll = 0;
};
