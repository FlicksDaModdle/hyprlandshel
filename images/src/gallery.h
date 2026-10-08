#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// What the viewer needs from outside QML: the pictures beside the one
// open, what a file is, and the few things done to one — the bin, the
// clipboard, the file manager, the wallpaper.
class Gallery : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The files given on the command line, as absolute paths.
    Q_PROPERTY(QStringList startFiles READ startFiles CONSTANT)

public:
    explicit Gallery(QObject *parent = nullptr);

    QStringList startFiles() const { return m_start; }
    static void setStartFiles(const QStringList &files);

    // Every picture in `path`'s folder (or in `path`, a folder), in the
    // order a person would number them: 2 before 10.
    Q_INVOKABLE QStringList siblings(const QString &path) const;
    // name, folder, bytes, modified (ms), width, height, format, animated
    Q_INVOKABLE QVariantMap info(const QString &path) const;
    Q_INVOKABLE bool isImage(const QString &path) const;
    Q_INVOKABLE QString fileUrl(const QString &path) const;
    // "*.png *.jpg …" — every format this Qt can read.
    Q_INVOKABLE QString patterns() const;

    Q_INVOKABLE bool trash(const QString &path);
    Q_INVOKABLE bool copyImage(const QString &path);
    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE void showInFolder(const QString &path);
    Q_INVOKABLE bool setWallpaper(const QString &path);
    Q_INVOKABLE void openWith(const QString &path);
    // Puts up the file manager's open dialog; picked() follows.
    Q_INVOKABLE void pick(const QString &startDir);

signals:
    void picked(const QString &path);

private:
    static QStringList s_start;
    QStringList m_start;
    QProcess *m_picker = nullptr;
};
