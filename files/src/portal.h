#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <QDBusObjectPath>
#include <QDBusMessage>
#include <QDBusContext>
#include <QDBusAbstractAdaptor>
#include <QHash>

// org.freedesktop.impl.portal.FileChooser — the interface behind every
// "Save as…" and "Upload" dialog a sandboxed or portal-using application
// shows.
//
// Firefox does not open a file dialog itself. It asks xdg-desktop-portal,
// which asks whichever *backend* is configured for the desktop, and on a
// machine with the KDE backend installed that backend is Dolphin's. That
// is why saving a download landed there no matter what the MIME defaults
// said: the choice was never Firefox's to make, and never the MIME
// database's to answer.
//
// This is a backend. It is chosen by a .portal file naming this interface
// and the desktop it applies to; see files/hyprshell.portal.
//
// Three methods, each returning immediately and answering later on the
// Request object the caller handed us:
//   OpenFile(o handle, s app_id, s parent_window, s title, a{sv} options)
//   SaveFile(...)      same shape, plus current_name / current_folder
//   SaveFiles(...)     a folder to put several named files in
//
// The reply is (u response, a{sv} results): response 0 chose something, 1
// was cancelled, 2 went wrong. `results` carries "uris" as a list.
// QDBusContext is on this class and not on the adaptor below, although it
// is the adaptor's slots that need it.
//
// Qt sets the call context on the object that was *registered* with the
// connection — this one — and never on the adaptor, whose own context
// pointer stays null. Calling setDelayedReply() from an adaptor slot
// therefore does not fail, it dereferences null: the first SaveFile over
// the bus segfaulted inside QDBusContext::message(), two frames under the
// slot. So the adaptor hands the call here and this class, which has the
// context, holds the reply open.
class FileChooserPortal : public QObject, protected QDBusContext {
    Q_OBJECT

public:
    explicit FileChooserPortal(QObject *parent = nullptr);

    bool attach();
    bool attached() const { return m_attached; }

    // Whether any caller is still waiting on a dialog.
    bool busy() const { return !m_pending.isEmpty(); }

signals:
    // Asks the QML for a dialog. `token` identifies which request this is,
    // so several at once cannot be confused for each other — a browser
    // downloading two things does exactly that.
    void dialogRequested(const QString &token, const QString &mode,
                         const QString &title, const QString &appId,
                         const QString &startFolder, const QString &suggestedName,
                         bool multiple, bool directory,
                         const QVariantList &filters);

    // Every dialog answered. Started for a single "Save as…", that is the
    // cue to go — see main().
    void idle();

public slots:
    // Called back from QML when the dialog closes. An empty list is a
    // cancellation.
    void finish(const QString &token, const QStringList &paths);

public:
    // Called by the adaptor from inside a slot invocation. Reads the call
    // out of the D-Bus context, marks the reply delayed, and asks for a
    // dialog; the reply goes out from finish().
    void begin(const QString &mode, const QString &appId,
               const QString &title, const QVariantMap &options);

private:
    // Checks, once the bus can answer, that the three methods a
    // FileChooser backend must have really made it onto it. See attach().
    void verifyExport();

    static QVariantList parseFilters(const QVariantMap &options);

    struct Pending {
        QDBusMessage reply;      // the call, held open until the dialog closes
        QString mode;
    };
    QHash<QString, Pending> m_pending;
    quint64 m_next = 0;
    bool m_attached = false;
};

// The D-Bus face of it.
//
// An adaptor rather than exporting the object's own slots: Qt's
// ExportScriptableSlots skips any method with output parameters, and every
// method here has two of them. The object registered, the name appeared on
// the bus, and introspection showed Properties, Introspectable and Peer and
// nothing else — which looks like success from every angle except the one
// that matters. An adaptor is the documented way to export a named
// interface and it does not have that hole.
class FileChooserAdaptor : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.FileChooser")
    Q_PROPERTY(uint version READ version CONSTANT)

public:
    explicit FileChooserAdaptor(FileChooserPortal *portal);

    uint version() const { return 3; }

public slots:
    // Every one of these must really reach the bus. Qt drops methods from
    // an adaptor without saying so on the bus — the object registers, the
    // interface is simply thinner than it was written, and the symptom is
    // every file dialog on the desktop opening nothing. attach()
    // introspects its own object afterwards for exactly that reason and
    // gives the bus name back rather than answering dialogs it cannot
    // show.
    uint OpenFile(const QDBusObjectPath &handle, const QString &appId,
                  const QString &parentWindow, const QString &title,
                  const QVariantMap &options, QVariantMap &results);
    uint SaveFile(const QDBusObjectPath &handle, const QString &appId,
                  const QString &parentWindow, const QString &title,
                  const QVariantMap &options, QVariantMap &results);
    uint SaveFiles(const QDBusObjectPath &handle, const QString &appId,
                   const QString &parentWindow, const QString &title,
                   const QVariantMap &options, QVariantMap &results);

private:
    FileChooserPortal *m_portal;
};
