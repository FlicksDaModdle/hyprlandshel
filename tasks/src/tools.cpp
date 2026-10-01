#include "tools.h"

#include "appindex.h"
#include "monitor.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>
#include <QtEndian>

#include <cstring>

#include <dirent.h>
#include <unistd.h>

namespace {

QByteArray slurp(const QString &path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}
QString text(const QString &path) { return QString::fromUtf8(slurp(path)).trimmed(); }

QString autostartDir() {
    QString c = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (c.isEmpty()) c = QDir::homePath() + "/.config";
    return c + "/autostart";
}
QStringList systemAutostartDirs() {
    QString dirs = qEnvironmentVariable("XDG_CONFIG_DIRS");
    if (dirs.isEmpty()) dirs = "/etc/xdg";
    QStringList out;
    for (const QString &d : dirs.split(':', Qt::SkipEmptyParts)) out << d + "/autostart";
    return out;
}

// One .desktop file's [Desktop Entry] group, keys as written.
QHash<QString, QString> readEntry(const QString &path) {
    QHash<QString, QString> kv;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return kv;
    bool main = false;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.startsWith('[')) { main = line == "[Desktop Entry]"; continue; }
        if (!main || line.startsWith('#')) continue;
        const int eq = line.indexOf('=');
        if (eq > 0) kv.insert(line.left(eq).trimmed(), line.mid(eq + 1).trimmed());
    }
    return kv;
}

// The same file with some keys set (or removed, given an empty value).
QString withKeys(const QString &original, const QHash<QString, QString> &set) {
    QStringList out;
    bool main = false, done = false;
    QSet<QString> written;
    const QStringList lines = original.split('\n');
    for (int i = 0; i < lines.size(); ++i) {
        const QString line = lines[i];
        const QString t = line.trimmed();
        if (t.startsWith('[')) {
            if (main && !done) {
                for (auto it = set.cbegin(); it != set.cend(); ++it)
                    if (!written.contains(it.key()) && !it.value().isEmpty()) out << it.key() + "=" + it.value();
                done = true;
            }
            main = t == "[Desktop Entry]";
            out << line;
            continue;
        }
        const int eq = t.indexOf('=');
        if (main && eq > 0 && set.contains(t.left(eq).trimmed())) {
            const QString k = t.left(eq).trimmed();
            written.insert(k);
            if (!set.value(k).isEmpty()) out << k + "=" + set.value(k);
            continue;
        }
        out << line;
    }
    if (main && !done)
        for (auto it = set.cbegin(); it != set.cend(); ++it)
            if (!written.contains(it.key()) && !it.value().isEmpty()) out << it.key() + "=" + it.value();
    QString s = out.join('\n');
    if (!s.endsWith('\n')) s += '\n';
    return s;
}

bool save(const QString &path, const QString &text) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) return false;
    f.write(text.toUtf8());
    return f.commit();
}

// /proc/net/tcp's addresses: hex, in the kernel's byte order.
QString hexAddr(const QString &hex, bool v6) {
    if (!v6) {
        // The address's bytes in network order, printed as a host-order
        // number: back to bytes, then read them as the network order they are.
        const quint32 raw = qToLittleEndian(hex.toUInt(nullptr, 16));
        return QHostAddress(qFromBigEndian(raw)).toString();
    }
    Q_IPV6ADDR addr;
    for (int word = 0; word < 4; ++word)
        for (int b = 0; b < 4; ++b)
            addr[word * 4 + b] = quint8(hex.mid(word * 8 + (3 - b) * 2, 2).toUInt(nullptr, 16));
    QHostAddress h(addr);
    // IPv4 carried in IPv6 reads better as IPv4.
    bool ok = false;
    const quint32 v4 = h.toIPv4Address(&ok);
    return ok ? QHostAddress(v4).toString() : h.toString();
}

QString pciClass(quint32 cls) {
    const quint32 major = cls >> 16, sub = (cls >> 8) & 0xff;
    switch (major) {
    case 0x01: return sub == 0x08 ? "NVMe controller" : sub == 0x06 ? "SATA controller" : "Storage controller";
    case 0x02: return sub == 0x80 ? "Network controller" : "Ethernet controller";
    case 0x03: return "Display adapter";
    case 0x04: return sub == 0x03 ? "Audio device" : "Multimedia device";
    case 0x05: return "Memory controller";
    case 0x06: return "Bridge";
    case 0x07: return "Communication controller";
    case 0x08: return "System peripheral";
    case 0x09: return "Input device";
    case 0x0c: return sub == 0x03 ? "USB controller" : sub == 0x05 ? "SMBus" : sub == 0x80 ? "Serial bus" : "Serial bus controller";
    case 0x0d: return "Wireless controller";
    case 0x10: return "Encryption controller";
    case 0x11: return "Signal processing";
    case 0x12: return "Processing accelerator";
    case 0x13: return "Instrumentation";
    default: return "Device";
    }
}

} // namespace

