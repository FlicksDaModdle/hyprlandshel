#include "procmodel.h"

#include "appindex.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>

#include <functional>

#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {

QByteArray slurp(const QString &path, qint64 max = 1 << 20) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Unbuffered)) return {};
    return f.read(max);
}

// Fields of /proc/PID/stat after the command name, which is in brackets
// and may itself contain spaces and brackets.
QList<QByteArray> statFields(const QByteArray &stat, QByteArray *comm) {
    const int open = stat.indexOf('('), close = stat.lastIndexOf(')');
    if (open < 0 || close < open) return {};
    if (comm) *comm = stat.mid(open + 1, close - open - 1);
    return stat.mid(close + 2).split(' ');
}

const quint64 kPfKthread = 0x00200000;

constexpr int kIoprioClassShift = 13;
int ioprioValue(int cls, int data) { return (cls << kIoprioClassShift) | data; }
int ioprioSet(int pid, int value) { return int(syscall(SYS_ioprio_set, 1 /* IOPRIO_WHO_PROCESS */, pid, value)); }
int ioprioGet(int pid) { return int(syscall(SYS_ioprio_get, 1, pid)); }

QList<int> threadsOf(int pid) {
    QList<int> out;
    for (const QString &t : QDir(QString("/proc/%1/task").arg(pid)).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        out << t.toInt();
    if (out.isEmpty()) out << pid;
    return out;
}

QString pidList(const QVariantList &pids) {
    QStringList s;
    for (const QVariant &p : pids) s << QString::number(p.toInt());
    return s.join(' ');
}

} // namespace

ProcessModel::ProcessModel(AppIndex *apps, QObject *parent)
    : QAbstractListModel(parent), m_apps(apps) {
    m_myUid = getuid();
    m_hz = sysconf(_SC_CLK_TCK);
    m_page = sysconf(_SC_PAGESIZE);
}

ProcessModel::~ProcessModel() = default;

// ── options ──────────────────────────────────────────────────────────────
void ProcessModel::setMode(const QString &m) { if (m != m_mode) { m_mode = m; rebuild(); emit optionsChanged(); } }
void ProcessModel::setSortKey(const QString &k) {
    if (k == m_sortKey) return;
    m_sortKey = k;
    // Numbers read biggest first; names, users and states A to Z.
    m_desc = !(k == "name" || k == "user" || k == "status" || k == "pid");
    rebuild();
    emit optionsChanged();
}
void ProcessModel::setSortDescending(bool d) { if (d != m_desc) { m_desc = d; rebuild(); emit optionsChanged(); } }
void ProcessModel::setFilter(const QString &f) { if (f != m_filter) { m_filter = f; rebuild(); emit optionsChanged(); } }
void ProcessModel::setShowKernel(bool v) { if (v != m_showKernel) { m_showKernel = v; rebuild(); emit optionsChanged(); } }
void ProcessModel::setShowOtherUsers(bool v) { if (v != m_showOthers) { m_showOthers = v; rebuild(); emit optionsChanged(); } }
void ProcessModel::setPerCore(bool v) { if (v != m_perCore) { m_perCore = v; rebuild(); emit optionsChanged(); } }
void ProcessModel::setTombstoneSeconds(int s) { if (s != m_tombSecs) { m_tombSecs = qBound(0, s, 60); emit optionsChanged(); } }

void ProcessModel::setWindows(const QVariantList &windows) {
    m_windowsByPid.clear();
    for (const QVariant &w : windows) {
        const QVariantMap m = w.toMap();
        const int pid = m.value("pid").toInt();
        if (pid > 0 && !m_windowsByPid.contains(pid)) m_windowsByPid.insert(pid, m);
    }
}

QString ProcessModel::userName(uint uid) const {
    auto it = m_users.constFind(uid);
    if (it != m_users.constEnd()) return it.value();
    struct passwd pw {};
    struct passwd *res = nullptr;
    char buf[1024];
    QString name = QString::number(uid);
    if (getpwuid_r(uid, &pw, buf, sizeof buf, &res) == 0 && res) name = QString::fromLocal8Bit(pw.pw_name);
    m_users.insert(uid, name);
    return name;
}

