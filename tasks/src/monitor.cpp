#include "monitor.h"

#include "appindex.h"
#include "procmodel.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QNetworkInterface>
#include <QSet>
#include <QSysInfo>
#include <QTextStream>

#include <sys/statvfs.h>
#include <unistd.h>

namespace {

QByteArray slurp(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return f.readAll();
}
QString text(const QString &path) { return QString::fromUtf8(slurp(path)).trimmed(); }
qint64 number(const QString &path, qint64 fallback = -1) {
    bool ok = false;
    const qint64 v = text(path).toLongLong(&ok);
    return ok ? v : fallback;
}
QStringList entries(const QString &dir, const QStringList &filters = {}) {
    return QDir(dir).entryList(filters, QDir::Dirs | QDir::Files | QDir::System | QDir::NoDotAndDotDot,
                               QDir::Name);
}

} // namespace

// A PCI vendor:device pair as a name, from the hwdata list every
// distribution ships (it is what lspci reads).
QString Monitor::pciName(const QString &vendor, const QString &device) {
    static QHash<QString, QString> cache;
    const QString key = vendor + ":" + device;
    if (cache.contains(key)) return cache.value(key);
    QString vendorName, deviceName;
    for (const char *p : {"/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids"}) {
        QFile f(QString::fromLatin1(p));
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) continue;
        bool inVendor = false;
        while (!f.atEnd()) {
            const QByteArray line = f.readLine();
            if (line.isEmpty() || line.startsWith('#')) continue;
            if (line[0] != '\t') {
                if (inVendor) break;
                if (line.startsWith(vendor.toLatin1())) { inVendor = true; vendorName = QString::fromUtf8(line.mid(6)).trimmed(); }
            } else if (inVendor && line.size() > 1 && line[1] != '\t' && line.mid(1, 4) == device.toLatin1()) {
                deviceName = QString::fromUtf8(line.mid(7)).trimmed();
                break;
            }
        }
        break;
    }
    // The bracketed marketing name, where the list has one: "Navi 33
    // [Radeon RX 7600/7600 XT/7600M XT/7600S/7700S / PRO W7600]".
    QString name = deviceName;
    const int b = deviceName.indexOf('['), e = deviceName.lastIndexOf(']');
    if (b >= 0 && e > b) name = deviceName.mid(b + 1, e - b - 1);
    QString vshort = vendorName;
    if (vendor == "1002") vshort = "AMD";
    else if (vendor == "10de") vshort = "NVIDIA";
    else if (vendor == "8086") vshort = "Intel";
    const QString out = name.isEmpty() ? (vshort.isEmpty() ? key : vshort + " " + device)
                                       : (name.startsWith(vshort) ? name : vshort + " " + name);
    cache.insert(key, out);
    return out;
}

namespace {

// "some avg10=1.23 avg60=0.40 avg300=0.10 total=123"
QVariantMap psiLine(const QString &line) {
    QVariantMap m;
    for (const QString &part : line.split(' ', Qt::SkipEmptyParts)) {
        const int eq = part.indexOf('=');
        if (eq > 0) m.insert(part.left(eq), part.mid(eq + 1).toDouble());
    }
    return m;
}

// The physical disk a block device (a partition, a mapper device) is on.
QString diskOf(const QString &devName) {
    QString name = devName;
    for (int hops = 0; hops < 6; ++hops) {
        const QString blk = Monitor::sys("/sys/block/" + name);
        if (QFileInfo::exists(blk)) {
            const QStringList slaves = entries(blk + "/slaves");
            if (slaves.isEmpty()) return name;
            name = slaves.first();
            continue;
        }
        // A partition: its directory in /sys/class/block is inside the
        // disk's.
        const QString real = QFileInfo(Monitor::sys("/sys/class/block/" + name)).canonicalFilePath();
        if (real.isEmpty()) return {};
        name = QFileInfo(QFileInfo(real).path()).fileName();
    }
    return {};
}

} // namespace

QString Monitor::sys(const QString &path) {
    static const QString root = qEnvironmentVariable("HYPRSHELL_TASKS_SYSROOT");
    if (root.isEmpty() || !path.startsWith("/sys")) return path;
    return root + path;
}

Monitor::Monitor(QObject *parent) : QObject(parent) {
    m_apps = new AppIndex(this);
    m_procs = new ProcessModel(m_apps, this);
    m_clock.start();
    readStatic();
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &Monitor::sample);
    m_timer.start(m_interval);
    // Something to show straight away; rates need a second sample.
    sample();
    pollWindows();
}

Monitor::~Monitor() = default;

void Monitor::setInterval(int ms) {
    ms = qBound(250, ms, 10000);
    if (ms == m_interval) return;
    m_interval = ms;
    m_timer.setInterval(ms);
    emit intervalChanged();
}

void Monitor::setPaused(bool p) {
    if (p == m_paused) return;
    m_paused = p;
    if (p) m_timer.stop(); else { m_timer.start(m_interval); sample(); }
    emit pausedChanged();
}

