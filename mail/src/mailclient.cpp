#include "mailclient.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFileInfo>
#include <QJSEngine>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>
#include <QtQml/qqmlengine.h>

MailClient::MailClient(QObject *parent) : QObject(parent) {
    connect(&m_sock, &QLocalSocket::connected, this, [this] {
        emit connectedChanged();
        flushQueue();
    });
    connect(&m_sock, &QLocalSocket::disconnected, this, [this] {
        emit connectedChanged();
        // Whatever was waiting will not be answered by this connection.
        const auto pending = m_pending;
        m_pending.clear();
        for (auto cb : pending)
            if (cb.isCallable())
                cb.call({QJSValue(false), QJSValue(QStringLiteral("Lost the connection to the mail service"))});
        m_retry.start(500);
    });
    connect(&m_sock, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        if (m_sock.state() != QLocalSocket::ConnectedState) {
            startDaemon();
            m_retry.start(400);
        }
    });
    connect(&m_sock, &QLocalSocket::readyRead, this, &MailClient::readLines);
    // Callbacks are the QML engine's values: let them go while it still
    // exists, not in its teardown, where releasing them corrupts the heap.
    connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, this, [this] {
        m_pending.clear();
        m_sock.disconnect(this);
        m_sock.abort();
    });
    m_retry.setSingleShot(true);
    connect(&m_retry, &QTimer::timeout, this, &MailClient::connectNow);
    connectNow();
}

QString MailClient::socketPath() const {
    const QString over = qEnvironmentVariable("HYPRSHELL_MAIL_SOCKET");
    if (!over.isEmpty()) return over;
    QString run = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (run.isEmpty()) run = QStringLiteral("/tmp");
    return run + QStringLiteral("/hyprshell-mail.sock");
}

void MailClient::connectNow() {
    if (m_sock.state() != QLocalSocket::UnconnectedState) return;
    m_sock.connectToServer(socketPath());
}

// The daemon beside this program if it is there (an install puts both in
// the same bin directory), else whichever is on PATH. Not more than once in
// ten seconds: one that will not start should not be started forever.
void MailClient::startDaemon() {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_startedAt < 10000) return;
    m_startedAt = now;
    QString exe = QCoreApplication::applicationDirPath() + QStringLiteral("/hyprshell-maild");
    if (!QFileInfo(exe).isExecutable()) exe = QStandardPaths::findExecutable(QStringLiteral("hyprshell-maild"));
    if (exe.isEmpty()) return;
    QStringList args;
    const QString over = qEnvironmentVariable("HYPRSHELL_MAIL_SOCKET");
    if (!over.isEmpty()) args << QStringLiteral("--socket") << over;
    QProcess::startDetached(exe, args);
}

void MailClient::call(const QString &cmd, const QVariantMap &args, const QJSValue &callback) {
    QJsonObject o = QJsonObject::fromVariantMap(args);
    const int rid = m_next++;
    o.insert(QStringLiteral("cmd"), cmd);
    o.insert(QStringLiteral("rid"), rid);
    if (callback.isCallable()) m_pending.insert(rid, callback);
    QByteArray line = QJsonDocument(o).toJson(QJsonDocument::Compact);
    line.append('\n');
    if (connected()) m_sock.write(line);
    else {
        m_queue.append(line);
        connectNow();
    }
}

void MailClient::flushQueue() {
    for (const auto &l : m_queue) m_sock.write(l);
    m_queue.clear();
}

void MailClient::readLines() {
    m_buf.append(m_sock.readAll());
    int nl;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        const QByteArray line = m_buf.left(nl);
        m_buf.remove(0, nl + 1);
        if (line.trimmed().isEmpty()) continue;
        const QJsonObject o = QJsonDocument::fromJson(line).object();
        if (o.contains(QStringLiteral("event"))) {
            emit event(o.value(QStringLiteral("event")).toString(), o.toVariantMap());
            continue;
        }
        const int rid = o.value(QStringLiteral("rid")).toInt();
        QJSValue cb = m_pending.take(rid);
        if (!cb.isCallable()) continue;
        QJSEngine *engine = qjsEngine(this);
        if (!engine) continue;
        const bool ok = o.value(QStringLiteral("ok")).toBool();
        const QJSValue payload = ok ? engine->toScriptValue(o.value(QStringLiteral("result")).toVariant())
                                    : QJSValue(o.value(QStringLiteral("error")).toString());
        cb.call({QJSValue(ok), payload});
    }
}
