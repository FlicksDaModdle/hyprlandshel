#include "gallery.h"

#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QMimeData>
#include <QStandardPaths>
#include <QUrl>

#include <algorithm>

QStringList Gallery::s_start;

Gallery::Gallery(QObject *parent) : QObject(parent), m_start(s_start) {}

void Gallery::setStartFiles(const QStringList &files) { s_start = files; }

static QStringList readableSuffixes() {
    static QStringList list;
    if (list.isEmpty()) {
        for (const QByteArray &f : QImageReader::supportedImageFormats())
            list << QString::fromLatin1(f).toLower();
        // Formats Qt reads under one name and files carry under another.
        for (const char *extra : {"jpg", "jpeg", "jfif", "tif", "tiff", "svgz"})
            if (!list.contains(QLatin1String(extra))) list << QString::fromLatin1(extra);
    }
    return list;
}

bool Gallery::isImage(const QString &path) const {
    const QFileInfo fi(path);
    return fi.isFile() && readableSuffixes().contains(fi.suffix().toLower());
}

QString Gallery::patterns() const {
    QStringList out;
    for (const QString &s : readableSuffixes()) out << QStringLiteral("*.") + s;
    return out.join(QLatin1Char(' '));
}

QString Gallery::fileUrl(const QString &path) const { return QUrl::fromLocalFile(path).toString(); }

// "photo 2" before "photo 10": runs of digits compare as numbers, the
// rest without regard to case. QCollator's numeric mode does this only
// where Qt was built with ICU, so it is done here.
static bool naturalLess(const QString &a, const QString &b) {
    int i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        if (a[i].isDigit() && b[j].isDigit()) {
            int si = i, sj = j;
            while (si < a.size() && a[si] == QLatin1Char('0')) ++si;
            while (sj < b.size() && b[sj] == QLatin1Char('0')) ++sj;
            int ei = si, ej = sj;
            while (ei < a.size() && a[ei].isDigit()) ++ei;
            while (ej < b.size() && b[ej].isDigit()) ++ej;
            if (ei - si != ej - sj) return ei - si < ej - sj;
            const int c = QStringView(a).mid(si, ei - si).compare(QStringView(b).mid(sj, ej - sj));
            if (c != 0) return c < 0;
            i = ei; j = ej;
            continue;
        }
        const QChar ca = a[i].toCaseFolded(), cb = b[j].toCaseFolded();
        if (ca != cb) return ca < cb;
        ++i; ++j;
    }
    if ((a.size() - i) != (b.size() - j)) return (a.size() - i) < (b.size() - j);
    return a < b;
}

QStringList Gallery::siblings(const QString &path) const {
    const QFileInfo fi(path);
    const QDir dir = fi.isDir() ? QDir(fi.absoluteFilePath()) : fi.absoluteDir();
    QStringList names;
    const QStringList all = dir.entryList(QDir::Files | QDir::Readable);
    const QStringList suffixes = readableSuffixes();
    for (const QString &n : all) {
        const int dot = n.lastIndexOf(QLatin1Char('.'));
        if (dot > 0 && suffixes.contains(n.mid(dot + 1).toLower())) names << n;
    }
    std::sort(names.begin(), names.end(), [](const QString &a, const QString &b) { return naturalLess(a, b); });
    QStringList out;
    out.reserve(names.size());
    for (const QString &n : names) out << dir.absoluteFilePath(n);
    return out;
}

QVariantMap Gallery::info(const QString &path) const {
    QVariantMap m;
    const QFileInfo fi(path);
    m[QStringLiteral("name")] = fi.fileName();
    m[QStringLiteral("folder")] = fi.absolutePath();
    m[QStringLiteral("bytes")] = fi.size();
    m[QStringLiteral("modified")] = fi.lastModified().toMSecsSinceEpoch();
    QImageReader r(path);
    r.setAutoTransform(true);
    QSize s = r.size();
    // Sideways photos: the size as they will be shown.
    if (r.transformation() & QImageIOHandler::TransformationRotate90) s.transpose();
    m[QStringLiteral("width")] = s.width();
    m[QStringLiteral("height")] = s.height();
    m[QStringLiteral("format")] = QString::fromLatin1(r.format()).toUpper();
    m[QStringLiteral("animated")] = r.supportsAnimation() && r.imageCount() > 1;
    return m;
}

bool Gallery::trash(const QString &path) { return QFile::moveToTrash(path); }

bool Gallery::copyImage(const QString &path) {
    QImageReader r(path);
    r.setAutoTransform(true);
    const QImage img = r.read();
    if (img.isNull()) return false;
    auto *mime = new QMimeData;
    mime->setImageData(img);
    // Pasted into a file manager it is the file; into anything else, the
    // picture.
    mime->setUrls({QUrl::fromLocalFile(path)});
    QGuiApplication::clipboard()->setMimeData(mime);
    return true;
}

void Gallery::copyText(const QString &text) { QGuiApplication::clipboard()->setText(text); }

static bool onPath(const QString &program) { return !QStandardPaths::findExecutable(program).isEmpty(); }

void Gallery::showInFolder(const QString &path) {
    // The shell's file manager, with the file selected, through the same
    // D-Bus call a browser's "Show in folder" makes; anything else that
    // answers it does too. Failing that, the folder.
    if (QProcess::startDetached(QStringLiteral("dbus-send"),
            {QStringLiteral("--session"), QStringLiteral("--dest=org.freedesktop.FileManager1"),
             QStringLiteral("--type=method_call"), QStringLiteral("/org/freedesktop/FileManager1"),
             QStringLiteral("org.freedesktop.FileManager1.ShowItems"),
             QStringLiteral("array:string:") + QUrl::fromLocalFile(path).toString(), QStringLiteral("string:")}))
        return;
    QProcess::startDetached(QStringLiteral("xdg-open"), {QFileInfo(path).absolutePath()});
}

bool Gallery::setWallpaper(const QString &path) {
    if (onPath(QStringLiteral("hyprshellctl")))
        return QProcess::startDetached(QStringLiteral("hyprshellctl"), {QStringLiteral("setWallpaper"), path});
    if (onPath(QStringLiteral("qs")))
        return QProcess::startDetached(QStringLiteral("qs"),
            {QStringLiteral("-c"), QStringLiteral("hyprshell"), QStringLiteral("ipc"), QStringLiteral("call"),
             QStringLiteral("shell"), QStringLiteral("setWallpaper"), path});
    return false;
}

void Gallery::openWith(const QString &path) {
    // The portal's chooser, where there is one; otherwise the folder.
    if (onPath(QStringLiteral("gio")))
        QProcess::startDetached(QStringLiteral("gio"), {QStringLiteral("open"), QFileInfo(path).absolutePath()});
    else
        QProcess::startDetached(QStringLiteral("xdg-open"), {QFileInfo(path).absolutePath()});
}

void Gallery::pick(const QString &startDir) {
    if (m_picker && m_picker->state() != QProcess::NotRunning) return;
    if (!onPath(QStringLiteral("hyprshell-files"))) { emit picked(QString()); return; }
    if (!m_picker) {
        m_picker = new QProcess(this);
        connect(m_picker, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
            const QString out = QString::fromUtf8(m_picker->readAllStandardOutput()).trimmed();
            emit picked(code == 0 ? out.section(QLatin1Char('\n'), 0, 0) : QString());
        });
    }
    QStringList args{QStringLiteral("--pick"), QStringLiteral("--filter"),
                     QStringLiteral("Pictures:") + patterns()};
    if (!startDir.isEmpty()) args << startDir;
    m_picker->start(QStringLiteral("hyprshell-files"), args);
}