const QVector<float> &Monitor::series(const QString &key) const {
    static const QVector<float> empty;
    auto it = m_history.constFind(key);
    return it == m_history.constEnd() ? empty : it.value();
}

QVariantList Monitor::history(const QString &key) const {
    QVariantList out;
    for (float v : series(key)) out << v;
    return out;
}

void Monitor::push(const QString &key, double v) {
    QVector<float> &h = m_history[key];
    h.append(float(v));
    if (h.size() > kHistory) h.remove(0, h.size() - kHistory);
}

void Monitor::sample() {
    const qint64 now = m_clock.elapsed();
    const double secs = m_lastAt == 0 ? 0 : (now - m_lastAt) / 1000.0;
    m_lastAt = now;
    m_sampledAt = QDateTime::currentMSecsSinceEpoch();

    readCpu(secs);
    readMemory();
    readPressure();
    readDisks(secs);
    readNetworks(secs);
    readGpus();
    readBattery();
    readSensors();
    m_procs->sample(secs, m_cores.size(), m_battery.value("watts").toDouble());
    readSystem();

    if (++m_hyprPoll >= qMax(1, 2000 / m_interval)) { m_hyprPoll = 0; pollWindows(); }
    if (++m_tick % 30 == 0) m_apps->refreshIfChanged();
    emit updated();
}

// ── fixed facts ──────────────────────────────────────────────────────────
void Monitor::readStatic() {
    QVariantMap info;
    // CPU
    const QString cpuinfo = QString::fromUtf8(slurp("/proc/cpuinfo"));
    QSet<QString> physCores, sockets;
    QString model, vendor, flags;
    QString phys, core;
    for (const QString &line : cpuinfo.split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0) {
            if (!phys.isEmpty() || !core.isEmpty()) physCores.insert(phys + "/" + core);
            phys.clear(); core.clear();
            continue;
        }
        const QString k = line.left(c).trimmed(), v = line.mid(c + 1).trimmed();
        if (k == "model name" && model.isEmpty()) model = v;
        else if (k == "vendor_id" && vendor.isEmpty()) vendor = v;
        else if (k == "flags" && flags.isEmpty()) flags = v;
        else if (k == "physical id") { phys = v; sockets.insert(v); }
        else if (k == "core id") core = v;
    }
    const int threads = int(sysconf(_SC_NPROCESSORS_CONF));
    info["cpuModel"] = model.isEmpty() ? QSysInfo::currentCpuArchitecture() : model;
    info["cpuVendor"] = vendor;
    info["threads"] = threads;
    info["cores"] = physCores.isEmpty() ? threads : physCores.size();
    info["sockets"] = qMax(1, int(sockets.size()));
    const QStringList fl = flags.split(' ');
    info["virtualization"] = fl.contains("svm") ? "AMD-V" : fl.contains("vmx") ? "VT-x" : "";

    // Speeds: base where the driver says, else the range.
    const QString f0 = sys("/sys/devices/system/cpu/cpu0/cpufreq/");
    qint64 base = number(f0 + "base_frequency");
    if (base <= 0) base = number(f0 + "amd_pstate_nominal_freq");
    info["baseMHz"] = base > 0 ? base / 1000 : 0;
    info["maxMHz"] = qMax<qint64>(0, number(f0 + "cpuinfo_max_freq") / 1000);
    info["minMHz"] = qMax<qint64>(0, number(f0 + "cpuinfo_min_freq") / 1000);
    info["scalingDriver"] = text(f0 + "scaling_driver");

    // Caches, each counted once however many CPUs share it.
    QHash<QString, qint64> cache;
    QSet<QString> seenCache;
    for (int cpu = 0; cpu < threads; ++cpu) {
        const QString base = sys(QString("/sys/devices/system/cpu/cpu%1/cache/").arg(cpu));
        for (const QString &idx : entries(base, {"index*"})) {
            const QString d = base + idx + "/";
            const QString level = text(d + "level"), type = text(d + "type"), shared = text(d + "shared_cpu_list");
            const QString id = level + type + shared;
            if (seenCache.contains(id)) continue;
            seenCache.insert(id);
            QString sz = text(d + "size");
            qint64 bytes = sz.left(sz.size() - 1).toLongLong();
            if (sz.endsWith('K')) bytes *= 1024; else if (sz.endsWith('M')) bytes *= 1024 * 1024;
            const QString key = "L" + level + (type == "Data" ? "d" : type == "Instruction" ? "i" : "");
            cache[key] += bytes;
        }
    }
    QVariantMap caches;
    for (auto it = cache.cbegin(); it != cache.cend(); ++it) caches.insert(it.key(), it.value());
    info["caches"] = caches;

    // NUMA
    QVariantList nodes;
    for (const QString &n : entries(sys("/sys/devices/system/node"), {"node*"})) {
        const QString d = sys("/sys/devices/system/node/") + n + "/";
        const QString mi = text(d + "meminfo");
        qint64 total = 0;
        for (const QString &line : mi.split('\n'))
            if (line.contains("MemTotal")) total = line.split(' ', Qt::SkipEmptyParts).value(3).toLongLong() * 1024;
        nodes << QVariantMap{{"name", n}, {"cpus", text(d + "cpulist")}, {"memory", total}};
    }
    info["numa"] = nodes;

    // The machine
    const QString dmi = sys("/sys/class/dmi/id/");
    info["vendor"] = text(dmi + "sys_vendor");
    info["product"] = text(dmi + "product_name");
    info["productVersion"] = text(dmi + "product_version");
    info["board"] = text(dmi + "board_name");
    info["boardVendor"] = text(dmi + "board_vendor");
    info["bios"] = text(dmi + "bios_version");
    info["biosDate"] = text(dmi + "bios_date");
    info["biosVendor"] = text(dmi + "bios_vendor");
    info["chassis"] = number(dmi + "chassis_type", 0);
    info["firmware"] = QFileInfo::exists(sys("/sys/firmware/efi")) ? "UEFI" : "BIOS";
    info["secureBoot"] = "";

    info["kernel"] = QSysInfo::kernelVersion();
    info["arch"] = QSysInfo::currentCpuArchitecture();
    info["os"] = QSysInfo::prettyProductName();
    info["hostname"] = QSysInfo::machineHostName();
    info["session"] = qEnvironmentVariable("XDG_SESSION_TYPE");
    info["desktop"] = qEnvironmentVariable("XDG_CURRENT_DESKTOP");
    info["qt"] = QString::fromLatin1(qVersion());
    const QString meminfo = QString::fromUtf8(slurp("/proc/meminfo"));
    for (const QString &line : meminfo.split('\n'))
        if (line.startsWith("MemTotal:")) info["memory"] = line.split(' ', Qt::SkipEmptyParts).value(1).toLongLong() * 1024;
    info["pageSize"] = qint64(sysconf(_SC_PAGESIZE));
    info["clockTicks"] = qint64(sysconf(_SC_CLK_TCK));
    m_info = info;
}