// ── sampling ─────────────────────────────────────────────────────────────
void ProcessModel::readProc(Proc &p, bool fresh, double secs) {
    const QString base = QString("/proc/%1/").arg(p.pid);
    QByteArray comm;
    const QList<QByteArray> f = statFields(slurp(base + "stat"), &comm);
    if (f.size() < 22) return;
    p.state = f[0].isEmpty() ? '?' : f[0][0];
    p.ppid = f[1].toInt();
    const quint64 flags = f[6].toULongLong();
    const quint64 ticks = f[11].toULongLong() + f[12].toULongLong();
    p.nice = f[16].toInt();
    p.threads = f[17].toInt();
    p.kernel = (flags & kPfKthread) != 0;
    if (!fresh && secs > 0 && ticks >= p.ticks) {
        p.cpu = double(ticks - p.ticks) * 100.0 / (secs * double(m_hz));
        p.cpuTotal += double(ticks - p.ticks) / double(m_hz);
    }
    p.ticks = ticks;

    // Memory: the process's own (anonymous) resident memory — what it would
    // give back by exiting, which is what "how much is this using" means.
    // File-backed pages are shared with the page cache and with every
    // other process that mapped the same library.
    for (const QByteArray &line : slurp(base + "status", 4096).split('\n')) {
        if (line.startsWith("Uid:")) p.uid = line.mid(4).simplified().split(' ').value(0).toUInt();
        else if (line.startsWith("RssAnon:")) p.mem = line.mid(8).simplified().split(' ').value(0).toLongLong() * 1024;
        else if (line.startsWith("RssShmem:")) p.shmem = line.mid(9).simplified().split(' ').value(0).toLongLong() * 1024;
        else if (line.startsWith("VmSwap:")) p.swap = line.mid(7).simplified().split(' ').value(0).toLongLong() * 1024;
    }

    // Disk: read and written to storage, not to the page cache. Only
    // readable for your own processes without root.
    const QByteArray io = slurp(base + "io", 1024);
    if (io.isEmpty()) {
        p.ioOk = false;
    } else {
        qint64 r = -1, w = -1;
        for (const QByteArray &line : io.split('\n')) {
            if (line.startsWith("read_bytes:")) r = line.mid(11).trimmed().toLongLong();
            else if (line.startsWith("write_bytes:")) w = line.mid(12).trimmed().toLongLong();
        }
        if (!fresh && p.ioOk && secs > 0 && r >= p.ioR && w >= p.ioW) {
            p.rBps = double(r - p.ioR) / secs;
            p.wBps = double(w - p.ioW) / secs;
        }
        p.ioR = r;
        p.ioW = w;
        p.ioOk = r >= 0;
    }

    if (fresh) {
        p.name = QString::fromUtf8(comm);
        QByteArray cmd = slurp(base + "cmdline", 8192);
        if (!cmd.isEmpty()) {
            if (cmd.endsWith('\0')) cmd.chop(1);
            const QByteArray argv0 = cmd.left(cmd.indexOf('\0') < 0 ? cmd.size() : cmd.indexOf('\0'));
            cmd.replace('\0', ' ');
            p.cmd = QString::fromUtf8(cmd);
            // comm is cut at 15 characters; the program's own name is not.
            const QString a0 = QFileInfo(QString::fromUtf8(argv0)).fileName();
            if (a0.size() > p.name.size() && a0.startsWith(p.name)) p.name = a0;
        }
        p.exe = QFileInfo(base + "exe").symLinkTarget();
        p.user = userName(p.uid);
    }
}

// GPU use, from the DRM driver's per-client counters in /proc/PID/fdinfo:
// how long each engine was busy, and how much video memory the client
// holds. amdgpu, i915/xe, nouveau and recent NVIDIA drivers all publish
// these. Only for your own processes, like disk I/O.
void ProcessModel::readGpu(Proc &p, double secs, qint64 nowMs) {
    if (p.uid != m_myUid || p.kernel) return;
    // Which file descriptors are the GPU: looked for every few seconds,
    // since a process opens its render node once and keeps it.
    if (p.drmScanAt < 0 || nowMs - p.drmScanAt > 5000) {
        p.drmScanAt = nowMs - qint64(p.pid % 2000);     // spread the scans out
        p.drmFds.clear();
        const QString fdDir = QString("/proc/%1/fd/").arg(p.pid);
        DIR *d = opendir(fdDir.toLocal8Bit().constData());
        if (d) {
            char target[256];
            while (dirent *e = readdir(d)) {
                if (e->d_name[0] == '.') continue;
                const QByteArray link = fdDir.toLocal8Bit() + e->d_name;
                const ssize_t n = readlink(link.constData(), target, sizeof target - 1);
                if (n > 9 && std::strncmp(target, "/dev/dri/", 9) == 0) p.drmFds << QString::fromLatin1(e->d_name);
            }
            closedir(d);
        }
    }
    if (p.drmFds.isEmpty()) { p.gpu = 0; p.gpuMem = 0; return; }
    QHash<QString, quint64> now;
    QSet<QString> clients;
    qint64 vram = 0;
    for (const QString &fd : p.drmFds) {
        const QByteArray info = slurp(QString("/proc/%1/fdinfo/%2").arg(p.pid).arg(fd), 4096);
        QString client, pdev;
        QList<QPair<QString, quint64>> engines;
        qint64 mem = 0;
        for (const QByteArray &line : info.split('\n')) {
            if (line.startsWith("drm-client-id:")) client = QString::fromLatin1(line.mid(14).trimmed());
            else if (line.startsWith("drm-pdev:")) pdev = QString::fromLatin1(line.mid(9).trimmed());
            else if (line.startsWith("drm-engine-") && line.endsWith(" ns")) {
                const int c = line.indexOf(':');
                engines << qMakePair(QString::fromLatin1(line.mid(11, c - 11)), line.mid(c + 1, line.size() - c - 4).trimmed().toULongLong());
            } else if (line.startsWith("drm-memory-vram:") || line.startsWith("drm-resident-vram:")) {
                const QList<QByteArray> f = line.mid(line.indexOf(':') + 1).simplified().split(' ');
                qint64 v = f.value(0).toLongLong();
                if (f.value(1) == "KiB") v *= 1024; else if (f.value(1) == "MiB") v *= 1024 * 1024;
                mem = qMax(mem, v);
            }
        }
        if (client.isEmpty() || clients.contains(pdev + client)) continue;
        clients.insert(pdev + client);
        vram += mem;
        for (const auto &e : engines) now.insert(pdev + "/" + client + "/" + e.first, e.second);
    }
    double best = 0;
    QString bestEngine;
    if (secs > 0) {
        QHash<QString, double> perEngine;
        for (auto it = now.cbegin(); it != now.cend(); ++it) {
            const quint64 before = p.gpuNs.value(it.key(), it.value());
            if (it.value() < before) continue;
            const QString engine = it.key().section('/', 2);
            perEngine[engine] += double(it.value() - before) / (secs * 1e9) * 100.0;
        }
        for (auto it = perEngine.cbegin(); it != perEngine.cend(); ++it)
            if (it.value() > best) { best = it.value(); bestEngine = it.key(); }
    }
    p.gpuNs = now;
    p.gpu = qMin(100.0, best);
    p.gpuEngine = bestEngine;
    p.gpuMem = vram;
}