Tools::Tools(QObject *parent) : QObject(parent), m_apps(new AppIndex(this)) {}

QString Tools::home() const { return QDir::homePath(); }
QString Tools::configPath() const {
    QString c = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (c.isEmpty()) c = QDir::homePath() + "/.config";
    return c + "/hyprshell-tasks";
}
QString Tools::dataPath() const {
    QString d = qEnvironmentVariable("XDG_DATA_HOME");
    if (d.isEmpty()) d = QDir::homePath() + "/.local/share";
    return d + "/hyprshell-tasks";
}
QString Tools::readFile(const QString &path) const { return QString::fromUtf8(slurp(path)); }
bool Tools::writeFile(const QString &path, const QString &t) const { return save(path, t); }

// ── Startup apps ─────────────────────────────────────────────────────────
QVariantList Tools::startupEntries() const {
    QHash<QString, QVariantMap> byId;
    const QString desktop = qEnvironmentVariable("XDG_CURRENT_DESKTOP");
    auto add = [&](const QString &dir, bool system) {
        for (const QFileInfo &fi : QDir(dir).entryInfoList({"*.desktop"}, QDir::Files)) {
            const QString id = fi.completeBaseName();
            if (byId.contains(id) && system) {
                // The user's file overrides the system one; note that a
                // system entry lies behind it, so turning it back on can
                // simply remove the override.
                byId[id]["overridesSystem"] = true;
                byId[id]["systemPath"] = fi.absoluteFilePath();
                continue;
            }
            const QHash<QString, QString> e = readEntry(fi.absoluteFilePath());
            const bool hidden = e.value("Hidden") == "true" || e.value("X-GNOME-Autostart-enabled") == "false";
            bool here = true;
            if (e.contains("OnlyShowIn")) {
                here = false;
                for (const QString &d : e.value("OnlyShowIn").split(';', Qt::SkipEmptyParts))
                    if (desktop.split(':').contains(d, Qt::CaseInsensitive)) here = true;
            }
            for (const QString &d : e.value("NotShowIn").split(';', Qt::SkipEmptyParts))
                if (desktop.split(':').contains(d, Qt::CaseInsensitive)) here = false;
            QVariantMap m{{"id", id}, {"name", e.value("Name", id)}, {"exec", e.value("Exec")},
                          {"comment", e.value("Comment")}, {"icon", e.value("Icon")},
                          {"enabled", !hidden}, {"thisDesktop", here}, {"source", "autostart"},
                          {"path", fi.absoluteFilePath()}, {"system", system},
                          {"unit", "app-" + id + "@autostart.service"}};
            byId.insert(id, m);
        }
    };
    add(autostartDir(), false);
    for (const QString &d : systemAutostartDirs()) add(d, true);
    QVariantList out;
    for (const QVariantMap &m : byId) out << m;
    return out;
}

bool Tools::setAutostart(const QString &id, bool enabled) {
    const QString user = autostartDir() + "/" + id + ".desktop";
    QString systemPath;
    for (const QString &d : systemAutostartDirs())
        if (QFileInfo::exists(d + "/" + id + ".desktop")) { systemPath = d + "/" + id + ".desktop"; break; }
    if (QFileInfo::exists(user)) {
        const QString original = QString::fromUtf8(slurp(user));
        // An override that only existed to turn a system entry off is
        // removed rather than kept around saying Hidden=false.
        if (enabled && !systemPath.isEmpty()) {
            const QHash<QString, QString> mine = readEntry(user), theirs = readEntry(systemPath);
            QHash<QString, QString> a = mine, b = theirs;
            a.remove("Hidden"); a.remove("X-GNOME-Autostart-enabled");
            b.remove("Hidden"); b.remove("X-GNOME-Autostart-enabled");
            if (a == b) return QFile::remove(user);
        }
        return save(user, withKeys(original, {{"Hidden", enabled ? QString() : "true"},
                                              {"X-GNOME-Autostart-enabled", enabled ? QString() : "false"}}));
    }
    if (systemPath.isEmpty()) return false;
    if (enabled) return true;
    return save(user, withKeys(QString::fromUtf8(slurp(systemPath)), {{"Hidden", "true"}}));
}

