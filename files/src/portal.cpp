#include "portal.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusServiceWatcher>
#include <QDBusReply>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusSignature>
#include <QDBusVariant>
#include <QDBusArgument>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QFileInfo>
#include <QUrl>
#include <QDebug>

FileChooserPortal::FileChooserPortal(QObject *parent) : QObject(parent) {}

FileChooserAdaptor::FileChooserAdaptor(FileChooserPortal *portal)
    : QDBusAbstractAdaptor(portal), m_portal(portal) {
    setAutoRelaySignals(false);
}

bool FileChooserPortal::attach() {
    // QtDBus registers even its own built-in types lazily, and exporting an
    // object is one of the things that happens before that lazy moment
    // arrives. A method whose parameter type is not registered *yet* is
    // skipped — silently on the bus, though QtDBus does say so on stderr:
    //
    //   Skipped method "OpenFile" : Unregistered input type in parameter
    //   list: QDBusObjectPath
    //
    // Every method of this interface takes an object path, so all three
    // went. Asking for their signatures first forces the registration; the
    // answers are thrown away.
    (void) QDBusMetaType::typeToSignature(QMetaType::fromType<QDBusObjectPath>());
    (void) QDBusMetaType::typeToSignature(QMetaType::fromType<QDBusVariant>());
    (void) QDBusMetaType::typeToSignature(QMetaType::fromType<QDBusSignature>());

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) return false;
    // Owned by this object, and found through it by ExportAdaptors.
    new FileChooserAdaptor(this);
    if (!bus.registerObject(QStringLiteral("/org/freedesktop/portal/desktop"),
                            this, QDBusConnection::ExportAdaptors))
        return false;
    // Taken with replacement both ways round.
    //
    // A backend left over from a previous install holds this name until
    // it exits, and the one the bus has just started then cannot have
    // it — so it gives up, systemd counts a failure, and after a few of
    // those the unit is refused altogether and every file dialog on the
    // desktop stops working until someone clears it by hand. Allowing
    // replacement means a new backend takes over from an old one
    // instead; asking to replace means it does so without waiting for
    // the old one to notice.
    QDBusConnectionInterface *iface = bus.interface();
    const QString name =
        QStringLiteral("org.freedesktop.impl.portal.desktop.hyprshell");
    if (iface) {
        const QDBusReply<QDBusConnectionInterface::RegisterServiceReply> reply =
            iface->registerService(name,
                                   QDBusConnectionInterface::ReplaceExistingService,
                                   QDBusConnectionInterface::AllowReplacement);
        m_attached = reply.isValid()
                     && reply.value() == QDBusConnectionInterface::ServiceRegistered;
    } else {
        m_attached = bus.registerService(name);
    }
    if (m_attached) { verifyExport(); watchForReplacement(); }
    return m_attached;
}

// Asks the bus what this object actually exports, and complains if the
// three a FileChooser backend must have are not among them.
//
// Qt drops methods from an adaptor silently — no warning, no error, the
// object registers and the interface is simply thinner than it was
// written. The symptom is every file dialog on the desktop opening
// nothing, which is a bad way to find out. So this asks.
//
// Asynchronously, and that is not a style preference: a blocking call to
// our own connection cannot be answered, because the thread that would
// answer it is the one waiting. The first version of this check did
// exactly that and reported the methods missing when they were there —
// the check failing, not the export.
void FileChooserPortal::verifyExport() {
    QDBusConnection bus = QDBusConnection::sessionBus();
    QDBusMessage probe = QDBusMessage::createMethodCall(
        bus.baseService(),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.DBus.Introspectable"),
        QStringLiteral("Introspect"));

    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(probe), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QString> reply = *w;
        if (reply.isError()) {
            qWarning("could not introspect our own portal object: %s",
                     qUtf8Printable(reply.error().message()));
            return;
        }
        const QString xml = reply.value();
        QStringList missing;
        for (const QString &name : { QStringLiteral("OpenFile"),
                                     QStringLiteral("SaveFile"),
                                     QStringLiteral("SaveFiles") }) {
            if (!xml.contains(QStringLiteral("name=\"%1\"").arg(name)))
                missing.append(name);
        }
        if (missing.isEmpty()) return;

        qWarning("org.freedesktop.impl.portal.FileChooser exported without %s. "
                 "Giving the name back rather than answering the desktop's file "
                 "dialogs with a dialog that cannot open.",
                 qUtf8Printable(missing.join(QStringLiteral(", "))));
        QDBusConnection::sessionBus().unregisterService(
            QStringLiteral("org.freedesktop.impl.portal.desktop.hyprshell"));
        m_attached = false;
    });
}

// The name was taken with AllowReplacement, so it can be taken back —
// by the next backend an upgrade installs. Once it has been, nothing
// will ever call this process again, and a portal backend sitting in
// memory answering nothing is just a process to wonder about later.
void FileChooserPortal::watchForReplacement() {
    const QString name =
        QStringLiteral("org.freedesktop.impl.portal.desktop.hyprshell");
    // Owner change, not unregistration: a handover never leaves the name
    // unowned, so serviceUnregistered — which fires only when the new
    // owner is nobody — never came, and the displaced backend stayed up
    // answering nothing. The owner is compared against this connection
    // because taking the name in the first place is an owner change too.
    auto *watcher = new QDBusServiceWatcher(
        name, QDBusConnection::sessionBus(),
        QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &newOwner) {
        if (newOwner == QDBusConnection::sessionBus().baseService()) return;
        m_attached = false;
        emit displaced();
    });
}

