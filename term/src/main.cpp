#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QRegularExpression>
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

    // The command line every other program expects a terminal to have.
    //
    // This is not a matter of taste now that it is the desktop's default
    // terminal: a file manager opening a shell in a folder, a .desktop
    // entry with Terminal=true, `xdg-terminal-exec`, a script — each has
    // its own idea of how to say "run this" and "start here", and a
    // terminal that only knows one of them is a terminal that silently
    // opens in the wrong place or ignores what it was asked to run.
    //
    //   -e ARGV...   |  -x ARGV...  |  -- ARGV...     what to run
    //   --working-directory=DIR  |  -w DIR  |  --cd DIR   where to start
    QStringList command;
    QString workdir;
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        const QString a = args.at(i);

        static const QString wdEq = QStringLiteral("--working-directory=");
        if (a.startsWith(wdEq)) { workdir = a.mid(wdEq.size()); continue; }
        if ((a == QStringLiteral("--working-directory") || a == QStringLiteral("-w")
             || a == QStringLiteral("--cd"))
            && i + 1 < args.size()) {
            workdir = args.at(++i);
            continue;
        }

        // Everything after this is the command, including anything that
        // looks like one of the flags above — those belong to it now.
        if (a == QStringLiteral("-e") || a == QStringLiteral("-x")
            || a == QStringLiteral("--")) {
            command = args.mid(i + 1);
            break;
        }
    }

    // `-e "ls -l"`: one argument with a space in it is a shell command,
    // not a program whose name contains a space. Callers are split on
    // which they mean — xterm takes it literally, gnome-terminal splits
    // it — and the ones that pass a whole line are far more common.
    //
    // Guarded on the file not existing, so the rare caller that really
    // does have a program with a space in its path still gets it: there
    // is no guessing left in that case, only a fact on disk.
    if (command.size() == 1) {
        static const QRegularExpression space(QStringLiteral("\\s"));
        const QString only = command.first();
        if (only.contains(space) && !QFileInfo(only).isExecutable()) {
            const QByteArray shell = qgetenv("SHELL");
            command = QStringList {
                shell.isEmpty() ? QStringLiteral("/bin/sh")
                                : QString::fromLocal8Bit(shell),
                QStringLiteral("-c"), only
            };
        }
    }

    // The shell is forked from this process, so its working directory is
    // this one's. A directory that is not there is ignored rather than
    // fatal: a stale bookmark in someone's file manager should open a
    // terminal at home, not fail to open one.
    if (!workdir.isEmpty()) {
        const QFileInfo info(workdir);
        if (info.isDir()) QDir::setCurrent(info.absoluteFilePath());
        else qWarning("no such directory: %s", qUtf8Printable(workdir));
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