bool Tools::addAutostart(const QString &desktopId) {
    const QVariantMap app = m_apps->byId(desktopId);
    if (app.isEmpty()) return false;
    return QFile::copy(app.value("path").toString(), autostartDir() + "/" + desktopId + ".desktop")
        || save(autostartDir() + "/" + desktopId + ".desktop", QString::fromUtf8(slurp(app.value("path").toString())));
}

bool Tools::removeAutostart(const QString &id) { return QFile::remove(autostartDir() + "/" + id + ".desktop"); }

QVariantList Tools::applications() const { return m_apps->all(); }

// ── Connections ──────────────────────────────────────────────────────────
QVariantList Tools::connections() const {
    // Socket inode → the process holding it. Only your own processes' file
    // descriptors are readable; the rest are listed without an owner.
    QHash<quint64, QPair<int, QString>> owner;
    DIR *proc = opendir("/proc");
    if (proc) {
        while (dirent *e = readdir(proc)) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
            const QString fdDir = QString("/proc/%1/fd/").arg(QString::fromLatin1(e->d_name));
            DIR *d = opendir(fdDir.toLocal8Bit().constData());
            if (!d) continue;
            QString comm;
            char target[128];
            while (dirent *f = readdir(d)) {
                if (f->d_name[0] == '.') continue;
                const QByteArray link = fdDir.toLocal8Bit() + f->d_name;
                const ssize_t n = readlink(link.constData(), target, sizeof target - 1);
                if (n > 8 && std::strncmp(target, "socket:[", 8) == 0) {
                    target[n] = 0;
                    const quint64 inode = QByteArray(target + 8, int(n) - 9).toULongLong();
                    if (comm.isEmpty()) comm = text(QString("/proc/%1/comm").arg(QString::fromLatin1(e->d_name)));
                    owner.insert(inode, {atoi(e->d_name), comm});
                }
            }
            closedir(d);
        }
        closedir(proc);
    }
    static const char *states[] = {"", "Established", "Connecting", "Received SYN", "Closing (FIN wait 1)",
                                   "Closing (FIN wait 2)", "Time wait", "Closed", "Close wait", "Last ACK",
                                   "Listening", "Closing"};
    QVariantList out;
    for (const char *file : {"tcp", "tcp6", "udp", "udp6"}) {
        const bool v6 = QByteArray(file).endsWith('6');
        const bool udp = QByteArray(file).startsWith("udp");
        const QList<QByteArray> lines = slurp(QString("/proc/net/") + file).split('\n');
        for (int i = 1; i < lines.size(); ++i) {
            const QList<QByteArray> f = lines[i].simplified().split(' ');
            if (f.size() < 10) continue;
            const QList<QByteArray> l = f[1].split(':'), r = f[2].split(':');
            const int st = f[3].toInt(nullptr, 16);
            const quint64 inode = f[9].toULongLong();
            QVariantMap m{{"proto", udp ? (v6 ? "UDPv6" : "UDP") : (v6 ? "TCPv6" : "TCP")},
                          {"local", hexAddr(QString::fromLatin1(l.value(0)), v6)},
                          {"localPort", l.value(1).toInt(nullptr, 16)},
                          {"remote", hexAddr(QString::fromLatin1(r.value(0)), v6)},
                          {"remotePort", r.value(1).toInt(nullptr, 16)},
                          {"state", udp ? (st == 1 ? "Connected" : "Open") : QString::fromLatin1(st < 12 ? states[st] : "")},
                          {"uid", f[7].toInt()}, {"inode", double(inode)}};
            if (owner.contains(inode)) { m["pid"] = owner[inode].first; m["process"] = owner[inode].second; }
            else { m["pid"] = 0; m["process"] = ""; }
            out << m;
        }
    }
    return out;
}