// Filters come over as a(sa(us)): a name, then pairs of (type, pattern)
// where type 0 is a glob and type 1 a MIME type. Flattened to
// { name, patterns: [...] } because that is all a dialog can show.
QVariantList FileChooserPortal::parseFilters(const QVariantMap &options) {
    QVariantList out;
    const QVariant raw = options.value(QStringLiteral("filters"));
    if (!raw.canConvert<QDBusArgument>()) return out;
    // const on purpose. QDBusArgument's reading and writing halves are
    // distinguished by constness alone — beginArray() on a non-const one
    // starts *marshalling*, so a filter list read through a mutable copy
    // printed "QDBusArgument: write from a read-only object" four times
    // and then aborted the process inside libdbus. Firefox sends filters
    // on every upload, so that was every Open dialog.
    const QDBusArgument arg = raw.value<QDBusArgument>();

    arg.beginArray();
    while (!arg.atEnd()) {
        arg.beginStructure();
        QString name;
        arg >> name;
        QStringList patterns;
        arg.beginArray();
        while (!arg.atEnd()) {
            arg.beginStructure();
            uint kind = 0;
            QString value;
            arg >> kind >> value;
            arg.endStructure();
            if (!value.isEmpty()) patterns.append(value);
        }
        arg.endArray();
        arg.endStructure();
        QVariantMap f;
        f.insert(QStringLiteral("name"), name);
        f.insert(QStringLiteral("patterns"), patterns);
        out.append(f);
    }
    arg.endArray();
    return out;
}

void FileChooserPortal::begin(const QString &mode, const QString &appId,
                              const QString &title, const QVariantMap &options) {
    // The reply goes out when the dialog closes, not when this returns.
    // Both halves of that have to happen here rather than in the adaptor:
    // the context Qt set for this call is on this object.
    if (!calledFromDBus()) return;
    setDelayedReply(true);

    const QString token = QStringLiteral("r%1").arg(++m_next);
    Pending p;
    p.reply = message().createReply();
    p.mode = mode;
    m_pending.insert(token, p);

    // current_folder is a byte array with a trailing NUL, per the spec.
    QString startFolder;
    const QByteArray cf = options.value(QStringLiteral("current_folder")).toByteArray();
    if (!cf.isEmpty()) startFolder = QString::fromUtf8(cf).remove(QChar('\0'));
    if (startFolder.isEmpty()) {
        const QByteArray cu = options.value(QStringLiteral("current_file")).toByteArray();
        if (!cu.isEmpty())
            startFolder = QFileInfo(QString::fromUtf8(cu).remove(QChar('\0'))).absolutePath();
    }

    emit dialogRequested(token, mode, title, appId, startFolder,
                         options.value(QStringLiteral("current_name")).toString(),
                         options.value(QStringLiteral("multiple")).toBool(),
                         options.value(QStringLiteral("directory")).toBool(),
                         parseFilters(options));
}

void FileChooserPortal::finish(const QString &token, const QStringList &paths) {
    if (!m_pending.contains(token)) return;
    const Pending p = m_pending.take(token);

    QStringList uris;
    for (const QString &path : paths)
        uris.append(QUrl::fromLocalFile(path).toString());

    QVariantMap results;
    results.insert(QStringLiteral("uris"), uris);
    results.insert(QStringLiteral("writable"), true);

    QDBusMessage reply = p.reply;
    // 0 chose something, 1 cancelled. Never 2 from here: a dialog that was
    // shown and dismissed is a cancellation, not a failure.
    reply << QVariant::fromValue(uris.isEmpty() ? uint(1) : uint(0))
          << QVariant::fromValue(results);
    QDBusConnection::sessionBus().send(reply);

    if (m_pending.isEmpty()) emit idle();
}

// The three the interface is for. Each hands the call to the portal, which
// says "not yet" on its own behalf — see begin(). The return value and
// `results` here are consequently never the ones the caller sees.
uint FileChooserAdaptor::OpenFile(const QDBusObjectPath &, const QString &appId,
                                  const QString &, const QString &title,
                                  const QVariantMap &options, QVariantMap &) {
    m_portal->begin(QStringLiteral("open"), appId, title, options);
    return 0;
}

uint FileChooserAdaptor::SaveFile(const QDBusObjectPath &, const QString &appId,
                                  const QString &, const QString &title,
                                  const QVariantMap &options, QVariantMap &) {
    m_portal->begin(QStringLiteral("save"), appId, title, options);
    return 0;
}

uint FileChooserAdaptor::SaveFiles(const QDBusObjectPath &, const QString &appId,
                                   const QString &, const QString &title,
                                   const QVariantMap &options, QVariantMap &) {
    m_portal->begin(QStringLiteral("savefiles"), appId, title, options);
    return 0;
}
