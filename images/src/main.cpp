#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include "gallery.h"

// Hyprshell Images: the image viewer.
//
//   hyprshell-images [FILE…]    open these (or a folder: its first picture)
//
// An ordinary window the compositor tiles and focuses like any other. It
// follows the shell's theme.json, as Files and the task manager do.
int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("hyprshell"));
    app.setApplicationName(QStringLiteral("hyprshell-images"));
    app.setDesktopFileName(QStringLiteral("hyprshell-images"));

    QStringList files;
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        QString a = args.at(i);
        if (a.startsWith(QLatin1Char('-'))) continue;
        if (a.startsWith(QStringLiteral("file://"))) a = QUrl(a).toLocalFile();
        const QFileInfo fi(a);
        if (fi.exists()) files << fi.absoluteFilePath();
    }
    Gallery::setStartFiles(files);

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.load(QUrl(QStringLiteral("qrc:/Hyprshell/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) return 1;

    // HYPRSHELL_IMAGES_SHOT=/tmp/x.png grabs the window once it has
    // settled and exits: for checking a change without a display.
    const QString shot = qEnvironmentVariable("HYPRSHELL_IMAGES_SHOT");
    if (!shot.isEmpty()) {
        auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        bool ok = false;
        const int delay = qEnvironmentVariableIntValue("HYPRSHELL_IMAGES_SHOT_DELAY", &ok);
        QTimer::singleShot(ok && delay > 0 ? delay : 2500, &app, [w, shot] {
            if (w) w->grabWindow().save(shot);
            QGuiApplication::quit();
        });
    }
    return app.exec();
}