// ── Drivers ──────────────────────────────────────────────────────────────
QVariantList Tools::pciDevices() const {
    QVariantList out;
    const QString base = Monitor::sys("/sys/bus/pci/devices/");
    for (const QString &slot : QDir(base).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::System)) {
        const QString d = base + slot + "/";
        const QString vendor = text(d + "vendor").mid(2), device = text(d + "device").mid(2);
        const QString driver = QFileInfo(QFileInfo(d + "driver").symLinkTarget()).fileName();
        const quint32 cls = text(d + "class").toUInt(nullptr, 16);
        out << QVariantMap{{"slot", slot}, {"name", Monitor::pciName(vendor, device)},
                           {"vendor", vendor}, {"device", device}, {"driver", driver},
                           {"class", pciClass(cls)}, {"classCode", double(cls)},
                           {"module", driver.isEmpty() ? QString() : QFileInfo(QFileInfo(d + "driver/module").symLinkTarget()).fileName()},
                           {"version", driver.isEmpty() ? QString() : text("/sys/module/" + driver + "/version")},
                           {"power", text(d + "power/runtime_status")}};
    }
    return out;
}

QVariantList Tools::usbDevices() const {
    QVariantList out;
    const QString base = Monitor::sys("/sys/bus/usb/devices/");
    for (const QString &dev : QDir(base).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::System)) {
        if (dev.contains(':')) continue;                // an interface
        const QString d = base + dev + "/";
        const QString vid = text(d + "idVendor");
        if (vid.isEmpty()) continue;
        QStringList drivers;
        for (const QString &iface : QDir(d).entryList({dev + ":*"}, QDir::Dirs | QDir::System)) {
            const QString drv = QFileInfo(QFileInfo(d + iface + "/driver").symLinkTarget()).fileName();
            if (!drv.isEmpty() && !drivers.contains(drv)) drivers << drv;
        }
        out << QVariantMap{{"bus", dev}, {"vendor", vid}, {"product", text(d + "idProduct")},
                           {"name", text(d + "product")}, {"maker", text(d + "manufacturer")},
                           {"speed", text(d + "speed").toInt()}, {"drivers", drivers},
                           {"hub", text(d + "bDeviceClass") == "09"}};
    }
    return out;
}

QVariantList Tools::kernelModules() const {
    QVariantList out;
    for (const QByteArray &line : slurp("/proc/modules").split('\n')) {
        const QList<QByteArray> f = line.split(' ');
        if (f.size() < 5) continue;
        QStringList by = QString::fromLatin1(f[3]).split(',', Qt::SkipEmptyParts);
        by.removeAll("-");
        out << QVariantMap{{"name", QString::fromLatin1(f[0])}, {"size", f[1].toLongLong()},
                           {"uses", f[2].toInt()}, {"usedBy", by}, {"state", QString::fromLatin1(f[4])},
                           {"version", text("/sys/module/" + QString::fromLatin1(f[0]) + "/version")}};
    }
    return out;
}

QVariantMap Tools::moduleInfo(const QString &name) const {
    QProcess p;
    p.start("modinfo", {name});
    p.waitForFinished(3000);
    QVariantMap m;
    QStringList params;
    for (const QString &line : QString::fromUtf8(p.readAllStandardOutput()).split('\n')) {
        const int c = line.indexOf(':');
        if (c < 0) continue;
        const QString k = line.left(c).trimmed(), v = line.mid(c + 1).trimmed();
        if (k == "parm") params << v;
        else if (!m.contains(k)) m.insert(k, v);
    }
    m["parameters"] = params;
    return m;
}

