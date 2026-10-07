#include "mailapp.h"

#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

#include <QBuffer>
#include <QHash>
#include <QUuid>

#ifdef HAVE_WEBENGINE
#include <QWebEngineUrlRequestInterceptor>
#include <QWebEngineUrlRequestJob>
#include <QWebEngineUrlSchemeHandler>
#include <QtWebEngineQuick/QQuickWebEngineProfile>

// The messages on screen, by key: hsmail:<key> is how the reader loads one.
// Not a data: URL — those stop at 2 MB, and a message with its pictures
// inside is often more.
static QHash<QString, QByteArray> s_pages;

class PageScheme : public QWebEngineUrlSchemeHandler {
public:
    void requestStarted(QWebEngineUrlRequestJob *job) override {
        const QString key = job->requestUrl().path();
        auto it = s_pages.constFind(key);
        if (it == s_pages.constEnd()) {
            job->fail(QWebEngineUrlRequestJob::UrlNotFound);
            return;
        }
        auto *buf = new QBuffer(job);
        buf->setData(*it);
        buf->open(QIODevice::ReadOnly);
        job->reply("text/html;charset=utf-8", buf);
    }
};
static PageScheme *pageScheme() {
    static PageScheme *h = new PageScheme;
    return h;
}

// The reader's gatekeeper. A message comes from hsmail:, and its own
// inline images are data: URLs (the daemon turns cid: references into
// them), so the message itself needs nothing from anywhere. Everything
// remote — tracking pixels, web fonts, stylesheets, images — is refused
// unless the person reading has said that sender may show images.
// Navigating away (a link) is the reader's own business: it opens links in
// the browser and never in the message pane.
class RemoteGate : public QWebEngineUrlRequestInterceptor {
public:
    bool allowRemote = false;
    void interceptRequest(QWebEngineUrlRequestInfo &info) override {
        const QString scheme = info.requestUrl().scheme();
        if (scheme == QLatin1String("data") || scheme == QLatin1String("about") || scheme == QLatin1String("blob")
            || scheme == QLatin1String("hsmail"))
            return;
        const auto type = info.resourceType();
        const bool remote = scheme == QLatin1String("http") || scheme == QLatin1String("https");
        if (remote && allowRemote
            && (type == QWebEngineUrlRequestInfo::ResourceTypeImage
                || type == QWebEngineUrlRequestInfo::ResourceTypeStylesheet
                || type == QWebEngineUrlRequestInfo::ResourceTypeFontResource
                || type == QWebEngineUrlRequestInfo::ResourceTypeMedia))
            return;
        // Nothing else: no frames, no scripts, no beacons, no files.
        info.block(true);
    }
};
#endif

static MailApp *s_instance = nullptr;

MailApp::MailApp(QObject *parent) : QObject(parent) {
    if (!s_instance) s_instance = this;
}

MailApp *MailApp::instance() {
    if (!s_instance) s_instance = new MailApp;
    return s_instance;
}

bool MailApp::hasWebEngine() const {
#ifdef HAVE_WEBENGINE
    return qEnvironmentVariable("HYPRSHELL_MAIL_NO_WEBENGINE").isEmpty();
#else
    return false;
#endif
}

// --message=ID opens a message; mailto:… (as given by a browser or by
// xdg-open) or --compose opens a new one.
void MailApp::takeArguments(const QStringList &args) {
    for (const QString &a : args.mid(1)) {
        if (a.startsWith(QLatin1String("--message="))) m_message = a.mid(10);
        else if (a.startsWith(QLatin1String("mailto:"))) m_compose = a;
        else if (a == QLatin1String("--compose")) m_compose = QStringLiteral("mailto:");
    }
    emit startChanged();
    emit raiseRequested();
}

