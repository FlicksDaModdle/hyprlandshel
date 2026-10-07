#pragma once

#include <QHash>
#include <QJSValue>
#include <QLocalSocket>
#include <QObject>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// The app's line to hyprshell-maild: JSON a line at a time over its Unix
// socket. `call(cmd, args, callback)` sends a command and calls back with
// (ok, resultOrError); everything the daemon announces on its own arrives
// as `event(name, data)`.
//
// If the daemon is not running the app starts it — it carries on after the
// window closes, which is what keeps mail arriving, snoozes ending and
// scheduled mail going out.
class MailClient : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)

public:
    explicit MailClient(QObject *parent = nullptr);

    bool connected() const { return m_sock.state() == QLocalSocket::ConnectedState; }

    Q_INVOKABLE void call(const QString &cmd, const QVariantMap &args = {}, const QJSValue &callback = QJSValue());
    Q_INVOKABLE QString socketPath() const;

signals:
    void connectedChanged();
    void event(const QString &name, const QVariantMap &data);

private:
    void connectNow();
    void startDaemon();
    void readLines();
    void flushQueue();

    QLocalSocket m_sock;
    QByteArray m_buf;
    QHash<int, QJSValue> m_pending;
    QList<QByteArray> m_queue;
    int m_next = 1;
    QTimer m_retry;
    qint64 m_startedAt = 0;
};
