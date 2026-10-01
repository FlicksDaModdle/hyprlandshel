#include "recorder.h"

#include "monitor.h"
#include "procmodel.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QSaveFile>
#include <QTimer>

#include <cmath>

namespace {

const char *kUnit = "hyprshell-tasks-recorder.service";

QString unitPath() {
    QString c = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (c.isEmpty()) c = QDir::homePath() + "/.config";
    return c + "/systemd/user/" + kUnit;
}

int systemctl(const QStringList &args, QString *out = nullptr) {
    QProcess p;
    p.start("systemctl", QStringList{"--user"} + args);
    p.waitForFinished(8000);
    if (out) *out = QString::fromUtf8(p.readAllStandardOutput()).trimmed();
    return p.exitStatus() == QProcess::NormalExit ? p.exitCode() : -1;
}

double num(const QJsonValue &v) { return v.isDouble() ? v.toDouble() : 0; }

} // namespace

QString Recorder::dir() {
    QString d = qEnvironmentVariable("XDG_DATA_HOME");
    if (d.isEmpty()) d = QDir::homePath() + "/.local/share";
    return d + "/hyprshell-tasks/recorder";
}

Recorder::Recorder(QObject *parent) : QObject(parent) {
    const QJsonObject cfg = QJsonDocument::fromJson([] {
        QFile f(dir() + "/settings.json");
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
    }()).object();
    if (cfg.contains("keepDays")) m_keep = cfg.value("keepDays").toInt(7);
    refresh();
    auto *t = new QTimer(this);
    connect(t, &QTimer::timeout, this, &Recorder::refresh);
    t->start(30000);
}

void Recorder::setKeepDays(int d) {
    d = qBound(1, d, 90);
    if (d == m_keep) return;
    m_keep = d;
    QDir().mkpath(dir());
    QSaveFile f(dir() + "/settings.json");
    if (f.open(QIODevice::WriteOnly)) { f.write(QJsonDocument(QJsonObject{{"keepDays", d}}).toJson()); f.commit(); }
    emit changed();
}

void Recorder::refresh() {
    m_enabled = QFileInfo::exists(unitPath());
    QString state;
    systemctl({"is-active", kUnit}, &state);
    m_running = state == "active";
    m_days.clear();
    QDir d(dir());
    const QFileInfoList files = d.entryInfoList({"????-??-??.jsonl"}, QDir::Files, QDir::Name | QDir::Reversed);
    for (const QFileInfo &fi : files)
        m_days << QVariantMap{{"day", fi.completeBaseName()}, {"size", fi.size()}};
    m_apps.clear();
    const QJsonObject apps = QJsonDocument::fromJson([] {
        QFile f(dir() + "/apps.json");
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
    }()).object();
    m_since = qint64(apps.value("since").toDouble());
    const QJsonObject list = apps.value("apps").toObject();
    for (auto it = list.constBegin(); it != list.constEnd(); ++it) {
        QVariantMap m = it.value().toObject().toVariantMap();
        m["key"] = it.key();
        m_apps << m;
    }
    emit changed();
}

void Recorder::setEnabled(bool on) {
    if (on) {
        const QString exe = QCoreApplication::applicationFilePath();
        const QString unit = QString(
            "[Unit]\n"
            "Description=Hyprshell Tasks flight recorder\n"
            "After=graphical-session.target\n\n"
            "[Service]\n"
            "ExecStart=%1 --record\n"
            "Restart=on-failure\n"
            "RestartSec=10\n"
            // It should never be what slows the machine down.
            "Nice=15\n"
            "IOSchedulingClass=idle\n"
            "CPUWeight=20\n\n"
            "[Install]\n"
            "WantedBy=default.target\n").arg(exe);
        QDir().mkpath(QFileInfo(unitPath()).absolutePath());
        QSaveFile f(unitPath());
        if (!f.open(QIODevice::WriteOnly) || f.write(unit.toUtf8()) < 0 || !f.commit()) {
            emit actionDone(false, "Couldn't write the service file.");
            return;
        }
        systemctl({"daemon-reload"});
        const int rc = systemctl({"enable", "--now", kUnit});
        emit actionDone(rc == 0, rc == 0 ? "The flight recorder is on." : "systemd wouldn't start the recorder.");
    } else {
        systemctl({"disable", "--now", kUnit});
        QFile::remove(unitPath());
        systemctl({"daemon-reload"});
        emit actionDone(true, "The flight recorder is off. What it recorded is kept.");
    }
    refresh();
}