// ── CPU ──────────────────────────────────────────────────────────────────
void Monitor::readCpu(double secs) {
    const QList<QByteArray> lines = slurp("/proc/stat").split('\n');
    QVector<CpuTimes> now;
    quint64 ctxt = 0, intr = 0;
    int running = 0, blocked = 0;
    for (const QByteArray &line : lines) {
        if (line.startsWith("cpu")) {
            const QList<QByteArray> f = line.simplified().split(' ');
            if (f.size() < 8) continue;
            CpuTimes t;
            quint64 v[10] = {};
            for (int i = 1; i < f.size() && i <= 10; ++i) v[i - 1] = f[i].toULongLong();
            // guest and guest_nice are already inside user and nice.
            const quint64 idle = v[3], iowait = v[4];
            t.total = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
            t.busy = t.total - idle - iowait;
            t.user = v[0] + v[1];
            t.system = v[2] + v[5] + v[6];
            t.iowait = iowait;
            now.append(t);
        } else if (line.startsWith("ctxt ")) ctxt = line.mid(5).trimmed().toULongLong();
        else if (line.startsWith("intr ")) intr = line.mid(5, line.indexOf(' ', 5) - 5).toULongLong();
        else if (line.startsWith("procs_running ")) running = line.mid(14).trimmed().toInt();
        else if (line.startsWith("procs_blocked ")) blocked = line.mid(14).trimmed().toInt();
    }
    auto pct = [](const CpuTimes &a, const CpuTimes &b, quint64 CpuTimes::*field) {
        const quint64 dt = a.total - b.total;
        return dt == 0 ? 0.0 : 100.0 * double(a.*field - b.*field) / double(dt);
    };
    const bool havePrev = m_prevCpu.size() == now.size();
    QVariantList cores;
    double freqSum = 0;
    int freqN = 0;
    for (int i = 1; i < now.size(); ++i) {
        const double p = havePrev ? qBound(0.0, pct(now[i], m_prevCpu[i], &CpuTimes::busy), 100.0) : 0;
        const qint64 khz = number(sys(QString("/sys/devices/system/cpu/cpu%1/cpufreq/scaling_cur_freq").arg(i - 1)));
        const int mhz = khz > 0 ? int(khz / 1000) : 0;
        if (mhz > 0) { freqSum += mhz; ++freqN; }
        cores << QVariantMap{{"percent", p}, {"mhz", mhz}};
        push(QString("cpu/%1").arg(i - 1), p);
        push(QString("cpu/%1/mhz").arg(i - 1), mhz);
    }
    QVariantMap cpu;
    const double total = havePrev && !now.isEmpty() ? qBound(0.0, pct(now[0], m_prevCpu[0], &CpuTimes::busy), 100.0) : 0;
    cpu["percent"] = total;
    cpu["user"] = havePrev ? pct(now[0], m_prevCpu[0], &CpuTimes::user) : 0;
    cpu["system"] = havePrev ? pct(now[0], m_prevCpu[0], &CpuTimes::system) : 0;
    cpu["iowait"] = havePrev ? pct(now[0], m_prevCpu[0], &CpuTimes::iowait) : 0;
    cpu["mhz"] = freqN ? int(freqSum / freqN) : 0;
    cpu["running"] = running;
    cpu["blocked"] = blocked;
    cpu["ctxPerSec"] = secs > 0 && m_prevCtxt ? double(ctxt - m_prevCtxt) / secs : 0;
    cpu["intrPerSec"] = secs > 0 && m_prevIntr ? double(intr - m_prevIntr) / secs : 0;
    // Temperature is filled in by readSensors.
    cpu["temp"] = m_cpu.value("temp");
    m_prevCtxt = ctxt;
    m_prevIntr = intr;
    m_prevCpu = now;
    m_cores = cores;
    m_cpu = cpu;
    push("cpu", total);
    push("cpu/mhz", cpu["mhz"].toDouble());
}

