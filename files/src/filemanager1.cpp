#include "filemanager1.h"

#include <QDBusConnection>
#include <QUrl>
#include <QLoggingCategory>

FileManager1::FileManager1(QObject *parent) : QObject(parent) {}

QStringList FileManager1::toPaths(const QStringList &uris) {
    QStringList out;
    for (const QString &u : uris) {
        // Callers are supposed to send file:// URIs and mostly do, but a
        // bare path turns up often enough that rejecting it would only
        // make this look broken.
        const QUrl url(u);
        const QString path = url.isLocalFile() ? url.toLocalFile()
                           : (u.startsWith(QLatin1Char('/')) ? u : QString());
        if (!path.isEmpty()) out.append(path);
    }
    return out;
}

bool FileManager1::attach() {
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) return false;
    if (!bus.registerObject(QStringLiteral("/org/freedesktop/FileManager1"),
                            this, QDBusConnection::ExportScriptableSlots))
        return false;
    // Not queued and not replacing: whoever holds it is handling these
    // already, and taking it from a running Dolphin mid-session would be a
    // surprise. Losing the race is reported, not worked around.
    return bus.registerService(QStringLiteral("org.freedesktop.FileManager1"));
}

void FileManager1::ShowFolders(const QStringList &uris, const QString &) {
    emit showFolders(toPaths(uris));
}

void FileManager1::ShowItems(const QStringList &uris, const QString &) {
    emit showItems(toPaths(uris));
}

void FileManager1::ShowItemProperties(const QStringList &uris, const QString &) {
    emit showItemProperties(toPaths(uris));
}