void ProcessModel::sample(double secs, int ncpu, double batteryWatts) {
    m_ncpu = qMax(1, ncpu);
    m_battery = batteryWatts;
    ++m_seq;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

    DIR *d = opendir("/proc");
    if (!d) return;
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
        const int pid = atoi(e->d_name);
        if (pid <= 0) continue;
        // Its start time, so a PID the kernel has handed to a new process
        // is not taken for the old one.
        const QList<QByteArray> f = statFields(slurp(QString("/proc/%1/stat").arg(pid)), nullptr);
        if (f.size() < 22) continue;
        const quint64 start = f[19].toULongLong();
        auto it = m_procs.find(pid);
        bool fresh = false;
        if (it == m_procs.end() || it->start != start || it->dead) {
            Proc p;
            p.pid = pid;
            p.start = start;
            it = m_procs.insert(pid, p);
            fresh = true;
        }
        readProc(*it, fresh, secs);
        readGpu(*it, secs, nowMs);
        it->seq = m_seq;
    }
    closedir(d);

    // The ones that went: kept a while as tombstones, then dropped.
    int live = 0, threads = 0;
    for (auto it = m_procs.begin(); it != m_procs.end();) {
        if (it->seq != m_seq) {
            if (!it->dead) {
                it->dead = true;
                it->diedAt = nowMs;
                it->cpu = it->gpu = it->rBps = it->wBps = 0;
            }
            if (nowMs - it->diedAt > qint64(m_tombSecs) * 1000) { it = m_procs.erase(it); continue; }
        } else {
            ++live;
            threads += it->threads;
        }
        ++it;
    }
    m_liveCount = live;
    m_threadCount = threads;
    assignGroups();
    accumulate(secs, nowMs);
    rebuild();
}

// Which app each live process belongs to: the window-owning process above
// it, if any. Remembered on the process, so its tombstone stays in place.
void ProcessModel::assignGroups() {
    QHash<int, QString> memo;
    std::function<QString(int, int)> find = [&](int pid, int hops) -> QString {
        if (pid <= 1 || hops > 64) return QString();
        auto g = memo.constFind(pid);
        if (g != memo.constEnd()) return g.value();
        QString out;
        if (m_windowsByPid.contains(pid)) out = "app:" + m_windowsByPid[pid].value("class").toString().toLower();
        else if (m_procs.contains(pid)) out = find(m_procs[pid].ppid, hops + 1);
        memo.insert(pid, out);
        return out;
    };
    for (auto it = m_procs.begin(); it != m_procs.end(); ++it)
        if (!it->dead) it->group = find(it->pid, 0);
}

// App history: what each app used in this interval, added to its total.
void ProcessModel::accumulate(double secs, qint64 nowMs) {
    if (secs <= 0) return;
    QHash<QString, double> cpu, gpu, disk;
    for (const Proc &p : std::as_const(m_procs)) {
        if (p.dead || p.group.isEmpty()) continue;
        cpu[p.group] += p.cpu / 100.0 * secs;
        gpu[p.group] += p.gpu / 100.0 * secs;
        disk[p.group] += (p.rBps + p.wBps) * secs;
    }
    for (auto it = cpu.cbegin(); it != cpu.cend(); ++it) {
        QVariantMap &t = m_appTotals[it.key()];
        const QString cls = it.key().mid(4);
        if (!t.contains("name")) {
            const QString n = m_apps->byClass(cls).value("name").toString();
            t["name"] = n.isEmpty() ? (cls.isEmpty() ? "Application" : cls.left(1).toUpper() + cls.mid(1)) : n;
            t["icon"] = cls;
            t["key"] = it.key();
            t["firstSeen"] = nowMs;
        }
        t["cpuSeconds"] = t.value("cpuSeconds").toDouble() + it.value();
        t["gpuSeconds"] = t.value("gpuSeconds").toDouble() + gpu.value(it.key());
        t["diskBytes"] = t.value("diskBytes").toDouble() + disk.value(it.key());
        t["lastSeen"] = nowMs;
    }
}

// ── layout ───────────────────────────────────────────────────────────────
// A process is named by its program, not its application: "firefox"
// rather than "Firefox" for each content process would make eight rows
// that look like eight windows. The application's name is on its group.
QString ProcessModel::displayName(const Proc &p) const { return p.name; }

// Not an icon file: the shell draws its own glyphs (IconPaths.js) and picks
// one from a window class or program name with the dock's own rules, so
// the "icon" here is the text those rules read — see Glyphs.js.
QString ProcessModel::iconFor(const Proc &p) const {
    if (p.kernel) return QStringLiteral("kernel");
    return p.name;
}

bool ProcessModel::matches(const Proc &p) const {
    if (m_filter.isEmpty()) return true;
    const QString f = m_filter.trimmed();
    bool isNum = false;
    const int n = f.toInt(&isNum);
    if (isNum && p.pid == n) return true;
    return p.name.contains(f, Qt::CaseInsensitive) || p.cmd.contains(f, Qt::CaseInsensitive)
        || p.user.contains(f, Qt::CaseInsensitive)
        || (m_windowsByPid.contains(p.pid) && m_windowsByPid[p.pid].value("title").toString().contains(f, Qt::CaseInsensitive));
}

int ProcessModel::powerLevel(double cpuMachine, double gpu) const {
    const double score = cpuMachine + gpu * 0.5;
    if (score < 0.3) return 0;      // very low
    if (score < 2) return 1;        // low
    if (score < 8) return 2;        // moderate
    if (score < 25) return 3;       // high
    return 4;                       // very high
}

