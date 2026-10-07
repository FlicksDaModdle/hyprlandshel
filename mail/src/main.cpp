#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#ifdef HAVE_WEBENGINE
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#endif

#include "mailapp.h"

// Hyprshell Mail.
//
//   hyprshell-mail                   the window
//   hyprshell-mail --message=ID      open on a message (from a notification)
//   hyprshell-mail mailto:…          write a new message (the mailto: handler)
//   hyprshell-mail --compose         write a new message
//
// One window: a second launch hands its arguments to the first and leaves.
static QString instanceName() {
    return QStringLiteral("hyprshell-mail-app-") + qEnvironmentVariable("USER", QStringLiteral("me"));
}

int main(int argc, char *argv[]) {
    // A second launch: pass the arguments on and go.
    {
        QCoreApplication probe(argc, argv);
        QLocalSocket s;
        s.connectToServer(instanceName());
        if (s.waitForConnected(300)) {
            s.write(QCoreApplication::arguments().join(QChar(0x1f)).toUtf8() + '\n');
            s.waitForBytesWritten(500);
            return 0;
        }
    }

#ifdef HAVE_WEBENGINE
    if (qEnvironmentVariable("HYPRSHELL_MAIL_NO_WEBENGINE").isEmpty()) QtWebEngineQuick::initialize();
#endif
    QGuiApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("hyprshell"));
    app.setApplicationName(QStringLiteral("hyprshell-mail"));
    app.setDesktopFileName(QStringLiteral("hyprshell-mail"));

    MailApp *mailApp = MailApp::instance();
    mailApp->takeArguments(app.arguments());

    QLocalServer server;
    QLocalServer::removeServer(instanceName());
    server.listen(instanceName());
    QObject::connect(&server, &QLocalServer::newConnection, &server, [&server, mailApp] {
        QLocalSocket *c = server.nextPendingConnection();
        QObject::connect(c, &QLocalSocket::readyRead, c, [c, mailApp] {
            if (!c->canReadLine()) return;
            const QStringList args = QString::fromUtf8(c->readLine()).trimmed().split(QChar(0x1f));
            mailApp->takeArguments(args);
            c->deleteLater();
        });
    });

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.load(QUrl(QStringLiteral("qrc:/Hyprshell/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) return 1;

    // HYPRSHELL_MAIL_SHOT=/path.png grabs the window once it has settled
    // and exits: for checking a change without a display.
    const QString shot = qEnvironmentVariable("HYPRSHELL_MAIL_SHOT");
    if (!shot.isEmpty()) {
        auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        bool ok = false;
        const int delay = qEnvironmentVariableIntValue("HYPRSHELL_MAIL_SHOT_DELAY", &ok);
        QTimer::singleShot(ok && delay > 0 ? delay : 4000, &app, [w, shot] {
            if (w) w->grabWindow().save(shot);
            QGuiApplication::quit();
        });
    }
    return app.exec();
}
