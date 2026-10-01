#include "sys.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
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
