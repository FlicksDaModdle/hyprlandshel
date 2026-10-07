#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QJSEngine>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;

// What the QML needs from the machine besides the daemon: whether HTML can
// be shown in full (Qt WebEngine was there at build time), the sandbox for
// it, a reduced rendering for when it is not, and a few paths and file
// facts for attachments.
class MailApp : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool hasWebEngine READ hasWebEngine CONSTANT)
    Q_PROPERTY(QString startMessage READ startMessage NOTIFY startChanged)
    Q_PROPERTY(QString startCompose READ startCompose NOTIFY startChanged)

public:
    explicit MailApp(QObject *parent = nullptr);

    static MailApp *instance();
    // The one instance main() made and filled in, rather than a fresh one.
    static MailApp *create(QQmlEngine *, QJSEngine *) {
        MailApp *a = instance();
        QJSEngine::setObjectOwnership(a, QJSEngine::CppOwnership);
        return a;
    }
    bool hasWebEngine() const;
    QString startMessage() const { return m_message; }
    QString startCompose() const { return m_compose; }
    // Arguments from the command line, or from a second launch.
    void takeArguments(const QStringList &args);

    // The reader's web profile: every request it makes passes through a
    // filter that refuses anything remote unless `allowRemote` is set for
    // the message showing. Called once by the reader with its profile.
    Q_INVOKABLE void secure(QObject *profile);
    Q_INVOKABLE void setAllowRemote(QObject *profile, bool on);

    // HTML reduced to what Qt's rich text shows, for builds without
    // WebEngine: no scripts, no styles, no remote images (unless allowed).
    Q_INVOKABLE QString richText(const QString &html, bool allowRemote) const;
    // Whether the HTML refers to anything remote — the "images are hidden"
    // bar only shows when there is something to show.
    Q_INVOKABLE bool hasRemote(const QString &html) const;

    Q_INVOKABLE QString downloadsDir() const;
    Q_INVOKABLE QVariantMap fileInfo(const QString &path) const;
    Q_INVOKABLE QString urlToPath(const QString &url) const;
    Q_INVOKABLE void openFile(const QString &path) const;
    Q_INVOKABLE void showInFolder(const QString &path) const;

signals:
    void startChanged();
    // A second launch asked to show something.
    void raiseRequested();

private:
    QString m_message;
    QString m_compose;
};