// ── Installed apps ───────────────────────────────────────────────────────
void Tools::loadPackages() {
    auto *pac = new QProcess(this);
    pac->setProcessEnvironment([] { auto e = QProcessEnvironment::systemEnvironment(); e.insert("LC_ALL", "C"); return e; }());
    connect(pac, &QProcess::finished, this, [this, pac] {
        QVariantList out;
        QVariantMap cur;
        auto size = [](const QString &s) {
            const QStringList f = s.split(' ', Qt::SkipEmptyParts);
            double v = f.value(0).toDouble();
            const QString u = f.value(1);
            if (u == "KiB") v *= 1024; else if (u == "MiB") v *= 1048576; else if (u == "GiB") v *= 1073741824.0;
            return v;
        };
        for (const QString &line : QString::fromUtf8(pac->readAllStandardOutput()).split('\n')) {
            if (line.trimmed().isEmpty()) {
                if (!cur.isEmpty()) {
                    cur["source"] = "pacman";
                    cur["app"] = !m_apps->byExec(cur.value("name").toString()).isEmpty()
                              || !m_apps->byId(cur.value("name").toString()).isEmpty();
                    out << cur;
                }
                cur.clear();
                continue;
            }
            const int c = line.indexOf(" : ");
            if (c < 0) continue;
            const QString k = line.left(c).trimmed(), v = line.mid(c + 3).trimmed();
            if (k == "Name") cur["name"] = v;
            else if (k == "Version") cur["version"] = v;
            else if (k == "Description") cur["description"] = v;
            else if (k == "Installed Size") cur["size"] = size(v);
            else if (k == "Install Date") cur["installed"] = v;
            else if (k == "Install Reason") cur["explicit"] = v.startsWith("Explicitly");
            else if (k == "URL") cur["url"] = v;
            else if (k == "Required By") cur["requiredBy"] = v == "None" ? 0 : int(v.split(' ', Qt::SkipEmptyParts).size());
        }
        pac->deleteLater();
        // Then Flatpak, if there is one.
        auto *fp = new QProcess(this);
        connect(fp, &QProcess::finished, this, [this, fp, out]() mutable {
            for (const QString &line : QString::fromUtf8(fp->readAllStandardOutput()).split('\n')) {
                const QStringList f = line.split('\t');
                if (f.size() < 5) continue;
                QString sz = f[3];
                double s = sz.split(QChar(0xa0)).value(0).split(' ').value(0).toDouble();
                if (sz.contains("GB")) s *= 1e9; else if (sz.contains("MB")) s *= 1e6; else if (sz.contains("kB")) s *= 1e3;
                out << QVariantMap{{"name", f[1]}, {"id", f[0]}, {"version", f[2]}, {"size", s},
                                   {"description", f.value(5)}, {"source", "flatpak"}, {"origin", f[4]},
                                   {"explicit", true}, {"app", true}};
            }
            fp->deleteLater();
            emit packagesLoaded(out);
        });
        connect(fp, &QProcess::errorOccurred, this, [this, fp, out](QProcess::ProcessError e) {
            if (e != QProcess::FailedToStart) return;
            fp->deleteLater();
            emit packagesLoaded(out);
        });
        fp->start("flatpak", {"list", "--app", "--columns=application,name,version,size,origin,description"});
    });
    connect(pac, &QProcess::errorOccurred, this, [this, pac](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart) return;
        pac->deleteLater();
        emit packagesLoaded({});
    });
    pac->start("pacman", {"-Qi"});
}

// ── Services ─────────────────────────────────────────────────────────────
void Tools::loadServices(bool user) {
    QStringList scope;
    if (user) scope << "--user";
    auto *files = new QProcess(this);
    connect(files, &QProcess::finished, this, [this, files, scope, user] {
        // Every installed unit file and whether it is enabled.
        QHash<QString, QString> enabled;
        for (const QString &line : QString::fromUtf8(files->readAllStandardOutput()).split('\n')) {
            const QStringList f = line.split(' ', Qt::SkipEmptyParts);
            if (f.size() >= 2) enabled.insert(f[0], f[1]);
        }
        files->deleteLater();
        // Then what the manager knows about the loaded ones.
        auto *show = new QProcess(this);
        connect(show, &QProcess::finished, this, [this, show, enabled, user] {
            QHash<QString, QVariantMap> units;
            QVariantMap cur;
            auto flush = [&] {
                const QString id = cur.value("unit").toString();
                if (!id.isEmpty()) units.insert(id, cur);
                cur.clear();
            };
            for (const QString &line : QString::fromUtf8(show->readAllStandardOutput()).split('\n')) {
                if (line.isEmpty()) { flush(); continue; }
                const int eq = line.indexOf('=');
                if (eq < 0) continue;
                const QString k = line.left(eq), v = line.mid(eq + 1);
                if (k == "Id") cur["unit"] = v;
                else if (k == "Description") cur["description"] = v;
                else if (k == "ActiveState") cur["active"] = v;
                else if (k == "SubState") cur["sub"] = v;
                else if (k == "LoadState") cur["load"] = v;
                else if (k == "UnitFileState") cur["enabled"] = v;
                else if (k == "MainPID") cur["pid"] = v.toInt();
                else if (k == "MemoryCurrent") cur["memory"] = v.startsWith('[') || v.size() > 18 ? -1.0 : v.toDouble();
                else if (k == "CPUUsageNSec") cur["cpuSeconds"] = v.startsWith('[') || v.size() > 18 ? -1.0 : v.toDouble() / 1e9;
                else if (k == "FragmentPath") cur["path"] = v;
            }
            flush();
            show->deleteLater();
            // Installed but never loaded: listed too, as stopped.
            for (auto it = enabled.cbegin(); it != enabled.cend(); ++it) {
                if (units.contains(it.key()) || it.key().contains("@.")) continue;
                units.insert(it.key(), QVariantMap{{"unit", it.key()}, {"active", "inactive"}, {"sub", "dead"},
                                                   {"enabled", it.value()}, {"pid", 0}, {"memory", -1.0},
                                                   {"cpuSeconds", -1.0}, {"description", ""}});
            }
            QVariantList out;
            for (QVariantMap m : units) {
                if (m.value("load").toString() == "not-found") continue;
                if (m.value("enabled").toString().isEmpty()) m["enabled"] = enabled.value(m.value("unit").toString(), "static");
                out << m;
            }
            emit servicesLoaded(user, out);
        });
        show->start("systemctl", scope + QStringList{"show", "--no-pager", "*.service",
                                                     "--property=Id,Description,ActiveState,SubState,LoadState,UnitFileState,MainPID,MemoryCurrent,CPUUsageNSec,FragmentPath"});
    });
    files->start("systemctl", scope + QStringList{"list-unit-files", "--type=service", "--no-legend", "--no-pager"});
}

