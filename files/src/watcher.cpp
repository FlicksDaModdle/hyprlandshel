#include "watcher.h"

#include <QFileInfo>
#include <QTimer>

Watcher::Watcher(QObject *parent) : QObject(parent) {
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] {
        // An editor that writes by renaming drops the watch, so it is put
        // back. The delay is because the new file is not always in place the
        // instant the old one goes.
        QTimer::singleShot(50, this, [this] {
            rewatch();
            emit changed();
        });
    });
}

void Watcher::setPath(const QString &p) {
    if (m_path == p) return;
    m_path = p;
    rewatch();
    emit pathChanged();
}

void Watcher::rewatch() {
    if (!m_watcher.files().isEmpty()) m_watcher.removePaths(m_watcher.files());
    if (!m_path.isEmpty() && QFileInfo::exists(m_path)) m_watcher.addPath(m_path);
}