ProcessModel::Row ProcessModel::procRow(const Proc &p, int depth, const QString &section) const {
    Row r;
    r.kind = 2;
    r.key = QString("p:%1").arg(p.pid);
    r.section = section;
    r.pid = p.pid;
    r.pids = {p.pid};
    r.depth = depth;
    r.name = displayName(p);
    r.icon = iconFor(p);
    r.title = m_windowsByPid.value(p.pid).value("title").toString();
    r.address = m_windowsByPid.value(p.pid).value("address").toString();
    r.dead = p.dead;
    r.cpu = cpuShown(p.cpu);
    r.mem = p.mem + p.shmem;
    r.rBps = p.rBps;
    r.wBps = p.wBps;
    r.ioKnown = p.ioOk;
    r.gpu = p.gpu;
    r.gpuMem = p.gpuMem;
    r.power = p.dead ? 0 : powerLevel(p.cpu / m_ncpu, p.gpu);
    r.count = 1;
    return r;
}

void ProcessModel::sortRows(QVector<Row> &rows) const {
    const QString k = m_sortKey;
    const bool desc = m_desc;
    auto procOf = [this](const Row &r) -> const Proc * {
        auto it = m_procs.constFind(r.pid);
        return it == m_procs.constEnd() ? nullptr : &it.value();
    };
    std::stable_sort(rows.begin(), rows.end(), [&](const Row &a, const Row &b) {
        int c = 0;
        if (k == "name") c = QString::compare(a.name, b.name, Qt::CaseInsensitive);
        else if (k == "pid") c = (a.pid > b.pid) - (a.pid < b.pid);
        else if (k == "cpu") c = (a.cpu > b.cpu) - (a.cpu < b.cpu);
        else if (k == "mem") c = (a.mem > b.mem) - (a.mem < b.mem);
        else if (k == "disk") { const double x = a.rBps + a.wBps, y = b.rBps + b.wBps; c = (x > y) - (x < y); }
        else if (k == "gpu") c = (a.gpu > b.gpu) - (a.gpu < b.gpu);
        else if (k == "gpumem") c = (a.gpuMem > b.gpuMem) - (a.gpuMem < b.gpuMem);
        else if (k == "power") { c = (a.power > b.power) - (a.power < b.power); if (!c) c = (a.cpu > b.cpu) - (a.cpu < b.cpu); }
        else {
            const Proc *pa = procOf(a), *pb = procOf(b);
            if (pa && pb) {
                if (k == "user") c = QString::compare(pa->user, pb->user);
                else if (k == "status") c = (pa->state > pb->state) - (pa->state < pb->state);
                else if (k == "threads") c = (pa->threads > pb->threads) - (pa->threads < pb->threads);
            }
        }
        if (c == 0) {
            // Ties in name order whichever way the column runs, so rows
            // with nothing to tell them apart do not shuffle every second.
            const int n = QString::compare(a.name, b.name, Qt::CaseInsensitive);
            return n != 0 ? n < 0 : a.pid < b.pid;
        }
        return desc ? c > 0 : c < 0;
    });
}