// ── memory ───────────────────────────────────────────────────────────────
void Monitor::readMemory() {
    QHash<QString, qint64> kv;
    for (const QByteArray &line : slurp("/proc/meminfo").split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0) continue;
        kv.insert(QString::fromLatin1(line.left(c)), line.mid(c + 1).simplified().split(' ').value(0).toLongLong() * 1024);
    }
    QVariantMap m;
    const qint64 total = kv.value("MemTotal"), avail = kv.value("MemAvailable", kv.value("MemFree"));
    m["total"] = total;
    m["available"] = avail;
    m["used"] = total - avail;
    m["free"] = kv.value("MemFree");
    m["buffers"] = kv.value("Buffers");
    m["cached"] = kv.value("Cached") + kv.value("SReclaimable") - kv.value("Shmem");
    m["shared"] = kv.value("Shmem");
    m["anon"] = kv.value("AnonPages");
    m["slab"] = kv.value("Slab");
    m["kernel"] = kv.value("KernelStack") + kv.value("PageTables") + kv.value("SUnreclaim");
    m["dirty"] = kv.value("Dirty");
    m["committed"] = kv.value("Committed_AS");
    m["commitLimit"] = kv.value("CommitLimit");
    m["swapTotal"] = kv.value("SwapTotal");
    m["swapUsed"] = kv.value("SwapTotal") - kv.value("SwapFree");
    m["hugeTotal"] = kv.value("HugePages_Total") / 1024 * kv.value("Hugepagesize");
    // zram: what was put in, and what it takes once compressed.
    qint64 zOrig = 0, zUsed = 0, zSize = 0;
    for (const QString &z : entries(sys("/sys/block"), {"zram*"})) {
        const QStringList f = text(sys("/sys/block/") + z + "/mm_stat").split(' ', Qt::SkipEmptyParts);
        zOrig += f.value(0).toLongLong();
        zUsed += f.value(2).toLongLong();
        zSize += number(sys("/sys/block/") + z + "/disksize", 0);
    }
    m["zramOriginal"] = zOrig;
    m["zramUsed"] = zUsed;
    m["zramSize"] = zSize;
    const double pct = total > 0 ? 100.0 * double(total - avail) / double(total) : 0;
    m["percent"] = pct;
    m_memory = m;
    push("mem", pct);
    push("mem/used", double(total - avail));
    push("swap", kv.value("SwapTotal") > 0 ? 100.0 * double(m["swapUsed"].toLongLong()) / double(kv.value("SwapTotal")) : 0);
    push("mem/committed", double(kv.value("Committed_AS")));
}

// Pressure stall information: the share of time something was waiting on
// CPU, memory or I/O. The most direct answer there is to "why is it slow".
void Monitor::readPressure() {
    QVariantMap p;
    for (const char *res : {"cpu", "memory", "io"}) {
        const QString key = res == QByteArray("memory") ? "mem" : QString::fromLatin1(res);
        const QStringList lines = text(QString("/proc/pressure/") + res).split('\n');
        for (const QString &line : lines) {
            if (line.startsWith("some")) {
                const QVariantMap s = psiLine(line);
                p[key + "Some"] = s.value("avg10");
                p[key + "Some60"] = s.value("avg60");
            } else if (line.startsWith("full")) {
                const QVariantMap s = psiLine(line);
                p[key + "Full"] = s.value("avg10");
                p[key + "Full60"] = s.value("avg60");
            }
        }
        push("psi/" + key, p.value(key + "Some").toDouble());
    }
    p["available"] = QFileInfo::exists("/proc/pressure/cpu");
    m_pressure = p;
}