QVariantMap Recorder::loadDay(const QString &day, qint64 from, qint64 to, int buckets) const {
    QFile f(dir() + "/" + day + ".jsonl");
    QVariantMap out;
    if (!f.open(QIODevice::ReadOnly)) return out;
    struct S { double t; QJsonObject o; };
    QVector<S> samples;
    while (!f.atEnd()) {
        const QByteArray line = f.readLine();
        const QJsonObject o = QJsonDocument::fromJson(line).object();
        const double t = num(o.value("t"));
        if (t <= 0 || (from > 0 && t < from) || (to > 0 && t > to)) continue;
        samples.append({t, o});
    }
    if (samples.isEmpty()) return out;
    static const QStringList keys{"cpu", "mem", "swap", "psiCpu", "psiMem", "psiIo", "diskRead", "diskWrite",
                                  "netRx", "netTx", "gpu", "temp", "watts"};
    QHash<QString, QVariantList> cols;
    QVariantList ts, tops, topMems;
    const int n = samples.size();
    const int b = qMax(1, qMin(buckets, n));
    for (int i = 0; i < b; ++i) {
        const int lo = int(qint64(i) * n / b), hi = qMax(lo + 1, int(qint64(i + 1) * n / b));
        QHash<QString, double> sum;
        int busiest = lo;
        for (int j = lo; j < hi; ++j) {
            for (const QString &k : keys) sum[k] += num(samples[j].o.value(k));
            if (num(samples[j].o.value("cpu")) > num(samples[busiest].o.value("cpu"))) busiest = j;
        }
        ts << samples[lo].t;
        for (const QString &k : keys) cols[k] << sum.value(k) / (hi - lo);
        tops << samples[busiest].o.value("top").toArray().toVariantList();
        topMems << samples[busiest].o.value("topMem").toArray().toVariantList();
    }
    out["t"] = ts;
    for (const QString &k : keys) out[k] = cols.value(k);
    out["top"] = tops;
    out["topMem"] = topMems;
    out["first"] = samples.first().t;
    out["last"] = samples.last().t;
    out["count"] = n;
    return out;
}

