#include "bench.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMetaObject>
#include <QSaveFile>
#include <QStorageInfo>
#include <QThread>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <numeric>
#include <random>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
double since(Clock::time_point t) { return std::chrono::duration<double>(Clock::now() - t).count(); }

QString resultsPath() {
    QString d = qEnvironmentVariable("XDG_DATA_HOME");
    if (d.isEmpty()) d = QDir::homePath() + "/.local/share";
    return d + "/hyprshell-tasks/benchmarks.json";
}

// A fixed workload of integer mixing and a little floating point: what
// each thread manages in a second, in millions of rounds.
quint64 work(double seconds, const std::atomic<bool> &cancel) {
    quint64 x = 0x9E3779B97F4A7C15ull, rounds = 0;
    double f = 1.0;
    const auto start = Clock::now();
    while (since(start) < seconds && !cancel) {
        for (int i = 0; i < 20000; ++i) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            x *= 0xff51afd7ed558ccdull;
            f = f * 1.0000001 + double(x & 0xff) * 1e-9;
        }
        rounds += 20000;
    }
    // Keep the compiler from deciding none of it matters.
    if (x == 42 && f < 0) std::abort();
    return rounds;
}

} // namespace

Bench::Bench(QObject *parent) : QObject(parent) {
    QFile f(resultsPath());
    if (f.open(QIODevice::ReadOnly)) m_results = QJsonDocument::fromJson(f.readAll()).array().toVariantList();
}

Bench::~Bench() { m_cancel = true; }

void Bench::save() {
    QDir().mkpath(QFileInfo(resultsPath()).absolutePath());
    QSaveFile f(resultsPath());
    if (f.open(QIODevice::WriteOnly)) { f.write(QJsonDocument(QJsonArray::fromVariantList(m_results)).toJson()); f.commit(); }
}

void Bench::clearResults() { m_results.clear(); save(); emit resultsChanged(); }

void Bench::setProgress(double p, const QString &stage) {
    QMetaObject::invokeMethod(this, [this, p, stage] {
        m_progress = p;
        m_stage = stage;
        emit progressChanged();
    }, Qt::QueuedConnection);
}

void Bench::run(const QString &kind, const QString &path) {
    if (m_running) return;
    m_running = true;
    m_cancel = false;
    m_current = kind;
    m_progress = 0;
    m_stage = "Starting";
    emit runningChanged();
    emit progressChanged();
    QThread *t = QThread::create([this, kind, path] {
        QVariantMap r;
        QString err;
        if (kind == "cpu") r = cpu();
        else if (kind == "memory") r = memory();
        else if (kind == "disk") r = disk(path.isEmpty() ? QDir::homePath() + "/.cache" : path, &err);
        QMetaObject::invokeMethod(this, [this, r, err, kind] {
            m_running = false;
            m_current.clear();
            emit runningChanged();
            if (m_cancel) { emit failed("Cancelled."); return; }
            if (!err.isEmpty() || r.isEmpty()) { emit failed(err.isEmpty() ? "It didn't finish." : err); return; }
            QVariantMap res = r;
            res["kind"] = kind;
            res["at"] = QDateTime::currentMSecsSinceEpoch();
            m_results.prepend(res);
            while (m_results.size() > 60) m_results.removeLast();
            save();
            emit resultsChanged();
            emit finished(res);
        }, Qt::QueuedConnection);
    });
    connect(t, &QThread::finished, t, &QObject::deleteLater);
    t->start();
}

// ── processor ────────────────────────────────────────────────────────────
QVariantMap Bench::cpu() {
    setProgress(0.05, "One thread");
    const double single = double(work(3.0, m_cancel)) / 3.0 / 1e6;
    if (m_cancel) return {};
    const unsigned n = std::max(1u, std::thread::hardware_concurrency());
    setProgress(0.5, QString("All %1 threads").arg(n));
    std::vector<quint64> counts(n, 0);
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < n; ++i) threads.emplace_back([&, i] { counts[i] = work(4.0, m_cancel); });
    for (auto &th : threads) th.join();
    const double multi = double(std::accumulate(counts.begin(), counts.end(), quint64(0))) / 4.0 / 1e6;
    setProgress(1, "Done");
    return {{"single", single}, {"multi", multi}, {"threads", int(n)}, {"scaling", single > 0 ? multi / single : 0}};
}

