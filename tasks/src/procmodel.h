#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QtQml/qqmlregistration.h>

class AppIndex;
class QProcess;

// Every process, sampled from /proc, as the rows the Processes view shows.
//
// Three ways to lay them out (`mode`):
//
//   "apps"   Windows' grouping: Apps — anything with a window, with every
//            process it started folded under it — then the rest of your own
//            processes, then everyone else's (root's, services').
//   "tree"   the parent/child tree from PID 1, folding at any level.
//   "flat"   every process, one list.
//
// Rows are re-sorted every sample but kept as the same rows: removals,
// insertions and a layout change rather than a reset, so the list does not
// jump back to the top every second and a selected row stays selected.
//
// A process that exits stays for `tombstoneSeconds` as a red row, so the
// thing that just vanished can be seen to have vanished.
class ProcessModel : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Owned by Monitor")

    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY optionsChanged)
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY optionsChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending WRITE setSortDescending NOTIFY optionsChanged)
    Q_PROPERTY(QString filter READ filter WRITE setFilter NOTIFY optionsChanged)
    Q_PROPERTY(bool showKernel READ showKernel WRITE setShowKernel NOTIFY optionsChanged)
    Q_PROPERTY(bool showOtherUsers READ showOtherUsers WRITE setShowOtherUsers NOTIFY optionsChanged)
    Q_PROPERTY(bool perCore READ perCore WRITE setPerCore NOTIFY optionsChanged)
    Q_PROPERTY(int tombstoneSeconds READ tombstoneSeconds WRITE setTombstoneSeconds NOTIFY optionsChanged)
    Q_PROPERTY(int count READ rowCountProp NOTIFY countsChanged)
    Q_PROPERTY(QVariantMap totals READ totals NOTIFY countsChanged)

public:
    enum Role {
        KindRole = Qt::UserRole + 1, KeyRole, PidRole, PidsRole, DepthRole, NameRole, TitleRole, IconRole,
        UserRole, UidRole, StatusRole, CpuRole, MemRole, DiskReadRole, DiskWriteRole, DiskRole, GpuRole,
        GpuMemRole, GpuEngineRole, PowerRole, WattsRole, ThreadsRole, NiceRole, CmdRole, ExeRole,
        StartedRole, ExpandableRole, ExpandedRole, CountRole, DeadRole, SectionRole, IsAppRole,
        AddressRole, IoKnownRole
    };

    ProcessModel(AppIndex *apps, QObject *parent = nullptr);
    ~ProcessModel() override;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString mode() const { return m_mode; }
    void setMode(const QString &m);
    QString sortKey() const { return m_sortKey; }
    void setSortKey(const QString &k);
    bool sortDescending() const { return m_desc; }
    void setSortDescending(bool d);
    QString filter() const { return m_filter; }
    void setFilter(const QString &f);
    bool showKernel() const { return m_showKernel; }
    void setShowKernel(bool v);
    bool showOtherUsers() const { return m_showOthers; }
    void setShowOtherUsers(bool v);
    bool perCore() const { return m_perCore; }
    void setPerCore(bool v);
    int tombstoneSeconds() const { return m_tombSecs; }
    void setTombstoneSeconds(int s);
    int rowCountProp() const { return m_rows.size(); }
    QVariantMap totals() const { return m_totals; }

    int processCount() const { return m_liveCount; }
    int threadCount() const { return m_threadCount; }

    // Called by Monitor once per interval.
    void sample(double secs, int ncpu, double batteryWatts);
    void setWindows(const QVariantList &windows);

    // ── for the view ──────────────────────────────────────────────────────
    Q_INVOKABLE void toggle(const QString &key);
    Q_INVOKABLE void setExpanded(const QString &key, bool on);
    Q_INVOKABLE void expandAll(bool on);
    Q_INVOKABLE int rowOf(const QString &key) const;
    Q_INVOKABLE QVariantMap row(int index) const;
    // Everything known about one process, read fresh: memory breakdown,
    // working directory, cgroup, scheduling, affinity, open files.
    Q_INVOKABLE QVariantMap details(int pid) const;
    // The top few by a key, for the Summary: [{ pid, name, icon, value }].
    Q_INVOKABLE QVariantList top(const QString &key, int n) const;
    // Per-user totals for the Users view.
    Q_INVOKABLE QVariantList users() const;
    // Per-app totals since this started, for App history.
    Q_INVOKABLE QVariantList appTotals() const;

    // ── actions ───────────────────────────────────────────────────────────
    // Each answers with actionDone(ok, message). Where the kernel says no
    // (another user's process), `admin` retries through pkexec, which puts
    // up the polkit password dialog.
    Q_INVOKABLE void signal(const QVariantList &pids, int sig, bool admin = false);
    Q_INVOKABLE void setNice(const QVariantList &pids, int nice, bool admin = false);
    Q_INVOKABLE void setAffinity(int pid, const QVariantList &cpus, bool admin = false);
    Q_INVOKABLE QVariantList affinity(int pid) const;
    // Efficiency mode: the lowest CPU priority and idle-class I/O, so it
    // only runs on what nothing else wants.
    Q_INVOKABLE void setEfficiency(const QVariantList &pids, bool on, bool admin = false);

