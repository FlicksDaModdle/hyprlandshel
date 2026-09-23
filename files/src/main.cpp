#include <QGuiApplication>
#include <QQuickWindow>
#include <QTimer>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDir>
#include <QFileInfo>
#include <QUrl>
#include <QImage>

// Hyprshell Files: the shell's file manager, as its own application.
//
// The window is an ordinary Qt toplevel, which is the whole point of it
// being separate: the compositor tiles it, focuses it and applies window
// rules the same as anything else, and dragging files out to other
// applications goes through the normal Wayland data-device rather than a
// layer-shell surface that is not a drag source.
int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);

    app.setApplicationName(QStringLiteral("hyprshell-files"));
    app.setOrganizationName(QStringLiteral("hyprshell"));
    // Wayland takes the app id from here, which is what a Hyprland window
    // rule matches on.
    app.setDesktopFileName(QStringLiteral("hyprshell-files"));

    // An argument is a directory to open, so `hyprshell-files ~/Downloads`
    // and the desktop entry's inode/directory handler both work.
    QString startPath;
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        QString a = args.at(i);
        if (a.startsWith(QStringLiteral("-"))) continue;
        if (a.startsWith(QStringLiteral("file://"))) a = QUrl(a).toLocalFile();
        const QFileInfo info(a);
        if (info.isDir()) { startPath = info.absoluteFilePath(); break; }
        if (info.exists()) { startPath = info.absolutePath(); break; }
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("startPath"), startPath);
    // The URL form rather than loadFromModule(), which arrived in 6.5: this
    // builds against 6.2, and the resource path is what that call resolves
    // to anyway.
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.load(QUrl(QStringLiteral("qrc:/Hyprshell/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) return 1;

    // A way to see what the window looks like without a display, for
    // debugging a rendering problem and for checking a change from a
    // terminal:  HYPRSHELL_FILES_SHOT=/tmp/x.png QT_QPA_PLATFORM=offscreen
    //            QT_QUICK_BACKEND=software hyprshell-files
    // It grabs once the first frame has settled and exits.
    const QString shot = qEnvironmentVariable("HYPRSHELL_FILES_SHOT");
    if (!shot.isEmpty()) {
        auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        if (w) {
            QTimer::singleShot(1500, &app, [w, shot] {
                const QImage img = w->grabWindow();
                if (img.save(shot)) qWarning("wrote %s", qUtf8Printable(shot));
                else qWarning("could not write %s", qUtf8Printable(shot));
                QGuiApplication::quit();
            });
        }
    }

    return app.exec();
}