// ── disks ────────────────────────────────────────────────────────────────
void Monitor::readDisks(double secs) {
    // Mounts, by the disk they are on.
    QHash<QString, QVariantList> mounts;
    QSet<QString> seenDev;
    for (const QByteArray &line : slurp("/proc/self/mounts").split('\n')) {
        const QList<QByteArray> f = line.split(' ');
        if (f.size() < 3 || !f[0].startsWith("/dev/")) continue;
        QString dev = QString::fromUtf8(f[0]);
        const QString real = QFileInfo(dev).canonicalFilePath();
        if (!real.isEmpty()) dev = real;
        if (seenDev.contains(dev)) continue;           // btrfs subvolumes: the first mount stands for the rest
        seenDev.insert(dev);
        QString path = QString::fromUtf8(f[1]).replace("\\040", " ");
        const QString disk = diskOf(QFileInfo(dev).fileName());
        if (disk.isEmpty()) continue;
        struct statvfs st {};
        if (statvfs(path.toLocal8Bit().constData(), &st) != 0) continue;
        const qint64 total = qint64(st.f_blocks) * qint64(st.f_frsize);
        const qint64 freeB = qint64(st.f_bavail) * qint64(st.f_frsize);
        const QString fs = QString::fromUtf8(f[2]);
        const bool readOnly = f.size() > 3 && (f[3] == "ro" || f[3].startsWith("ro,"))
                              || fs == "squashfs" || fs == "iso9660" || fs == "erofs" || fs == "udf";
        mounts[disk] << QVariantMap{{"path", path}, {"fs", fs}, {"device", dev}, {"readOnly", readOnly},
                                    {"total", total}, {"free", freeB}, {"used", total - freeB}};
    }

    QVariantList out;
    QHash<QString, DiskPrev> next;
    int index = 0;
    for (const QByteArray &line : slurp("/proc/diskstats").split('\n')) {
        const QList<QByteArray> f = line.simplified().split(' ');
        if (f.size() < 14) continue;
        const QString name = QString::fromLatin1(f[2]);
        if (name.startsWith("loop") || name.startsWith("ram") || name.startsWith("zram") || name.startsWith("dm-")
            || name.startsWith("sr") || name.startsWith("fd") || name.startsWith("md") && false)
            continue;
        const QString blk = sys("/sys/block/" + name);
        if (!QFileInfo::exists(blk)) continue;          // a partition
        DiskPrev d;
        d.rd = f[3].toULongLong(); d.rdSect = f[5].toULongLong(); d.rdMs = f[6].toULongLong();
        d.wr = f[7].toULongLong(); d.wrSect = f[9].toULongLong(); d.wrMs = f[10].toULongLong();
        d.ioMs = f[12].toULongLong();
        next.insert(name, d);
        double rBps = 0, wBps = 0, active = 0, resp = 0;
        if (secs > 0 && m_prevDisk.contains(name)) {
            const DiskPrev &p = m_prevDisk[name];
            rBps = double(d.rdSect - p.rdSect) * 512.0 / secs;
            wBps = double(d.wrSect - p.wrSect) * 512.0 / secs;
            active = qBound(0.0, double(d.ioMs - p.ioMs) / (secs * 10.0), 100.0);
            const quint64 ios = (d.rd - p.rd) + (d.wr - p.wr);
            resp = ios ? double((d.rdMs - p.rdMs) + (d.wrMs - p.wrMs)) / double(ios) : 0;
        }
        const bool rotational = text(blk + "/queue/rotational") == "1";
        const bool removable = text(blk + "/removable") == "1";
        QString model = text(blk + "/device/model");
        if (model.isEmpty()) model = text(blk + "/device/name");
        const QString type = name.startsWith("nvme") ? "SSD (NVMe)"
                           : name.startsWith("mmcblk") ? "SD card"
                           : removable ? "Removable" : rotational ? "HDD" : "SSD";
        const qint64 size = number(blk + "/size", 0) * 512;
        if (size == 0) continue;
        out << QVariantMap{{"name", name}, {"index", index++}, {"model", model.isEmpty() ? name : model},
                           {"type", type}, {"size", size}, {"readBps", rBps}, {"writeBps", wBps},
                           {"active", active}, {"responseMs", resp}, {"mounts", mounts.value(name)},
                           {"system", mounts.value(name).size() > 0 && [&] {
                                for (const QVariant &m : mounts.value(name))
                                    if (m.toMap().value("path") == "/") return true;
                                return false; }()}};
        push("disk/" + name + "/read", rBps);
        push("disk/" + name + "/write", wBps);
        push("disk/" + name + "/active", active);
    }
    m_prevDisk = next;
    m_disks = out;
}