void Tools::serviceAction(bool user, const QString &unit, const QString &action) {
    static const QStringList allowed{"start", "stop", "restart", "enable", "disable", "reload"};
    if (!allowed.contains(action)) return;
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p, unit, action](int code) {
        const QString err = QString::fromUtf8(p->readAllStandardError()).trimmed();
        if (code == 0) emit actionDone(true, QString("%1: %2 done.").arg(unit, action));
        else if (err.contains("Interactive authentication required"))
            emit actionDone(false, "That needs an administrator password, and no polkit agent is running to ask for it.");
        else emit actionDone(false, err.isEmpty() ? QString("systemctl %1 failed.").arg(action) : err);
        p->deleteLater();
    });
    QStringList args;
    if (user) args << "--user";
    args << action << unit;
    p->start("systemctl", args);
}

void Tools::sessions() {
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p] {
        QVariantList out;
        const QJsonDocument doc = QJsonDocument::fromJson(p->readAllStandardOutput());
        if (doc.isArray()) {
            for (const QJsonValue &v : doc.array()) out << v.toObject().toVariantMap();
        }
        p->deleteLater();
        emit sessionsLoaded(out);
    });
    p->start("loginctl", {"list-sessions", "--output=json"});
}

// ── odds and ends ────────────────────────────────────────────────────────
void Tools::focusWindow(const QString &address) const {
    const QString sig = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
    if (sig.isEmpty() || address.isEmpty()) return;
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty()) runtime = QString("/run/user/%1").arg(getuid());
    auto *s = new QLocalSocket(const_cast<Tools *>(this));
    connect(s, &QLocalSocket::connected, s, [s, address] {
        // Hyprland under a Lua config evaluates a dispatch as Lua.
        s->write(QString("dispatch hl.dsp.focus({ window = \"address:%1\" })").arg(address).toUtf8());
        s->flush();
    });
    connect(s, &QLocalSocket::disconnected, s, &QObject::deleteLater);
    connect(s, &QLocalSocket::errorOccurred, s, &QObject::deleteLater);
    s->connectToServer(runtime + "/hypr/" + sig + "/.socket.sock");
}

void Tools::showInFolder(const QString &path) const {
    QDBusMessage m = QDBusMessage::createMethodCall("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                                                    "org.freedesktop.FileManager1", "ShowItems");
    m << QStringList{QUrl::fromLocalFile(path).toString()} << QString();
    if (!QDBusConnection::sessionBus().send(m))
        QProcess::startDetached("xdg-open", {QFileInfo(path).absolutePath()});
}

void Tools::openTerminal(const QStringList &argv) const {
    for (const QString &term : {QString("hyprshell-term"), QString("xdg-terminal-exec"), QString("kitty"), QString("foot")}) {
        const QString exe = QStandardPaths::findExecutable(term);
        if (exe.isEmpty()) continue;
        QStringList a;
        if (term != "xdg-terminal-exec") a << "-e";
        QProcess::startDetached(exe, a + argv);
        return;
    }
}

void Tools::runDetached(const QStringList &argv) const {
    if (!argv.isEmpty()) QProcess::startDetached(argv.first(), argv.mid(1));
}
