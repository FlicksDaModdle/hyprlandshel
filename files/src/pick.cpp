#include "pick.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QTextStream>
#include <QUrl>

Picker::Picker(QObject *parent) : QObject(parent) {}

namespace {

// --filter "Images:*.png *.svg *.jpg"
//
// The name before the colon, space-separated globs after it, which is the
// shortest thing that still carries both halves of what the dialog's
// filter row shows. The portal's own form is a D-Bus structure and has no
// command-line spelling to borrow.
QVariantMap parseFilter(const QString &spec, QString *error) {
    const int colon = spec.indexOf(QLatin1Char(':'));
    if (colon <= 0 || colon == spec.size() - 1) {
        *error = QStringLiteral("--filter wants NAME:PATTERN [PATTERN...], got \"%1\"")
                     .arg(spec);
        return {};
    }

    QStringList patterns;
    const auto parts = spec.mid(colon + 1).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString &p : parts) patterns.append(p);
    if (patterns.isEmpty()) {
        *error = QStringLiteral("--filter \"%1\" names no patterns").arg(spec);
        return {};
    }

    QVariantMap f;
    f.insert(QStringLiteral("name"), spec.left(colon));
    f.insert(QStringLiteral("patterns"), patterns);
    return f;
}

} // namespace

bool Picker::parse(const QStringList &args) {
    if (!args.contains(QStringLiteral("--pick"))) return false;

    m_wanted = true;

    QString mode = QStringLiteral("open");
    QString startFolder;
    QString suggestedName;
    bool multiple = false;
    bool directory = false;
    QVariantList filters;

    for (int i = 1; i < args.size(); ++i) {
        const QString a = args.at(i);
        // Anything that needs a value and has not got one is a mistake
        // worth naming, not a flag to ignore: a script that meant
        // `--start "$dir"` with an empty $dir would otherwise silently
        // eat the flag after it.
        const auto value = [&](const char *flag) -> QString {
            if (i + 1 >= args.size()) {
                m_error = QStringLiteral("%1 wants a value").arg(QLatin1String(flag));
                return {};
            }
            return args.at(++i);
        };

        if (a == QLatin1String("--pick")) continue;
        if (a == QLatin1String("--save")) { mode = QStringLiteral("save"); continue; }
        if (a == QLatin1String("--directory")) { directory = true; continue; }
        if (a == QLatin1String("--multiple")) { multiple = true; continue; }
        if (a == QLatin1String("--start")) {
            const QString v = value("--start");
            if (!m_error.isEmpty()) return false;
            // A file is as good as a folder to start from: the dialog
            // opens where it lives, which is what someone passing the
            // currently-chosen file means.
            QString p = v;
            if (p.startsWith(QLatin1String("file://"))) p = QUrl(p).toLocalFile();
            const QFileInfo info(p);
            if (info.isDir()) startFolder = info.absoluteFilePath();
            else if (info.exists()) startFolder = info.absolutePath();
            continue;
        }
        if (a == QLatin1String("--name")) {
            suggestedName = value("--name");
            if (!m_error.isEmpty()) return false;
            continue;
        }
        if (a == QLatin1String("--filter")) {
            const QString v = value("--filter");
            if (!m_error.isEmpty()) return false;
            QString err;
            const QVariantMap f = parseFilter(v, &err);
            if (!err.isEmpty()) { m_error = err; return false; }
            filters.append(f);
            continue;
        }
        if (a.startsWith(QLatin1Char('-'))) {
            m_error = QStringLiteral("unknown option \"%1\"").arg(a);
            return false;
        }
    }

    // Saving into a folder you have to choose is what the portal calls
    // SaveFiles; asking for both here is a contradiction rather than a
    // third mode.
    if (mode == QLatin1String("save") && directory) {
        m_error = QStringLiteral("--save and --directory cannot both be given");
        return false;
    }

    m_request.insert(QStringLiteral("mode"), mode);
    m_request.insert(QStringLiteral("startFolder"), startFolder);
    m_request.insert(QStringLiteral("suggestedName"), suggestedName);
    m_request.insert(QStringLiteral("multiple"), multiple);
    m_request.insert(QStringLiteral("directory"), directory);
    m_request.insert(QStringLiteral("filters"), filters);
    return true;
}

void Picker::finish(const QStringList &paths) {
    QTextStream out(stdout);
    for (const QString &p : paths) out << p << Qt::endl;
    out.flush();
    // Cancelled is not a failure of the program, but it has to be
    // distinguishable from "chose nothing", which cannot happen — the
    // dialog will not accept an empty selection. So: 1 for cancelled,
    // and a caller can simply test the exit status.
    QCoreApplication::exit(paths.isEmpty() ? 1 : 0);
}