// ── network ──────────────────────────────────────────────────────────────
void Monitor::readNetworks(double secs) {
    // Signal, for Wi-Fi: /proc/net/wireless has the link quality and level.
    QHash<QString, QPair<double, double>> wireless;
    for (const QByteArray &line : slurp("/proc/net/wireless").split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0 || line.contains('|')) continue;
        const QList<QByteArray> f = line.mid(c + 1).simplified().split(' ');
        if (f.size() >= 3)
            wireless.insert(QString::fromLatin1(line.left(c).trimmed()),
                            {QByteArray(f[1]).replace(".", "").toDouble(), QByteArray(f[2]).replace(".", "").toDouble()});
    }
    QHash<QString, QStringList> v4, v6;
    QHash<QString, QString> macs;
    for (const QNetworkInterface &iface : QNetworkInterface::allInterfaces()) {
        for (const QNetworkAddressEntry &e : iface.addressEntries()) {
            if (e.ip().protocol() == QAbstractSocket::IPv4Protocol) v4[iface.name()] << e.ip().toString();
            else if (e.ip().protocol() == QAbstractSocket::IPv6Protocol) v6[iface.name()] << e.ip().toString();
        }
        macs[iface.name()] = iface.hardwareAddress();
    }

    QVariantList out;
    QHash<QString, NetPrev> next;
    int index = 0;
    for (const QByteArray &line : slurp("/proc/net/dev").split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0) continue;
        const QString name = QString::fromLatin1(line.left(c).trimmed());
        if (name == "lo") continue;
        const QString base = sys("/sys/class/net/" + name);
        // Adapters, not the virtual plumbing: a bridge or a veth for a
        // container is not "the network".
        const bool physical = QFileInfo::exists(base + "/device");
        const bool vpn = name.startsWith("wg") || name.startsWith("tun") || name.startsWith("tailscale");
        if (!physical && !vpn) continue;
        const QList<QByteArray> f = line.mid(c + 1).simplified().split(' ');
        if (f.size() < 9) continue;
        NetPrev n;
        n.rx = f[0].toULongLong();
        n.tx = f[8].toULongLong();
        next.insert(name, n);
        double rx = 0, tx = 0;
        if (secs > 0 && m_prevNet.contains(name)) {
            rx = double(n.rx - m_prevNet[name].rx) / secs;
            tx = double(n.tx - m_prevNet[name].tx) / secs;
        }
        const bool wifi = QFileInfo::exists(base + "/wireless") || QFileInfo::exists(base + "/phy80211");
        const QString state = text(base + "/operstate");
        QVariantMap m{{"name", name}, {"index", index++},
                      {"type", wifi ? "Wi-Fi" : vpn ? "VPN" : "Ethernet"},
                      {"up", state == "up" || (vpn && state == "unknown")}, {"rxBps", rx}, {"txBps", tx},
                      {"rxTotal", double(n.rx)}, {"txTotal", double(n.tx)},
                      {"ipv4", v4.value(name)}, {"ipv6", v6.value(name)}, {"mac", macs.value(name)},
                      {"speedMbps", number(base + "/speed", 0)},
                      {"driver", QFileInfo(QFileInfo(base + "/device/driver").symLinkTarget()).fileName()}};
        if (wireless.contains(name)) {
            m["quality"] = wireless[name].first;     // of 70
            m["signalDbm"] = wireless[name].second;
        }
        out << m;
        push("net/" + name + "/rx", rx);
        push("net/" + name + "/tx", tx);
    }
    m_prevNet = next;
    m_networks = out;
}

// ── GPUs ─────────────────────────────────────────────────────────────────
// A GPU that is asleep is left asleep: reading most of these wakes it, and
// on a laptop a woken discrete GPU is an hour of battery.
void Monitor::readGpus() {
    QVariantList out;
    int index = 0;
    for (const QString &card : entries(sys("/sys/class/drm"), {"card*"})) {
        if (card.contains('-')) continue;               // card0-eDP-1: a connector
        const QString dev = sys("/sys/class/drm/") + card + "/device/";
        const QString vendor = text(dev + "vendor").mid(2), device = text(dev + "device").mid(2);
        if (vendor.isEmpty()) continue;
        const QString driver = QFileInfo(QFileInfo(dev + "driver").symLinkTarget()).fileName();
        const QString slot = QFileInfo(QFileInfo(sys("/sys/class/drm/") + card + "/device").symLinkTarget()).fileName();
        const QString rpm = text(dev + "power/runtime_status");
        const bool asleep = rpm == "suspended";
        QVariantMap g{{"card", card}, {"index", index}, {"name", pciName(vendor, device)}, {"vendor", vendor},
                      {"driver", driver}, {"slot", slot}, {"asleep", asleep}};
        // An integrated GPU has no VRAM of its own worth the name and sits
        // on bus 0; a discrete one is the other.
        double busy = -1;
        if (!asleep && driver == "amdgpu") {
            busy = number(dev + "gpu_busy_percent", -1);
            g["vramUsed"] = number(dev + "mem_info_vram_used", 0);
            g["vramTotal"] = number(dev + "mem_info_vram_total", 0);
            g["gttUsed"] = number(dev + "mem_info_gtt_used", 0);
            g["gttTotal"] = number(dev + "mem_info_gtt_total", 0);
            const QStringList hw = entries(dev + "hwmon", {"hwmon*"});
            if (!hw.isEmpty()) {
                const QString h = dev + "hwmon/" + hw.first() + "/";
                const qint64 t = number(h + "temp1_input");
                if (t > 0) g["temp"] = t / 1000.0;
                qint64 pw = number(h + "power1_average");
                if (pw <= 0) pw = number(h + "power1_input");
                if (pw > 0) g["watts"] = pw / 1e6;
                const qint64 hz = number(h + "freq1_input");
                if (hz > 0) g["mhz"] = hz / 1000000;
            }
        } else if (!asleep && driver == "i915") {
            const qint64 mhz = number(sys("/sys/class/drm/") + card + "/gt_cur_freq_mhz");
            if (mhz > 0) g["mhz"] = mhz;
        } else if (!asleep && driver == "xe") {
            const qint64 mhz = number(sys("/sys/class/drm/") + card + "/device/tile0/gt0/freq0/act_freq");
            if (mhz > 0) g["mhz"] = mhz;
        } else if (!asleep && driver == "nvidia") {
            m_nvidiaSlot = slot;
            if (!m_smi) {
                m_smi = new QProcess(this);
                connect(m_smi, &QProcess::finished, this, [this] {
                    const QStringList f = QString::fromUtf8(m_smi->readAllStandardOutput()).trimmed().split(',');
                    if (f.size() >= 7) {
                        m_smiLast = QVariantMap{
                            {"busy", f[1].trimmed().toDouble()},
                            {"vramUsed", f[2].trimmed().toDouble() * 1048576.0},
                            {"vramTotal", f[3].trimmed().toDouble() * 1048576.0},
                            {"temp", f[4].trimmed().toDouble()},
                            {"watts", f[5].trimmed().toDouble()},
                            {"mhz", f[6].trimmed().toDouble()}};
                    }
                });
            }
            if (m_smi->state() == QProcess::NotRunning)
                m_smi->start("nvidia-smi", {"--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.gr",
                                            "--format=csv,noheader,nounits", "-i", "00000000:" + slot.mid(slot.indexOf(':') + 1)});
            for (auto it = m_smiLast.cbegin(); it != m_smiLast.cend(); ++it) g.insert(it.key(), it.value());
            busy = m_smiLast.value("busy", -1).toDouble();
        }
        g["busy"] = busy;
        g["integrated"] = slot.startsWith("0000:00:") || (driver == "amdgpu" && number(dev + "mem_info_vram_total", 0) < (qint64(1) << 30) && !asleep);
        const double vt = g.value("vramTotal").toDouble();
        push(QString("gpu/%1/busy").arg(index), qMax(0.0, busy));
        push(QString("gpu/%1/vram").arg(index), vt > 0 ? 100.0 * g.value("vramUsed").toDouble() / vt : 0);
        out << g;
        ++index;
    }
    m_gpus = out;
}