// ── memory ───────────────────────────────────────────────────────────────
QVariantMap Bench::memory() {
    const size_t size = size_t(512) << 20;
    std::vector<char> a(size, 1), b(size, 2);
    setProgress(0.1, "Bandwidth");
    // Copy bandwidth: bytes read plus bytes written, per second.
    double moved = 0;
    const auto start = Clock::now();
    while (since(start) < 3.0 && !m_cancel) {
        std::memcpy(b.data(), a.data(), size);
        moved += 2.0 * double(size);
        a[moved > 0 ? size_t(moved) % size : 0] ^= 1;
    }
    const double bw = moved / since(start) / 1e9;
    if (m_cancel) return {};

    setProgress(0.55, "Latency");
    // Latency: a random walk through 256 MB, each step depending on the
    // last, so nothing can be fetched ahead.
    const size_t count = (size_t(256) << 20) / sizeof(size_t);
    std::vector<size_t> next(count);
    std::vector<size_t> order(count);
    std::iota(order.begin(), order.end(), size_t(0));
    std::shuffle(order.begin() + 1, order.end(), std::mt19937_64(42));
    for (size_t i = 0; i < count; ++i) next[order[i]] = order[(i + 1) % count];
    size_t p = 0;
    const size_t steps = 20'000'000;
    const auto l0 = Clock::now();
    for (size_t i = 0; i < steps && !m_cancel; ++i) p = next[p];
    const double ns = since(l0) * 1e9 / double(steps);
    if (p == size_t(-1)) std::abort();
    setProgress(1, "Done");
    return {{"bandwidth", bw}, {"latency", ns}};
}

// ── a disk ───────────────────────────────────────────────────────────────
QVariantMap Bench::disk(const QString &path, QString *error) {
    QDir().mkpath(path);
    const QStorageInfo st(path);
    const qint64 size = qint64(1) << 30;
    if (st.bytesAvailable() < size * 2) { *error = "Not enough free space there for a 1 GB test file."; return {}; }
    const QString file = path + "/.hyprshell-tasks-bench." + QString::number(getpid());
    const size_t block = size_t(4) << 20;
    void *buf = nullptr;
    if (posix_memalign(&buf, 4096, block) != 0) { *error = "Out of memory."; return {}; }
    std::memset(buf, 0x5a, block);
    std::mt19937_64 rng(7);
    for (size_t i = 0; i < block / 8; ++i) static_cast<quint64 *>(buf)[i] = rng();   // not compressible

    // O_DIRECT where the filesystem allows it, so this measures the disk
    // and not the page cache. Where it doesn't, the cache is dropped for
    // this one file instead.
    bool direct = true;
    int fd = ::open(file.toLocal8Bit().constData(), O_CREAT | O_TRUNC | O_WRONLY | O_DIRECT, 0600);
    if (fd < 0) { direct = false; fd = ::open(file.toLocal8Bit().constData(), O_CREAT | O_TRUNC | O_WRONLY, 0600); }
    if (fd < 0) { free(buf); *error = "Couldn't create a file there."; return {}; }

    setProgress(0.05, "Sequential write");
    auto t0 = Clock::now();
    for (qint64 done = 0; done < size && !m_cancel; done += block) {
        if (::write(fd, buf, block) != ssize_t(block)) { *error = "Writing failed."; break; }
        if ((done / block) % 16 == 0) setProgress(0.05 + 0.3 * double(done) / double(size), "Sequential write");
    }
    fdatasync(fd);
    const double writeMBs = double(size) / since(t0) / 1048576.0;
    ::close(fd);

    double readMBs = 0, iops = 0;
    if (error->isEmpty() && !m_cancel) {
        fd = ::open(file.toLocal8Bit().constData(), O_RDONLY | (direct ? O_DIRECT : 0));
        if (!direct) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
        setProgress(0.4, "Sequential read");
        t0 = Clock::now();
        for (qint64 done = 0; done < size && !m_cancel; done += block) {
            if (::read(fd, buf, block) <= 0) break;
            if ((done / block) % 16 == 0) setProgress(0.4 + 0.3 * double(done) / double(size), "Sequential read");
        }
        readMBs = double(size) / since(t0) / 1048576.0;

        setProgress(0.72, "4K random read");
        if (!direct) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
        std::uniform_int_distribution<qint64> pick(0, size / 4096 - 1);
        quint64 ops = 0;
        t0 = Clock::now();
        while (since(t0) < 4.0 && !m_cancel) {
            if (pread(fd, buf, 4096, pick(rng) * 4096) != 4096) break;
            ++ops;
            if (ops % 2000 == 0) setProgress(0.72 + 0.27 * since(t0) / 4.0, "4K random read");
        }
        iops = double(ops) / since(t0);
        ::close(fd);
    }
    ::unlink(file.toLocal8Bit().constData());
    free(buf);
    if (!error->isEmpty() || m_cancel) return {};
    setProgress(1, "Done");
    return {{"path", path}, {"write", writeMBs}, {"read", readMBs}, {"iops", iops}, {"direct", direct},
            {"device", st.device().constData() ? QString::fromLocal8Bit(st.device()) : QString()}, {"fs", QString::fromLocal8Bit(st.fileSystemType())}};
}