void ProcessModel::rebuild() {
    QVector<Row> out;
    double totCpu = 0, totGpu = 0, totR = 0, totW = 0;
    qint64 totMem = 0;
    QVariantMap sectionCounts;

    auto visible = [this](const Proc &p) {
        if (p.kernel && !m_showKernel) return false;
        if (!m_showOthers && p.uid != m_myUid) return false;
        return true;
    };
    for (const Proc &p : std::as_const(m_procs)) {
        if (p.dead || !visible(p)) continue;
        totCpu += cpuShown(p.cpu);
        totGpu += p.gpu;
        totMem += p.mem + p.shmem;
        totR += p.rBps;
        totW += p.wBps;
    }

    const bool filtering = !m_filter.trimmed().isEmpty();

    if (m_mode == "flat") {
        QVector<Row> rows;
        for (const Proc &p : std::as_const(m_procs))
            if (visible(p) && matches(p)) rows << procRow(p, 0, "all");
        sortRows(rows);
        out = rows;
    } else if (m_mode == "tree") {
        QHash<int, QVector<int>> children;
        QVector<int> roots;
        for (const Proc &p : std::as_const(m_procs)) {
            if (!visible(p)) continue;
            if (p.ppid > 0 && m_procs.contains(p.ppid) && visible(m_procs[p.ppid])) children[p.ppid] << p.pid;
            else roots << p.pid;
        }
        // Which subtrees hold a match, so a match deep down keeps the
        // processes above it on screen.
        QHash<int, bool> keep;
        std::function<bool(int)> holds = [&](int pid) -> bool {
            bool k = matches(m_procs[pid]);
            for (int c : children.value(pid)) k = holds(c) || k;
            keep[pid] = k;
            return k;
        };
        for (int r : roots) holds(r);
        std::function<void(const QVector<int> &, int)> add = [&](const QVector<int> &pids, int depth) {
            QVector<Row> level;
            for (int pid : pids) if (keep.value(pid)) level << procRow(m_procs[pid], depth, "tree");
            sortRows(level);
            for (Row &r : level) {
                const QVector<int> kids = children.value(r.pid);
                r.expandable = !kids.isEmpty();
                const bool open = r.expandable && (filtering || !m_collapsed.contains(r.key));
                out << r;
                if (open) add(kids, depth + 1);
            }
        };
        add(roots, 0);
        for (Row &r : out) {
            // Folded rows say what they hold.
            if (r.expandable) {
                int n = 0;
                std::function<void(int)> count = [&](int pid) { for (int c : children.value(pid)) { ++n; count(c); } };
                count(r.pid);
                r.count = n + 1;
            }
        }
    } else {
        // apps: grouped under the window-owning process above them
        // (assignGroups, each sample).
        QHash<QString, QVector<int>> appMembers;
        QVector<int> background, system;
        for (auto it = m_procs.cbegin(); it != m_procs.cend(); ++it) {
            const Proc &p = it.value();
            if (!visible(p)) continue;
            const QString &g = p.group;
            if (!g.isEmpty()) appMembers[g] << p.pid;
            else if (p.uid == m_myUid) background << p.pid;
            else system << p.pid;
        }

        // Apps
        QVector<Row> apps;
        QHash<QString, QVector<Row>> appChildren;
        for (auto it = appMembers.cbegin(); it != appMembers.cend(); ++it) {
            QVector<Row> kids;
            bool any = !filtering;
            for (int pid : it.value()) {
                const Proc &p = m_procs[pid];
                if (filtering && !matches(p)) continue;
                any = true;
                kids << procRow(p, 1, "apps");
            }
            const QString cls = it.key().mid(4);
            const QVariantMap app = m_apps->byClass(cls);
            const QString appName = app.value("name").toString();
            if (filtering && !any && !appName.contains(m_filter.trimmed(), Qt::CaseInsensitive)) continue;
            if (filtering && !any) for (int pid : it.value()) kids << procRow(m_procs[pid], 1, "apps");
            Row g;
            g.kind = 1;
            g.key = it.key();
            g.section = "apps";
            g.isApp = true;
            g.name = appName.isEmpty() ? (cls.isEmpty() ? "Application" : cls.left(1).toUpper() + cls.mid(1)) : appName;
            g.icon = cls;
            g.dead = true;
            for (int pid : it.value()) {
                const Proc &p = m_procs[pid];
                g.pids << pid;
                g.cpu += cpuShown(p.cpu);
                g.mem += p.mem + p.shmem;
                g.rBps += p.rBps;
                g.wBps += p.wBps;
                g.gpu += p.gpu;
                g.gpuMem += p.gpuMem;
                g.ioKnown = g.ioKnown && p.ioOk;
                if (!p.dead) g.dead = false;
                if (g.title.isEmpty() && m_windowsByPid.contains(pid)) {
                    g.title = m_windowsByPid[pid].value("title").toString();
                    g.address = m_windowsByPid[pid].value("address").toString();
                    g.pid = pid;
                }
            }
            if (g.pid == 0 && !g.pids.isEmpty()) g.pid = g.pids.first();
            g.gpu = qMin(100.0, g.gpu);
            g.power = g.dead ? 0 : powerLevel(m_perCore ? g.cpu / m_ncpu : g.cpu, g.gpu);
            g.count = g.pids.size();
            g.expandable = true;
            sortRows(kids);
            apps << g;
            appChildren.insert(g.key, kids);
        }
        sortRows(apps);

        auto section = [&](const QString &id, const QString &title, int n) {
            Row h;
            h.kind = 0;
            h.key = "section:" + id;
            h.section = id;
            h.name = title;
            h.count = n;
            h.expandable = true;
            out << h;
            sectionCounts.insert(id, n);
            return !m_collapsed.contains(h.key) || filtering;
        };
        if (!apps.isEmpty() && section("apps", "Apps", apps.size())) {
            for (const Row &g : std::as_const(apps)) {
                out << g;
                if (filtering || m_expanded.contains(g.key)) out << appChildren.value(g.key);
            }
        }
        QVector<Row> bg, sys;
        for (int pid : background) if (matches(m_procs[pid])) bg << procRow(m_procs[pid], 0, "background");
        for (int pid : system) if (matches(m_procs[pid])) sys << procRow(m_procs[pid], 0, "system");
        sortRows(bg);
        sortRows(sys);
        if (!bg.isEmpty() && section("background", "Background processes", bg.size())) out << bg;
        if (!sys.isEmpty() && section("system", "System processes", sys.size())) out << sys;

    }

    QVariantMap tot{{"cpu", totCpu}, {"mem", totMem}, {"readBps", totR}, {"writeBps", totW}, {"gpu", qMin(100.0, totGpu)},
                    {"processes", m_liveCount}, {"threads", m_threadCount}, {"sections", sectionCounts}};
    m_totals = tot;
    applyRows(out);
    emit countsChanged();
}

// Turn the old rows into the new without a reset: rows that went are
// removed, new ones inserted, and the order is changed as a layout change,
// which a ListView takes without moving its scroll position.
void ProcessModel::applyRows(QVector<Row> next) {
    QHash<QString, int> wanted;
    for (int i = 0; i < next.size(); ++i) wanted.insert(next[i].key, i);

    for (int i = m_rows.size() - 1; i >= 0;) {
        if (wanted.contains(m_rows[i].key)) { --i; continue; }
        int j = i;
        while (j > 0 && !wanted.contains(m_rows[j - 1].key)) --j;
        beginRemoveRows({}, j, i);
        m_rows.remove(j, i - j + 1);
        endRemoveRows();
        i = j - 1;
    }
    QSet<QString> have;
    for (const Row &r : std::as_const(m_rows)) have.insert(r.key);
    QVector<Row> added;
    for (const Row &r : std::as_const(next)) if (!have.contains(r.key)) added << r;
    if (!added.isEmpty()) {
        beginInsertRows({}, m_rows.size(), m_rows.size() + added.size() - 1);
        m_rows += added;
        endInsertRows();
    }

    bool sameOrder = m_rows.size() == next.size();
    for (int i = 0; sameOrder && i < next.size(); ++i) sameOrder = m_rows[i].key == next[i].key;
    if (!sameOrder) {
        emit layoutAboutToBeChanged();
        const QModelIndexList old = persistentIndexList();
        QModelIndexList from, to;
        for (const QModelIndex &idx : old) {
            const QString key = m_rows.value(idx.row()).key;
            from << idx;
            to << (wanted.contains(key) ? index(wanted.value(key)) : QModelIndex());
        }
        m_rows = next;
        changePersistentIndexList(from, to);
        emit layoutChanged();
    } else {
        m_rows = next;
    }
    if (!m_rows.isEmpty()) emit dataChanged(index(0), index(m_rows.size() - 1));
}

// ── model ────────────────────────────────────────────────────────────────
int ProcessModel::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : m_rows.size(); }