// ── the recording process ────────────────────────────────────────────────
int Recorder::run(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QDir().mkpath(dir());
    Monitor mon;
    mon.setInterval(qEnvironmentVariableIntValue("HYPRSHELL_TASKS_RECORD_MS") > 0
                    ? qEnvironmentVariableIntValue("HYPRSHELL_TASKS_RECORD_MS") : 5000);
    mon.processes()->setMode("flat");      // cheapest layout; nobody looks at it here

    // Per-app totals carry over from earlier runs.
    QJsonObject saved = QJsonDocument::fromJson([] {
        QFile f(dir() + "/apps.json");
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
    }()).object();
    const QJsonObject base = saved.value("apps").toObject();
    const qint64 since = saved.contains("since") ? qint64(saved.value("since").toDouble()) : QDateTime::currentMSecsSinceEpoch();

    int keep = 7;
    {
        QFile f(dir() + "/settings.json");
        if (f.open(QIODevice::ReadOnly)) keep = QJsonDocument::fromJson(f.readAll()).object().value("keepDays").toInt(7);
    }
    auto prune = [keep] {
        QDir d(dir());
        const QStringList files = d.entryList({"????-??-??.jsonl"}, QDir::Files, QDir::Name);
        for (int i = 0; i + keep < files.size(); ++i) d.remove(files[i]);
    };
    prune();

    int tick = 0;
    QObject::connect(&mon, &Monitor::updated, &app, [&] {
        if (++tick < 2) return;             // the first sample has no rates yet
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        double dr = 0, dw = 0, rx = 0, tx = 0, gpu = 0;
        for (const QVariant &d : mon.disks()) { dr += d.toMap().value("readBps").toDouble(); dw += d.toMap().value("writeBps").toDouble(); }
        for (const QVariant &n : mon.networks()) { rx += n.toMap().value("rxBps").toDouble(); tx += n.toMap().value("txBps").toDouble(); }
        for (const QVariant &g : mon.gpus()) gpu = qMax(gpu, g.toMap().value("busy").toDouble());
        auto round1 = [](double v) { return std::round(v * 10) / 10; };
        QJsonArray top, topMem;
        for (const QVariant &p : mon.processes()->top("cpu", 3))
            top << QJsonArray{p.toMap().value("name").toString(), round1(p.toMap().value("value").toDouble())};
        for (const QVariant &p : mon.processes()->top("mem", 3))
            topMem << QJsonArray{p.toMap().value("name").toString(), std::round(p.toMap().value("value").toDouble() / 1048576)};
        const QJsonObject o{
            {"t", double(now)},
            {"cpu", round1(mon.cpu().value("percent").toDouble())},
            {"mem", round1(mon.memory().value("percent").toDouble())},
            {"swap", std::round(mon.memory().value("swapUsed").toDouble() / 1048576)},
            {"psiCpu", round1(mon.pressure().value("cpuSome").toDouble())},
            {"psiMem", round1(mon.pressure().value("memSome").toDouble())},
            {"psiIo", round1(mon.pressure().value("ioSome").toDouble())},
            {"diskRead", std::round(dr)}, {"diskWrite", std::round(dw)},
            {"netRx", std::round(rx)}, {"netTx", std::round(tx)},
            {"gpu", round1(qMax(0.0, gpu))},
            {"temp", round1(mon.cpu().value("temp").toDouble())},
            {"watts", round1(mon.battery().value("watts").toDouble())},
            {"top", top}, {"topMem", topMem}};
        QFile f(dir() + "/" + QDate::currentDate().toString(Qt::ISODate) + ".jsonl");
        if (f.open(QIODevice::Append)) f.write(QJsonDocument(o).toJson(QJsonDocument::Compact) + '\n');

        // Apps, every minute: this run's totals on top of the saved ones.
        if (tick % qMax(1, 60000 / mon.interval()) == 0) {
            QJsonObject apps = base;
            for (const QVariant &v : mon.processes()->appTotals()) {
                const QVariantMap a = v.toMap();
                QJsonObject was = apps.value(a.value("key").toString()).toObject();
                was["name"] = a.value("name").toString();
                was["icon"] = a.value("icon").toString();
                was["cpuSeconds"] = base.value(a.value("key").toString()).toObject().value("cpuSeconds").toDouble() + a.value("cpuSeconds").toDouble();
                was["gpuSeconds"] = base.value(a.value("key").toString()).toObject().value("gpuSeconds").toDouble() + a.value("gpuSeconds").toDouble();
                was["diskBytes"] = base.value(a.value("key").toString()).toObject().value("diskBytes").toDouble() + a.value("diskBytes").toDouble();
                was["lastSeen"] = a.value("lastSeen").toDouble();
                apps[a.value("key").toString()] = was;
            }
            QSaveFile af(dir() + "/apps.json");
            if (af.open(QIODevice::WriteOnly)) {
                af.write(QJsonDocument(QJsonObject{{"since", double(since)}, {"apps", apps}}).toJson(QJsonDocument::Compact));
                af.commit();
            }
        }
        if (tick % 720 == 0) prune();
    });
    return app.exec();
}
