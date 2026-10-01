#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include "bench.h"
#include "recorder.h"

#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

// Hyprshell Tasks: the task manager, as its own application — an ordinary
// window the compositor tiles and focuses like any other, so Ctrl+Shift+Esc
// brings up something that can be moved, resized and closed.
//
//   hyprshell-tasks                 the window
//   hyprshell-tasks --view NAME     open on a view (processes, performance…)
//   hyprshell-tasks --record        the flight recorder, as its service runs it
//   hyprshell-tasks --bench cpu|memory|disk [folder]   a benchmark, as JSON
int main(int argc, char *argv[]) {
    // The flight recorder: no window, no GUI, a sample every few seconds.
    for (int i = 1; i < argc; ++i)
        if (qstrcmp(argv[i], "--record") == 0) return Recorder::run(argc, argv);

    // A benchmark from the command line, its result printed as JSON.
    for (int i = 1; i + 1 < argc; ++i) {
        if (qstrcmp(argv[i], "--bench") != 0) continue;
        QCoreApplication app(argc, argv);
        Bench bench;
        int rc = 0;
        QObject::connect(&bench, &Bench::finished, &app, [&](const QVariantMap &r) {
            std::printf("%s\n", QJsonDocument(QJsonObject::fromVariantMap(r)).toJson(QJsonDocument::Compact).constData());
            app.quit();
        });
        QObject::connect(&bench, &Bench::failed, &app, [&](const QString &msg) {
            std::fprintf(stderr, "%s\n", qUtf8Printable(msg));
            rc = 1;
            app.quit();
        });
        bench.run(QString::fromLocal8Bit(argv[i + 1]), i + 2 < argc ? QString::fromLocal8Bit(argv[i + 2]) : QString());
        app.exec();
        return rc;
    }

    QGuiApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("hyprshell"));
    app.setApplicationName(QStringLiteral("hyprshell-tasks"));
    app.setDesktopFileName(QStringLiteral("hyprshell-tasks"));

    QString view;
    const QStringList args = app.arguments();
    const int v = args.indexOf(QStringLiteral("--view"));
    if (v >= 0 && v + 1 < args.size()) view = args.at(v + 1);

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.rootContext()->setContextProperty(QStringLiteral("startView"), view);
    engine.load(QUrl(QStringLiteral("qrc:/Hyprshell/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) return 1;

    // HYPRSHELL_TASKS_SHOT=/tmp/x.png grabs the window once it has settled
    // and exits: for checking a change without a display.
    const QString shot = qEnvironmentVariable("HYPRSHELL_TASKS_SHOT");
    if (!shot.isEmpty()) {
        auto *w = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        bool ok = false;
        const int delay = qEnvironmentVariableIntValue("HYPRSHELL_TASKS_SHOT_DELAY", &ok);
        QTimer::singleShot(ok && delay > 0 ? delay : 3500, &app, [w, shot] {
            if (w) w->grabWindow().save(shot);
            QGuiApplication::quit();
        });
    }
    return app.exec();
}