QHash<int, QByteArray> ProcessModel::roleNames() const {
    return {{KindRole, "kind"}, {KeyRole, "key"}, {PidRole, "pid"}, {PidsRole, "pids"}, {DepthRole, "depth"},
            {NameRole, "name"}, {TitleRole, "title"}, {IconRole, "icon"}, {UserRole, "user"}, {UidRole, "uid"},
            {StatusRole, "status"}, {CpuRole, "cpu"}, {MemRole, "mem"}, {DiskReadRole, "diskRead"},
            {DiskWriteRole, "diskWrite"}, {DiskRole, "disk"}, {GpuRole, "gpu"}, {GpuMemRole, "gpuMem"},
            {GpuEngineRole, "gpuEngine"}, {PowerRole, "power"}, {WattsRole, "watts"}, {ThreadsRole, "threads"},
            {NiceRole, "nice"}, {CmdRole, "cmd"}, {ExeRole, "exe"}, {StartedRole, "started"},
            {ExpandableRole, "expandable"}, {ExpandedRole, "expanded"}, {CountRole, "count"}, {DeadRole, "dead"},
            {SectionRole, "section"}, {IsAppRole, "isApp"}, {AddressRole, "address"}, {IoKnownRole, "ioKnown"}};
}

QVariant ProcessModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= m_rows.size()) return {};
    const Row &r = m_rows[index.row()];
    const Proc *p = nullptr;
    auto it = m_procs.constFind(r.pid);
    if (it != m_procs.constEnd()) p = &it.value();
    switch (role) {
    case KindRole: return r.kind;
    case KeyRole: return r.key;
    case PidRole: return r.pid;
    case PidsRole: { QVariantList l; for (int x : r.pids) l << x; return l; }
    case DepthRole: return r.depth;
    case NameRole: return r.name;
    case TitleRole: return r.title;
    case IconRole: return r.icon;
    case UserRole: return p ? p->user : QString();
    case UidRole: return p ? int(p->uid) : -1;
    case StatusRole: {
        if (r.dead) return QStringLiteral("Exited");
        if (r.kind == 0) return QString();
        if (r.kind == 1) {
            bool allStopped = !r.pids.isEmpty();
            for (int pid : r.pids) if (m_procs.value(pid).state != 'T') allStopped = false;
            return allStopped ? QStringLiteral("Suspended") : QString();
        }
        if (!p) return QString();
        if (p->nice >= 19) return QStringLiteral("Efficiency mode");
        switch (p->state) {
        case 'R': return QStringLiteral("Running");
        case 'S': return QStringLiteral("Sleeping");
        case 'D': return QStringLiteral("Waiting on I/O");
        case 'Z': return QStringLiteral("Zombie");
        case 'T': return QStringLiteral("Suspended");
        case 't': return QStringLiteral("Being debugged");
        case 'I': return QStringLiteral("Idle");
        default: return QString(QChar(p->state));
        }
    }
    case CpuRole: return r.cpu;
    case MemRole: return double(r.mem);
    case DiskReadRole: return r.rBps;
    case DiskWriteRole: return r.wBps;
    case DiskRole: return r.rBps + r.wBps;
    case GpuRole: return r.gpu;
    case GpuMemRole: return double(r.gpuMem);
    case GpuEngineRole: return p ? p->gpuEngine : QString();
    case PowerRole: return r.power;
    case WattsRole: return r.watts;
    case ThreadsRole: {
        if (r.kind == 1) { int n = 0; for (int pid : r.pids) n += m_procs.value(pid).threads; return n; }
        return p ? p->threads : 0;
    }
    case NiceRole: return p ? p->nice : 0;
    case CmdRole: return p ? p->cmd : QString();
    case ExeRole: return p ? p->exe : QString();
    case StartedRole: {
        if (!p) return 0;
        static qint64 btime = [] {
            QFile f("/proc/stat");
            if (!f.open(QIODevice::ReadOnly)) return qint64(0);
            for (const QByteArray &l : f.readAll().split('\n'))
                if (l.startsWith("btime ")) return l.mid(6).trimmed().toLongLong();
            return qint64(0);
        }();
        return double(btime + qint64(p->start / quint64(m_hz)));
    }
    case ExpandableRole: return r.expandable;
    case ExpandedRole:
        if (r.kind == 1) return m_expanded.contains(r.key) || !m_filter.trimmed().isEmpty();
        return r.expandable && !m_collapsed.contains(r.key);
    case CountRole: return r.count;
    case DeadRole: return r.dead;
    case SectionRole: return r.section;
    case IsAppRole: return r.isApp;
    case AddressRole: return r.address;
    case IoKnownRole: return r.ioKnown;
    }
    return {};
}

// ── view helpers ─────────────────────────────────────────────────────────
void ProcessModel::toggle(const QString &key) {
    const int i = rowOf(key);
    const bool app = i >= 0 && m_rows[i].kind == 1;
    if (app) setExpanded(key, !m_expanded.contains(key));
    else setExpanded(key, m_collapsed.contains(key));
}

void ProcessModel::setExpanded(const QString &key, bool on) {
    const bool app = key.startsWith("app:");
    if (app) { if (on) m_expanded.insert(key); else m_expanded.remove(key); }
    else { if (on) m_collapsed.remove(key); else m_collapsed.insert(key); }
    rebuild();
}

void ProcessModel::expandAll(bool on) {
    if (on) {
        m_collapsed.clear();
        for (const Row &r : std::as_const(m_rows)) if (r.kind == 1) m_expanded.insert(r.key);
    } else {
        m_expanded.clear();
        for (const Row &r : std::as_const(m_rows)) if (r.kind == 2 && r.expandable) m_collapsed.insert(r.key);
    }
    rebuild();
}

int ProcessModel::rowOf(const QString &key) const {
    for (int i = 0; i < m_rows.size(); ++i) if (m_rows[i].key == key) return i;
    return -1;
}

