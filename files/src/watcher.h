#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// Watches one file and says when it changed, so the palette can follow the
// shell's theme.json without polling.
class Watcher : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)

public:
    explicit Watcher(QObject *parent = nullptr);

    QString path() const { return m_path; }
    void setPath(const QString &p);

signals:
    void pathChanged();
    void changed();

private:
    void rewatch();

    QFileSystemWatcher m_watcher;
    QString m_path;
};