signals:
    void optionsChanged();
    void countsChanged();
    void actionDone(bool ok, const QString &message, bool canRetryAsAdmin);

private:
    struct Proc {
        int pid = 0, ppid = 0;
        uint uid = 0;
        quint64 start = 0;
        QString name, cmd, exe, user;
        char state = '?';
        quint64 ticks = 0;
        double cpu = 0;                 // % of one core
        qint64 mem = 0, shmem = 0, swap = 0;
        qint64 ioR = -1, ioW = -1;
        double rBps = 0, wBps = 0;
        bool ioOk = false;
        QHash<QString, quint64> gpuNs;  // "client/engine" -> ns
        QStringList drmFds;
        qint64 drmScanAt = -1;
        double gpu = 0;
        qint64 gpuMem = 0;
        QString gpuEngine;
        int threads = 0, nice = 0;
        bool kernel = false;
        bool dead = false;
        qint64 diedAt = 0;
        QString group;                  // app group key, remembered for the tombstone
        quint64 seq = 0;                // last sample seen in
        double cpuTotal = 0;            // seconds, for App history
    };
    struct Row {
        int kind = 2;                   // 0 section header, 1 app group, 2 process
        QString key, section, name, title, icon, address;
        int pid = 0, depth = 0, count = 0;
        QVector<int> pids;
        bool expandable = false, dead = false, isApp = false;
        double cpu = 0, gpu = 0, rBps = 0, wBps = 0, watts = -1;
        qint64 mem = 0, gpuMem = 0;
        int power = 0;
        bool ioKnown = true;
    };

    void readProc(Proc &p, bool fresh, double secs);
    void readGpu(Proc &p, double secs, qint64 nowMs);
    void rebuild();
    void assignGroups();
    void accumulate(double secs, qint64 nowMs);
    void applyRows(QVector<Row> next);
    Row procRow(const Proc &p, int depth, const QString &section) const;
    QString displayName(const Proc &p) const;
    QString iconFor(const Proc &p) const;
    bool matches(const Proc &p) const;
    double cpuShown(double perCoreCpu) const { return m_perCore ? perCoreCpu : perCoreCpu / qMax(1, m_ncpu); }
    int powerLevel(double cpuMachine, double gpu) const;
    void sortRows(QVector<Row> &rows) const;
    QString userName(uint uid) const;
    void runAdmin(const QStringList &argv, const QString &what);

    AppIndex *m_apps;
    QHash<int, Proc> m_procs;
    QVector<Row> m_rows;
    QSet<QString> m_collapsed, m_expanded;
    QHash<int, QVariantMap> m_windowsByPid;
    QHash<QString, QVariantMap> m_appTotals;   // per app: cpu seconds, gpu seconds, disk bytes, first/last seen
    QString m_mode = "apps", m_sortKey = "cpu", m_filter;
    bool m_desc = true, m_showKernel = false, m_showOthers = true, m_perCore = false;
    int m_tombSecs = 5;
    int m_ncpu = 1;
    double m_battery = 0;
    quint64 m_seq = 0;
    int m_liveCount = 0, m_threadCount = 0;
    uint m_myUid = 0;
    long m_hz = 100;
    qint64 m_page = 4096;
    QVariantMap m_totals;
    mutable QHash<uint, QString> m_users;
};