QVariantMap ProcessModel::row(int i) const {
    QVariantMap m;
    if (i < 0 || i >= m_rows.size()) return m;
    const QHash<int, QByteArray> roles = roleNames();
    for (auto it = roles.cbegin(); it != roles.cend(); ++it)
        m.insert(QString::fromLatin1(it.value()), data(index(i), it.key()));
    return m;
}

QVariantMap ProcessModel::details(int pid) const {
    QVariantMap m;
    const QString base = QString("/proc/%1/").arg(pid);
    if (!QFileInfo::exists(base)) return m;
    auto it = m_procs.constFind(pid);
    if (it != m_procs.constEnd()) {
        m["name"] = it->name;
        m["user"] = it->user;
        m["ppid"] = it->ppid;
        m["parent"] = m_procs.value(it->ppid).name;
        m["threads"] = it->threads;
        m["nice"] = it->nice;
        m["cmd"] = it->cmd;
        m["kernel"] = it->kernel;
        m["ioKnown"] = it->ioOk;
        m["readTotal"] = double(it->ioR);
        m["writeTotal"] = double(it->ioW);
        m["cpuSeconds"] = double(it->ticks) / double(m_hz);
        QVariantList kids;
        for (const Proc &p : m_procs) if (p.ppid == pid && !p.dead) kids << QVariantMap{{"pid", p.pid}, {"name", p.name}};
        m["children"] = kids;
    }
    m["pid"] = pid;
    m["exe"] = QFileInfo(base + "exe").symLinkTarget();
    m["cwd"] = QFileInfo(base + "cwd").symLinkTarget();
    QVariantMap mem;
    for (const QByteArray &line : slurp(base + "status").split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0) continue;
        const QByteArray k = line.left(c);
        const QByteArray v = line.mid(c + 1).simplified();
        if (k.startsWith("Vm") || k.startsWith("Rss"))
            mem.insert(QString::fromLatin1(k), v.split(' ').value(0).toLongLong() * 1024);
        else if (k == "voluntary_ctxt_switches") m["ctxVoluntary"] = v.toLongLong();
        else if (k == "nonvoluntary_ctxt_switches") m["ctxForced"] = v.toLongLong();
        else if (k == "Cpus_allowed_list") m["cpusAllowed"] = QString::fromLatin1(v);
    }
    m["memory"] = mem;
    m["cgroup"] = QString::fromUtf8(slurp(base + "cgroup")).trimmed().section("::", -1);
    m["oomScore"] = QString::fromLatin1(slurp(base + "oom_score")).trimmed().toInt();
    int fds = 0, sockets = 0, pipes = 0, files = 0;
    QDir fdDir(base + "fd");
    const QFileInfoList fdl = fdDir.entryInfoList(QDir::Files | QDir::System | QDir::NoDotAndDotDot);
    for (const QFileInfo &fi : fdl) {
        ++fds;
        const QString t = fi.symLinkTarget();
        const QString raw = QFile::symLinkTarget(fi.absoluteFilePath());
        Q_UNUSED(t);
        char buf[256];
        const ssize_t n = readlink(fi.absoluteFilePath().toLocal8Bit().constData(), buf, sizeof buf - 1);
        const QByteArray target = n > 0 ? QByteArray(buf, int(n)) : QByteArray();
        Q_UNUSED(raw);
        if (target.startsWith("socket:")) ++sockets;
        else if (target.startsWith("pipe:")) ++pipes;
        else if (target.startsWith('/')) ++files;
    }
    m["fds"] = fds;
    m["sockets"] = sockets;
    m["pipes"] = pipes;
    m["files"] = files;
    m["fdsKnown"] = fdDir.isReadable();
    const int policy = sched_getscheduler(pid);
    m["policy"] = policy == SCHED_OTHER ? "Normal" : policy == SCHED_BATCH ? "Batch" : policy == SCHED_IDLE ? "Idle"
                : policy == SCHED_FIFO ? "Real-time (FIFO)" : policy == SCHED_RR ? "Real-time (round robin)" : "";
    const int io = ioprioGet(pid);
    if (io >= 0) {
        const int cls = io >> kIoprioClassShift;
        m["ioClass"] = cls == 1 ? "Real-time" : cls == 2 ? "Best effort" : cls == 3 ? "Idle" : "Normal";
        m["ioLevel"] = io & 0xff;
    }
    m["affinity"] = affinity(pid);
    QVariantList wins;
    for (auto w = m_windowsByPid.cbegin(); w != m_windowsByPid.cend(); ++w)
        if (w.key() == pid) wins << w.value();
    m["windows"] = wins;
    return m;
}

QVariantList ProcessModel::top(const QString &key, int n) const {
    QVector<const Proc *> list;
    for (const Proc &p : m_procs) if (!p.dead && !p.kernel) list << &p;
    auto val = [&](const Proc *p) -> double {
        if (key == "mem") return double(p->mem + p->shmem);
        if (key == "disk") return p->rBps + p->wBps;
        if (key == "gpu") return p->gpu;
        if (key == "gpumem") return double(p->gpuMem);
        return cpuShown(p->cpu);
    };
    std::sort(list.begin(), list.end(), [&](const Proc *a, const Proc *b) { return val(a) > val(b); });
    QVariantList out;
    for (int i = 0; i < list.size() && i < n; ++i) {
        const Proc *p = list[i];
        out << QVariantMap{{"pid", p->pid}, {"name", p->name}, {"icon", iconFor(*p)}, {"value", val(p)},
                           {"user", p->user}, {"cmd", p->cmd}};
    }
    return out;
}

