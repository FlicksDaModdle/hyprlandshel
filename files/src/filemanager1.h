#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

// org.freedesktop.FileManager1 — the interface every desktop asks when it
// wants "show me this file in a file manager".
//
// Firefox's "Open Containing Folder", GTK and Qt file dialogs' "Open
// Folder", and `gio open` on a selection all call this rather than running
// a command. Dolphin and Nautilus register it, which is why they kept
// answering even after this became the default handler for
// inode/directory: the MIME default decides who opens a *folder*, and this
// decides who is asked to *reveal* something. They are different questions
// and the answer was only given to one of them.
//
// Three methods, per the spec:
//   ShowFolders(as uris, s startupId)          open each as a folder
//   ShowItems(as uris, s startupId)            open each item's folder,
//                                              with the item selected
//   ShowItemProperties(as uris, s startupId)   open the properties sheet
class FileManager1 : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.FileManager1")

public:
    explicit FileManager1(QObject *parent = nullptr);

    // Registers the service and object on the session bus. False when the
    // name is already taken — Dolphin or Nautilus got there first — which
    // is worth saying out loud rather than failing silently, since the
    // symptom is "it still opens the wrong thing".
    bool attach();

signals:
    // Emitted on the Qt side for the QML to act on. Paths, not URIs: by
    // this point they have been decoded once and only once.
    void showFolders(const QStringList &paths);
    void showItems(const QStringList &paths);
    void showItemProperties(const QStringList &paths);

public slots:
    // The D-Bus surface. Names and signatures are the spec's.
    Q_SCRIPTABLE void ShowFolders(const QStringList &uris, const QString &startupId);
    Q_SCRIPTABLE void ShowItems(const QStringList &uris, const QString &startupId);
    Q_SCRIPTABLE void ShowItemProperties(const QStringList &uris, const QString &startupId);

private:
    static QStringList toPaths(const QStringList &uris);
};