// Each message's view has a profile of its own, and each profile a gate of
// its own, so allowing one sender's pictures never lets another's through.
// The gate lives as long as the profile.
void MailApp::secure(QObject *profile) {
#ifdef HAVE_WEBENGINE
    auto *p = qobject_cast<QQuickWebEngineProfile *>(profile);
    if (!p || p->property("hsGate").isValid()) return;
    auto *g = new RemoteGate;
    p->setUrlRequestInterceptor(g);
    p->installUrlSchemeHandler("hsmail", pageScheme());
    p->setProperty("hsGate", QVariant::fromValue(static_cast<void *>(g)));
    QObject::connect(p, &QObject::destroyed, p, [g] { delete g; });
#else
    Q_UNUSED(profile);
#endif
}

void MailApp::setAllowRemote(QObject *profile, bool on) {
#ifdef HAVE_WEBENGINE
    if (!profile) return;
    if (auto *g = static_cast<RemoteGate *>(profile->property("hsGate").value<void *>())) g->allowRemote = on;
#else
    Q_UNUSED(profile);
    Q_UNUSED(on);
#endif
}

QString MailApp::publish(const QString &html) {
#ifdef HAVE_WEBENGINE
    const QString key = QUuid::createUuid().toString(QUuid::WithoutBraces);
    s_pages.insert(key, html.toUtf8());
    return QStringLiteral("hsmail:") + key;
#else
    Q_UNUSED(html);
    return QString();
#endif
}

void MailApp::release(const QString &url) {
#ifdef HAVE_WEBENGINE
    if (url.startsWith(QLatin1String("hsmail:"))) s_pages.remove(url.mid(7));
#else
    Q_UNUSED(url);
#endif
}

bool MailApp::hasRemote(const QString &html) const {
    static const QRegularExpression re(QStringLiteral(R"((src|srcset|background)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//)"),
                                       QRegularExpression::CaseInsensitiveOption);
    return re.match(html).hasMatch();
}

QString MailApp::richText(const QString &html, bool allowRemote) const {
    QString s = html;
    static const QRegularExpression drop(QStringLiteral(R"(<(script|style|head|title|iframe|object|embed)\b[^>]*>.*?</\1\s*>)"),
                                         QRegularExpression::CaseInsensitiveOption | QRegularExpression::DotMatchesEverythingOption);
    s.remove(drop);
    static const QRegularExpression handlers(QStringLiteral(R"(\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))"),
                                             QRegularExpression::CaseInsensitiveOption);
    s.remove(handlers);
    if (!allowRemote) {
        static const QRegularExpression remoteImg(QStringLiteral(R"(<img\b[^>]*\bsrc\s*=\s*["']?\s*https?:[^>]*>)"),
                                                  QRegularExpression::CaseInsensitiveOption);
        s.remove(remoteImg);
    }
    return s;
}

QString MailApp::downloadsDir() const {
    const QString d = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    return d.isEmpty() ? QDir::homePath() : d;
}

QVariantMap MailApp::fileInfo(const QString &path) const {
    const QFileInfo fi(urlToPath(path));
    return {{QStringLiteral("exists"), fi.exists()},
            {QStringLiteral("name"), fi.fileName()},
            {QStringLiteral("size"), fi.size()},
            {QStringLiteral("dir"), fi.isDir()},
            {QStringLiteral("path"), fi.absoluteFilePath()}};
}

QString MailApp::urlToPath(const QString &url) const {
    const QUrl u(url);
    return u.isLocalFile() ? u.toLocalFile() : url;
}

void MailApp::openFile(const QString &path) const {
    QDesktopServices::openUrl(QUrl::fromLocalFile(urlToPath(path)));
}

// Files' own "show me where it is", when the file manager is installed.
void MailApp::showInFolder(const QString &path) const {
    const QFileInfo fi(urlToPath(path));
    const QString files = QStandardPaths::findExecutable(QStringLiteral("hyprshell-files"));
    if (!files.isEmpty()) QProcess::startDetached(files, {fi.absolutePath()});
    else QDesktopServices::openUrl(QUrl::fromLocalFile(fi.absolutePath()));
}