QVariantList ProcessModel::users() const {
    QHash<uint, QVariantMap> by;
    for (const Proc &p : m_procs) {
        if (p.dead || p.kernel) continue;
        QVariantMap &u = by[p.uid];
        u["uid"] = p.uid;
        u["name"] = p.user;
        u["processes"] = u.value("processes").toInt() + 1;
        u["cpu"] = u.value("cpu").toDouble() + cpuShown(p.cpu);
        u["mem"] = u.value("mem").toDouble() + double(p.mem + p.shmem);
        u["disk"] = u.value("disk").toDouble() + p.rBps + p.wBps;
        u["gpu"] = u.value("gpu").toDouble() + p.gpu;
        u["me"] = p.uid == m_myUid;
    }
    QVariantList out;
    for (const QVariantMap &u : by) out << u;
    std::sort(out.begin(), out.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("cpu").toDouble() > b.toMap().value("cpu").toDouble();
    });
    return out;
}

QVariantList ProcessModel::appTotals() const {
    QVariantList out;
    for (const QVariantMap &t : m_appTotals) out << t;
    std::sort(out.begin(), out.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("cpuSeconds").toDouble() > b.toMap().value("cpuSeconds").toDouble();
    });
    return out;
}

// ── actions ──────────────────────────────────────────────────────────────
void ProcessModel::runAdmin(const QStringList &argv, const QString &what) {
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p, what](int code) {
        const QString err = QString::fromUtf8(p->readAllStandardError()).trimmed();
        if (code == 0) emit actionDone(true, what, false);
        else if (code == 126) emit actionDone(false, "Cancelled.", false);
        else if (code == 127) emit actionDone(false, "Not authorised — no polkit agent answered, or the password was refused.", false);
        else emit actionDone(false, err.isEmpty() ? QString("Failed (exit %1).").arg(code) : err, false);
        p->deleteLater();
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            emit actionDone(false, "pkexec is not installed (the polkit package).", false);
            p->deleteLater();
        }
    });
    p->start("pkexec", argv);
}

void ProcessModel::signal(const QVariantList &pids, int sig, bool admin) {
    const QString what = sig == SIGKILL ? "Killed." : sig == SIGTERM ? "Asked to end." : sig == SIGSTOP ? "Suspended." : sig == SIGCONT ? "Resumed." : "Signalled.";
    if (admin) { runAdmin(QStringList{"kill", "-" + QString::number(sig)} + pidList(pids).split(' '), what); return; }
    QStringList denied, gone;
    for (const QVariant &v : pids) {
        const int pid = v.toInt();
        if (pid <= 1) continue;
        if (::kill(pid, sig) != 0) (errno == EPERM ? denied : gone) << QString::number(pid);
    }
    if (denied.isEmpty()) emit actionDone(true, what, false);
    else emit actionDone(false, QString("Not allowed to signal %1 — it belongs to another user.").arg(denied.join(", ")), true);
}

void ProcessModel::setNice(const QVariantList &pids, int nice, bool admin) {
    nice = qBound(-20, nice, 19);
    if (admin) { runAdmin(QStringList{"renice", "-n", QString::number(nice), "-p"} + pidList(pids).split(' '), "Priority changed."); return; }
    bool denied = false;
    for (const QVariant &v : pids) {
        const int pid = v.toInt();
        for (int tid : threadsOf(pid))
            if (setpriority(PRIO_PROCESS, id_t(tid), nice) != 0 && (errno == EPERM || errno == EACCES)) denied = true;
    }
    if (!denied) emit actionDone(true, "Priority changed.", false);
    else emit actionDone(false, nice < 0 ? "Raising a priority needs administrator rights."
                                         : "Not allowed: lowering a niceness back, or another user's process, needs administrator rights.", true);
}

QVariantList ProcessModel::affinity(int pid) const {
    QVariantList out;
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(pid, sizeof set, &set) != 0) return out;
    for (int i = 0; i < CPU_SETSIZE; ++i) if (CPU_ISSET(i, &set)) out << i;
    return out;
}

void ProcessModel::setAffinity(int pid, const QVariantList &cpus, bool admin) {
    if (cpus.isEmpty()) { emit actionDone(false, "At least one processor has to be allowed.", false); return; }
    QStringList list;
    for (const QVariant &c : cpus) list << QString::number(c.toInt());
    if (admin) { runAdmin({"taskset", "-a", "-p", "-c", list.join(','), QString::number(pid)}, "Affinity set."); return; }
    cpu_set_t set;
    CPU_ZERO(&set);
    for (const QVariant &c : cpus) CPU_SET(c.toInt(), &set);
    bool denied = false;
    for (int tid : threadsOf(pid))
        if (sched_setaffinity(tid, sizeof set, &set) != 0 && errno == EPERM) denied = true;
    if (!denied) emit actionDone(true, "Affinity set.", false);
    else emit actionDone(false, "Not allowed to change another user's process.", true);
}

void ProcessModel::setEfficiency(const QVariantList &pids, bool on, bool admin) {
    if (admin) {
        const QString list = pidList(pids);
        runAdmin({"sh", "-c", on ? QString("renice -n 19 -p %1 >/dev/null && ionice -c 3 -p %1").arg(list)
                                 : QString("renice -n 0 -p %1 >/dev/null && ionice -c 2 -n 4 -p %1").arg(list)},
                 on ? "Efficiency mode on." : "Efficiency mode off.");
        return;
    }
    bool denied = false;
    for (const QVariant &v : pids) {
        for (int tid : threadsOf(v.toInt())) {
            if (setpriority(PRIO_PROCESS, id_t(tid), on ? 19 : 0) != 0) denied = true;
            if (ioprioSet(tid, on ? ioprioValue(3, 0) : ioprioValue(2, 4)) != 0) denied = true;
        }
    }
    if (!denied) emit actionDone(true, on ? "Efficiency mode on." : "Efficiency mode off.", false);
    else emit actionDone(false, on ? "Not allowed to change another user's process."
                                   : "Turning efficiency mode off raises the priority again, which needs administrator rights.", true);
}