// ── battery ──────────────────────────────────────────────────────────────
void Monitor::readBattery() {
    QVariantMap b{{"present", false}};
    bool ac = false;
    for (const QString &ps : entries(sys("/sys/class/power_supply"))) {
        const QString d = sys("/sys/class/power_supply/") + ps + "/";
        const QString type = text(d + "type");
        if (type == "Mains" || type == "USB") { if (text(d + "online") == "1") ac = true; continue; }
        if (type != "Battery" || text(d + "scope") == "Device") continue;
        if (b.value("present").toBool()) continue;      // the first battery
        b["present"] = text(d + "present") != "0";
        b["name"] = ps;
        b["percent"] = number(d + "capacity", 0);
        b["status"] = text(d + "status");
        b["model"] = text(d + "model_name");
        b["vendor"] = text(d + "manufacturer");
        b["technology"] = text(d + "technology");
        b["cycles"] = number(d + "cycle_count", -1);
        const qint64 voltMin = number(d + "voltage_min_design", number(d + "voltage_now", 0));
        auto wh = [&](const QString &energy, const QString &charge) -> double {
            const qint64 e = number(d + energy);
            if (e >= 0) return e / 1e6;
            const qint64 c = number(d + charge);
            return c >= 0 && voltMin > 0 ? double(c) * double(voltMin) / 1e12 : -1;
        };
        const double now = wh("energy_now", "charge_now"), full = wh("energy_full", "charge_full"),
                     design = wh("energy_full_design", "charge_full_design");
        b["energyNow"] = now;
        b["energyFull"] = full;
        b["energyDesign"] = design;
        b["health"] = design > 0 && full > 0 ? 100.0 * full / design : -1;
        double watts = number(d + "power_now", -1) / 1e6;
        if (watts < 0) {
            const qint64 c = number(d + "current_now", -1), v = number(d + "voltage_now", -1);
            watts = c >= 0 && v >= 0 ? double(c) * double(v) / 1e12 : 0;
        }
        watts = qAbs(watts);
        b["watts"] = watts;
        const QString st = b["status"].toString();
        if (watts > 0.1 && now > 0) {
            if (st == "Discharging") b["secondsLeft"] = qint64(now / watts * 3600);
            else if (st == "Charging" && full > now) b["secondsLeft"] = qint64((full - now) / watts * 3600);
        }
        const qint64 limit = number(d + "charge_control_end_threshold", -1);
        if (limit > 0) b["chargeLimit"] = limit;
        b["chargeLimitPath"] = limit > 0 ? d + "charge_control_end_threshold" : QString();
    }
    b["ac"] = ac;
    m_battery = b;
    if (b.value("present").toBool()) {
        push("bat/watts", b.value("watts").toDouble());
        push("bat/percent", b.value("percent").toDouble());
    }
}

