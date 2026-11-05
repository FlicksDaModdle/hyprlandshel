#include "sys.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>

Sys::Sys(QObject *parent) : QObject(parent) {}

QString Sys::env(const QString &name) const {
    return qEnvironmentVariable(name.toUtf8().constData());
}

QString Sys::home() const {
    const QString h = qEnvironmentVariable("HOME");
    return h.isEmpty() ? QDir::homePath() : h;
}

QString Sys::configDir() const {
    const QString x = qEnvironmentVariable("XDG_CONFIG_HOME");
    return x.isEmpty() ? home() + QStringLiteral("/.config") : x;
}

void Sys::execDetached(const QStringList &argv) const {
    if (argv.isEmpty()) return;
    QProcess::startDetached(argv.first(), argv.mid(1));
}

QString Sys::readFile(const QString &path) const {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    return QString::fromUtf8(f.readAll());
}

bool Sys::writeFile(const QString &path, const QString &text) const {
    if (!ensureDir(QFileInfo(path).absolutePath())) return false;
    // QSaveFile writes to a temporary and renames, so an interrupted write
    // cannot leave a half-written settings file behind.
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) return false;
    f.write(text.toUtf8());
    return f.commit();
}

bool Sys::ensureDir(const QString &path) const {
    if (path.isEmpty()) return false;
    QDir d;
    return d.mkpath(path);
}

bool Sys::exists(const QString &path) const {
    if (path.isEmpty()) return false;
    const QFileInfo fi(path);
    return fi.exists() || fi.isSymLink();
}

QString Sys::appPath() const {
    return QCoreApplication::applicationFilePath();
}

QStringList Sys::mimeSuffixes(const QString &type) const {
    static QMimeDatabase db;
    const QString t = type.trimmed().toLower();
    QStringList out;
    const auto add = [&out](const QMimeType &m) {
        for (const QString &suf : m.suffixes())
            if (!out.contains(suf, Qt::CaseInsensitive)) out.append(suf);
    };
    if (t.endsWith(QStringLiteral("/*"))) {
        const QString group = t.left(t.size() - 1);           // "image/"
        for (const QMimeType &m : db.allMimeTypes())
            if (m.name().startsWith(group)) add(m);
        return out;
    }
    const QMimeType want = db.mimeTypeForName(t);
    if (!want.isValid()) return out;
    add(want);
    for (const QMimeType &m : db.allMimeTypes())
        if (m.name() != want.name() && m.inherits(want.name())) add(m);
    return out;
}
