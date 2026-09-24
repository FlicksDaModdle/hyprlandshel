#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>
#include <QImage>

// Hyprshell Terminal: the shell's terminal, as its own application.
//
// Same shape as the file manager next door — an ordinary Qt toplevel with
// the designed chrome drawn in QML rather than the compositor's, so the
// window matches the rest of the desktop rather than sitting inside
// someone else's idea of a title bar.
//
// What is underneath it is libvterm, which is the part nobody should
// write twice: it is the VT220/xterm state machine, and everything here
// is the pty in front of it and the grid behind it.
int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);

    app.setOrganizationName(QStringLiteral("hyprshell"));
    app.setApplicationName(QStringLiteral("hyprshell-term"));
    app.setDesktopFileName(QStringLiteral("hyprshell-term"));

    // `hyprshell-term -e some command` runs that instead of a shell, which
    // is what every launcher and file manager expects of a terminal.
    QStringList command;
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        if (args.at(i) == QStringLiteral("-e") || args.at(i) == QStringLiteral("--")) {
            command = args.mid(i + 1);
            break;
        }
    }

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.rootContext()->setContextProperty(QStringLiteral("startCommand"), command);
    engine.load(QUrl(QStringLiteral("qrc:/Hyprterm/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) return 1;

    // The same offscreen grab the file manager has, for checking a change
    // without a display. See files/src/main.cpp for why it exists.
    const QString shot = qEnvironmentVariable("HYPRSHELL_TERM_SHOT");
    if (!shot.isEmpty()) {
        if (auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst())) {
            bool ok = false;
            const int delay = qEnvironmentVariableIntValue("HYPRSHELL_TERM_SHOT_DELAY", &ok);
            QTimer::singleShot(ok && delay > 0 ? delay : 1500, &app, [w, shot] {
                const QImage img = w->grabWindow();
                if (img.save(shot)) qWarning("wrote %s", qUtf8Printable(shot));
                else qWarning("could not write %s", qUtf8Printable(shot));
                QGuiApplication::quit();
            });
        }
    }

    return app.exec();
}