// ── temperatures and fans ────────────────────────────────────────────────
void Monitor::readSensors() {
    QVariantList temps, fans;
    double cpuTemp = -1;
    int cpuRank = 99;
    // Lower is better: the reading that is the CPU package, where there is one.
    static const QHash<QString, int> cpuChips{{"k10temp", 0}, {"zenpower", 0}, {"coretemp", 0},
                                              {"cpu_thermal", 1}, {"acpitz", 3}, {"thinkpad", 2}};
    for (const QString &hw : entries(sys("/sys/class/hwmon"), {"hwmon*"})) {
        const QString d = sys("/sys/class/hwmon/") + hw + "/";
        const QString chip = text(d + "name");
        for (const QString &f : entries(d, {"temp*_input"})) {
            const QString n = f.left(f.indexOf('_'));
            const qint64 v = number(d + f);
            if (v <= -273000 || v == -1) continue;
            QString label = text(d + n + "_label");
            if (label.isEmpty()) label = n;
            const double c = v / 1000.0;
            const qint64 crit = number(d + n + "_crit");
            temps << QVariantMap{{"chip", chip}, {"label", label}, {"celsius", c},
                                 {"critical", crit > 0 ? crit / 1000.0 : QVariant()}};
            push("temp/" + chip + "/" + label, c);
            if (cpuChips.contains(chip)) {
                int rank = cpuChips.value(chip);
                if (label == "Tctl" || label == "Tdie" || label.startsWith("Package")) rank -= 1;
                if (rank < cpuRank) { cpuRank = rank; cpuTemp = c; }
            }
        }
        for (const QString &f : entries(d, {"fan*_input"})) {
            const QString n = f.left(f.indexOf('_'));
            QString label = text(d + n + "_label");
            if (label.isEmpty()) label = chip + " " + n;
            const qint64 rpm = number(d + f);
            if (rpm < 0) continue;
            fans << QVariantMap{{"chip", chip}, {"label", label}, {"rpm", rpm}};
            push("fan/" + chip + "/" + n, rpm);
        }
    }
    m_sensors = temps;
    m_fans = fans;
    if (cpuTemp > -1) {
        m_cpu["temp"] = cpuTemp;
        push("cpu/temp", cpuTemp);
    }
}

// ── counts ───────────────────────────────────────────────────────────────
void Monitor::readSystem() {
    QVariantMap s;
    const QStringList up = text("/proc/uptime").split(' ');
    s["uptime"] = up.value(0).toDouble();
    const QStringList la = text("/proc/loadavg").split(' ');
    s["load1"] = la.value(0).toDouble();
    s["load5"] = la.value(1).toDouble();
    s["load15"] = la.value(2).toDouble();
    s["processes"] = m_procs->processCount();
    s["threads"] = m_procs->threadCount();
    s["handles"] = text("/proc/sys/fs/file-nr").split('\t').value(0).toLongLong();
    const QString cf = sys("/sys/devices/system/cpu/cpu0/cpufreq/");
    s["governor"] = text(cf + "scaling_governor");
    s["epp"] = text(cf + "energy_performance_preference");
    s["platformProfile"] = text(sys("/sys/firmware/acpi/platform_profile"));
    s["platformProfiles"] = text(sys("/sys/firmware/acpi/platform_profile_choices")).split(' ', Qt::SkipEmptyParts);
    m_system = s;
}

// ── Hyprland's windows ───────────────────────────────────────────────────
// Which processes are applications with windows, and what those windows
// are called — the Processes view's "Apps" — straight off Hyprland's
// socket rather than by running hyprctl every two seconds.
void Monitor::pollWindows() {
    const QString sig = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
    if (sig.isEmpty()) return;
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty()) runtime = QString("/run/user/%1").arg(getuid());
    const QString path = runtime + "/hypr/" + sig + "/.socket.sock";
    if (!m_hypr) {
        m_hypr = new QLocalSocket(this);
        connect(m_hypr, &QLocalSocket::connected, this, [this] { m_hypr->write("j/clients"); m_hypr->flush(); });
        connect(m_hypr, &QLocalSocket::readyRead, this, [this] { m_hyprBuf += m_hypr->readAll(); });
        connect(m_hypr, &QLocalSocket::disconnected, this, [this] {
            m_hyprBuf += m_hypr->readAll();
            const QJsonArray arr = QJsonDocument::fromJson(m_hyprBuf).array();
            m_hyprBuf.clear();
            QVariantList wins;
            for (const QJsonValue &v : arr) {
                const QJsonObject o = v.toObject();
                if (!o.value("mapped").toBool(true)) continue;
                wins << QVariantMap{{"pid", o.value("pid").toInt()}, {"class", o.value("class").toString()},
                                    {"title", o.value("title").toString()}, {"address", o.value("address").toString()},
                                    {"workspace", o.value("workspace").toObject().value("name").toString()}};
            }
            m_windows = wins;
            m_procs->setWindows(wins);
            emit windowsChanged();
        });
    }
    if (m_hypr->state() != QLocalSocket::UnconnectedState) return;
    m_hyprBuf.clear();
    m_hypr->connectToServer(path);
}
