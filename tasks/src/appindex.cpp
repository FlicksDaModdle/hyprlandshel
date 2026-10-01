#include "appindex.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QSet>

#include <algorithm>

namespace {

// The program a desktop entry's Exec line runs: "env FOO=1 flatpak run
// org.x.Y %U" is org.x.Y; "/usr/bin/firefox --new-window %u" is firefox.
QString execProgram(const QString &exec) {
    QStringList words = exec.split(' ', Qt::SkipEmptyParts);
    while (!words.isEmpty() && (words.first() == "env" || words.first().contains('='))) words.removeFirst();
    if (words.size() >= 3 && QFileInfo(words.first()).fileName() == "flatpak" && words.at(1) == "run") {
        for (int i = 2; i < words.size(); ++i) if (!words.at(i).startsWith('-')) return words.at(i);
    }
    if (words.isEmpty()) return {};
    QString p = words.first();
    p.remove('"');
    return QFileInfo(p).fileName();
}

} // namespace

AppIndex::AppIndex(QObject *parent) : QObject(parent) { scan(); }

QStringList AppIndex::dirs() {
    QStringList out;
    QString home = qEnvironmentVariable("XDG_DATA_HOME");
    if (home.isEmpty()) home = QDir::homePath() + "/.local/share";
    out << home + "/applications" << home + "/flatpak/exports/share/applications";
    QString sys = qEnvironmentVariable("XDG_DATA_DIRS");
    if (sys.isEmpty()) sys = "/usr/local/share:/usr/share";
    for (const QString &d : sys.split(':', Qt::SkipEmptyParts)) out << d + "/applications";
    out << "/var/lib/flatpak/exports/share/applications";
    out.removeDuplicates();
    return out;
}

void AppIndex::scan() {
    m_byId.clear();
    m_byClass.clear();
    m_byExec.clear();
    m_stamps.clear();
    const QString lang = QLocale().name().section('_', 0, 0);
    // Earlier directories win: ~/.local overrides /usr.
    for (const QString &dir : dirs()) {
        const QFileInfo di(dir);
        m_stamps.insert(dir, di.exists() ? di.lastModified() : QDateTime());
        if (!di.isDir()) continue;
        QDir d(dir);
        for (const QFileInfo &fi : d.entryInfoList({"*.desktop"}, QDir::Files)) {
            const QString id = fi.completeBaseName();
            if (m_byId.contains(id.toLower())) continue;
            QFile f(fi.absoluteFilePath());
            if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) continue;
            QVariantMap e{{"id", id}, {"path", fi.absoluteFilePath()}};
            bool inMain = false, hidden = false, noDisplay = false;
            QString type;
            while (!f.atEnd()) {
                const QString line = QString::fromUtf8(f.readLine()).trimmed();
                if (line.startsWith('[')) { inMain = line == "[Desktop Entry]"; continue; }
                if (!inMain) continue;
                const int eq = line.indexOf('=');
                if (eq < 0) continue;
                const QString k = line.left(eq).trimmed(), v = line.mid(eq + 1).trimmed();
                if (k == "Name") e["name"] = v;
                else if (k == "Name[" + lang + "]") e["localName"] = v;
                else if (k == "Icon") e["icon"] = v;
                else if (k == "Exec") e["exec"] = v;
                else if (k == "Comment") e["comment"] = v;
                else if (k == "StartupWMClass") e["wmclass"] = v;
                else if (k == "Type") type = v;
                else if (k == "Hidden") hidden = v == "true";
                else if (k == "NoDisplay") noDisplay = v == "true";
            }
            if (type != "Application" || hidden) continue;
            if (e.contains("localName")) e["name"] = e.value("localName");
            e["visible"] = !noDisplay;
            m_byId.insert(id.toLower(), e);
            if (e.contains("wmclass")) m_byClass.insert(e.value("wmclass").toString().toLower(), e);
            const QString prog = execProgram(e.value("exec").toString()).toLower();
            if (!prog.isEmpty() && !m_byExec.contains(prog)) m_byExec.insert(prog, e);
        }
    }
}

void AppIndex::refreshIfChanged() {
    for (auto it = m_stamps.cbegin(); it != m_stamps.cend(); ++it) {
        const QFileInfo fi(it.key());
        if ((fi.exists() ? fi.lastModified() : QDateTime()) != it.value()) { scan(); return; }
    }
}

QVariantMap AppIndex::byId(const QString &id) const { return m_byId.value(id.toLower()); }

QVariantMap AppIndex::byClass(const QString &cls) const {
    const QString c = cls.toLower();
    if (c.isEmpty()) return {};
    if (m_byClass.contains(c)) return m_byClass.value(c);
    if (m_byId.contains(c)) return m_byId.value(c);
    // "org.mozilla.firefox" → "firefox", and the other way about.
    const QString tail = c.section('.', -1);
    for (auto it = m_byId.cbegin(); it != m_byId.cend(); ++it)
        if (it.key().section('.', -1) == tail) return it.value();
    if (m_byExec.contains(c)) return m_byExec.value(c);
    if (m_byExec.contains(tail)) return m_byExec.value(tail);
    return {};
}

QVariantMap AppIndex::byExec(const QString &program) const {
    const QString p = program.toLower();
    if (m_byExec.contains(p)) return m_byExec.value(p);
    if (m_byId.contains(p)) return m_byId.value(p);
    return {};
}

QVariantList AppIndex::all() const {
    QVariantList out;
    for (const QVariantMap &e : m_byId) if (e.value("visible").toBool()) out << e;
    std::sort(out.begin(), out.end(), [](const QVariant &a, const QVariant &b) {
        return QString::compare(a.toMap().value("name").toString(), b.toMap().value("name").toString(),
                                Qt::CaseInsensitive) < 0;
    });
    return out;
}
