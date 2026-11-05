#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

// The handful of things the QML needs from the system that are not a
// process: the environment, a detached launch, and reading and writing a
// file. Quickshell supplied these; standing alone, this does.
class Sys : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Sys(QObject *parent = nullptr);

    Q_INVOKABLE QString env(const QString &name) const;
    Q_INVOKABLE QString home() const;
    Q_INVOKABLE QString configDir() const;

    // Launches and forgets. Used for opening a file in its own application,
    // where waiting for it would mean holding a process for as long as the
    // document is open.
    Q_INVOKABLE void execDetached(const QStringList &argv) const;

    Q_INVOKABLE QString readFile(const QString &path) const;
    Q_INVOKABLE bool writeFile(const QString &path, const QString &text) const;

    // The directory a path names, created if it is not there. Returns false
    // when it could not be made, so a write can say so rather than failing
    // silently later.
    Q_INVOKABLE bool ensureDir(const QString &path) const;

    // Whether anything is at a path — a file, a folder, a dangling link.
    Q_INVOKABLE bool exists(const QString &path) const;

    // The file name suffixes ("png", "tar.gz") a MIME type covers, from the
    // system's shared MIME database: an exact type with every type that
    // counts as one (so "text/plain" takes .py and .c, which are text),
    // aliases resolved, and a whole group for "image/*". Empty when the
    // type is unknown, so the caller can tell "nothing" from "anything".
    Q_INVOKABLE QStringList mimeSuffixes(const QString &type) const;

    // This program's own executable, to run it again as `--pick` for a
    // folder dialog of its own.
    Q_INVOKABLE QString appPath() const;
};
