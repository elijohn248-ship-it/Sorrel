#include "Engine.h"
#include "Log.h"

#include <QApplication>
#include <QDir>
#include <QStandardPaths>
#include <QWebEngineCertificateError>
#include <QWebEngineDownloadRequest>
#include <QWebEngineNotification>
#include <QWebEngineProfile>
#include <QWebEngineProfileBuilder>
#include <QWebEngineSettings>
#include <QWebEngineUrlRequestInfo>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
#ifdef Q_OS_LINUX
#include <sys/xattr.h>
#endif

namespace Birch {

// Switches that turn the sandbox (or process isolation) off. Never allowed.
static const char *const kForbiddenSwitches[] = {
    "--no-sandbox", "--disable-seccomp-filter-sandbox", "--disable-namespace-sandbox",
    "--disable-setuid-sandbox", "--disable-gpu-sandbox", "--single-process", "--no-zygote",
    "--disable-site-isolation-trials", "--disable-web-security",
};

// Birch's own hardening. Most are no-ops in Qt WebEngine (it leaves Chrome's
// Google services out), kept as defence in depth; the NetLog comparison with
// BIRCH_BASELINE=1 shows which actually change anything.
static const char kHardening[] =
    "--disable-background-networking --disable-component-update --disable-domain-reliability "
    "--no-pings --disable-breakpad";

static QString g_flagsInUse;

bool prepareChromiumFlags(int argc, char **argv)
{
    QByteArray flags = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
    QByteArray all = flags;
    for (int i = 1; i < argc; ++i)
        all += ' ' + QByteArray(argv[i]);
    for (const char *bad : kForbiddenSwitches) {
        if (all.contains(bad)) {
            log(QStringLiteral("sandbox: refused-switch expected=absent got=%1 (Birch never runs without Chromium's sandbox)")
                    .arg(QString::fromLatin1(bad)));
            return false;
        }
    }
    if (qEnvironmentVariableIsSet("QTWEBENGINE_DISABLE_SANDBOX")) {
        log(QStringLiteral("sandbox: refused-env expected=absent got=QTWEBENGINE_DISABLE_SANDBOX"));
        return false;
    }
    if (qEnvironmentVariable("BIRCH_BASELINE") != QLatin1String("1"))
        flags = QByteArray(kHardening) + (flags.isEmpty() ? QByteArray() : ' ' + flags);
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", flags);
    g_flagsInUse = QString::fromUtf8(flags);
    return true;
}

QString chromiumFlagsInUse() { return g_flagsInUse; }

QString displayOrigin(const QUrl &url)
{
    if (!url.isValid())
        return QStringLiteral("(none)");
    QString host = url.host(QUrl::EncodeUnicode);  // ASCII/punycode, never Unicode
    if (host.isEmpty())
        return url.scheme() + QLatin1Char(':');
    if (host.contains(QLatin1Char(':')))
        host = QLatin1Char('[') + host + QLatin1Char(']');
    QString out = url.scheme() + QStringLiteral("://") + host;
    if (url.port() != -1)
        out += QLatin1Char(':') + QString::number(url.port());
    return out;
}

static bool testMode() { return !qEnvironmentVariable("BIRCH_HOME").isEmpty(); }

void applyPrivacy(QWebEngineProfile *p)
{
    p->setSpellCheckEnabled(false);   // no dictionary downloads either way; keep it off
    p->setPushServiceEnabled(false);  // push would use Google's push service
    p->setNotificationPresenter([](std::unique_ptr<QWebEngineNotification> n) {
        log(QStringLiteral("perm: notification-shown expected=0 got=1"));
        n->close();
    });
    QWebEngineSettings *s = p->settings();
    s->setAttribute(QWebEngineSettings::DnsPrefetchEnabled, false);
    s->setAttribute(QWebEngineSettings::HyperlinkAuditingEnabled, false);
    s->setAttribute(QWebEngineSettings::WebRTCPublicInterfacesOnly, true);
    s->setAttribute(QWebEngineSettings::LocalContentCanAccessRemoteUrls, false);
    s->setAttribute(QWebEngineSettings::LocalContentCanAccessFileUrls, false);
    s->setAttribute(QWebEngineSettings::AllowRunningInsecureContent, false);
    s->setAttribute(QWebEngineSettings::AllowGeolocationOnInsecureOrigins, false);
    s->setAttribute(QWebEngineSettings::JavascriptCanAccessClipboard, false);
    s->setAttribute(QWebEngineSettings::JavascriptCanPaste, false);
    // Test windows are never touched by a person, so the codec check may call play().
    if (testMode())
        s->setAttribute(QWebEngineSettings::PlaybackRequiresUserGesture, false);
}

QWebEngineProfile *normalProfile()
{
    static QWebEngineProfile *profile = nullptr;
    if (profile)
        return profile;
    const QString home = qEnvironmentVariable("BIRCH_HOME");
    const QString base = home.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
        : home;
    // Tests (BIRCH_HOME set) keep cookies and cache in memory. A named profile
    // still needs a folder (extensions live there), and it is inside BIRCH_HOME.
    // BIRCH_PERSIST_SCRATCH=1 lets gate 2 prove what reaches disk, still only
    // inside the scratch folder.
    const bool persist = home.isEmpty() || qEnvironmentVariable("BIRCH_PERSIST_SCRATCH") == QLatin1String("1");
    QWebEngineProfileBuilder b;
    b.setPersistentStoragePath(base + QStringLiteral("/profile"))
        .setCachePath(base + QStringLiteral("/cache"))
        .setPersistentCookiesPolicy(persist ? QWebEngineProfile::AllowPersistentCookies
                                            : QWebEngineProfile::NoPersistentCookies)
        .setHttpCacheType(persist ? QWebEngineProfile::DiskHttpCache : QWebEngineProfile::MemoryHttpCache)
        .setPersistentPermissionsPolicy(QWebEngineProfile::PersistentPermissionsPolicy::AskEveryTime);
    profile = b.createProfile(QStringLiteral("birch"), qApp);
    applyPrivacy(profile);
    Downloads::instance()->watch(profile, false);
    return profile;
}

QWebEngineProfile *privateProfile()
{
    QWebEngineProfile *p = QWebEngineProfileBuilder::createOffTheRecordProfile(nullptr);
    p->setPersistentPermissionsPolicy(QWebEngineProfile::PersistentPermissionsPolicy::AskEveryTime);
    applyPrivacy(p);
    p->setUrlRequestInterceptor(new PrivateBlocker(p));
    Downloads::instance()->watch(p, true);
    return p;
}

void PrivateBlocker::interceptRequest(QWebEngineUrlRequestInfo &info)
{
    const QString host = info.requestUrl().host(QUrl::EncodeUnicode).toLower();
    if (host == QLatin1String("adnxs.com") || host.endsWith(QLatin1String(".adnxs.com"))) {
        info.block(true);
        ++blocked;
    }
}

QString permissionName(QWebEnginePermission::PermissionType t)
{
    using T = QWebEnginePermission::PermissionType;
    switch (t) {
    case T::MediaAudioCapture: return QStringLiteral("microphone");
    case T::MediaVideoCapture: return QStringLiteral("camera");
    case T::MediaAudioVideoCapture: return QStringLiteral("camera+microphone");
    case T::DesktopVideoCapture: return QStringLiteral("screen");
    case T::DesktopAudioVideoCapture: return QStringLiteral("screen+audio");
    case T::MouseLock: return QStringLiteral("mouselock");
    case T::Notifications: return QStringLiteral("notifications");
    case T::Geolocation: return QStringLiteral("location");
    case T::ClipboardReadWrite: return QStringLiteral("clipboard");
    case T::LocalFontsAccess: return QStringLiteral("localfonts");
    default: return QStringLiteral("other");
    }
}

Page::Page(QWebEngineProfile *profile, QObject *parent) : QWebEnginePage(profile, parent)
{
    // Every permission is refused by default and nothing is remembered
    // (AskEveryTime). A real build shows a prompt here; never auto-grant.
    connect(this, &QWebEnginePage::permissionRequested, this, [this](QWebEnginePermission perm) {
        const QString name = permissionName(perm.permissionType());
        permissionRequests[name] += 1;
        log(QStringLiteral("perm: request type=%1 origin=%2 private=%3 action=deny")
                .arg(name, displayOrigin(perm.origin()), yesNo(this->profile()->isOffTheRecord())));
        perm.deny();
    });
    connect(this, &QWebEnginePage::certificateError, this, [this](const QWebEngineCertificateError &e) {
        ++certificateErrors;
        lastCertificateOverridable = e.isOverridable();
        log(QStringLiteral("tls: certificate-error type=%1 overridable=%2 action=reject")
                .arg(int(e.type()))
                .arg(yesNo(e.isOverridable())));
        QWebEngineCertificateError copy = e;
        copy.rejectCertificate();
    });
    connect(this, &QWebEnginePage::loadFinished, this, [this](bool) { m_allowInternal = false; });
}

void Page::showInternalHtml(const QString &html)
{
    m_allowInternal = true;
    setHtml(html, QUrl());
}

bool Page::acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame)
{
    const QString scheme = url.scheme().toLower();
    if (scheme == QLatin1String("data")) {
        if (m_allowInternal || !isMainFrame)
            return true;
        ++refusedNavigations;
        log(QStringLiteral("nav: refused main-frame data: navigation"));
        return false;
    }
    static const QSet<QString> web = {QStringLiteral("http"), QStringLiteral("https"), QStringLiteral("about"),
                                      QStringLiteral("blob"), QStringLiteral("chrome-extension"),
                                      QStringLiteral("qrc")};
    if (web.contains(scheme))
        return true;
    // chrome:// diagnostics only when the app itself loads them (never a page link).
    if (scheme == QLatin1String("chrome") && type == NavigationTypeTyped)
        return true;
    ++refusedNavigations;
    log(QStringLiteral("nav: refused scheme=%1 main-frame=%2 (a real build asks before opening another app)")
            .arg(scheme, yesNo(isMainFrame)));
    return false;
}

Downloads *Downloads::instance()
{
    static Downloads *d = new Downloads;
    return d;
}

void Downloads::watch(QWebEngineProfile *profile, bool isPrivate)
{
    connect(profile, &QWebEngineProfile::downloadRequested, this,
            [this, isPrivate](QWebEngineDownloadRequest *d) { handle(d, isPrivate); });
}

void Downloads::handle(QWebEngineDownloadRequest *d, bool isPrivate)
{
    const QString dir = qEnvironmentVariable(
        "BIRCH_DOWNLOADS", QStandardPaths::writableLocation(QStandardPaths::DownloadLocation));
    d->setDownloadDirectory(dir);
    const QUrl source = d->url();
    log(QStringLiteral("download: requested private=%1").arg(yesNo(isPrivate)));
    connect(d, &QWebEngineDownloadRequest::isFinishedChanged, this, [this, d, isPrivate, source]() {
        if (!d->isFinished())
            return;
        const QString path = QDir(d->downloadDirectory()).filePath(d->downloadFileName());
        int zone = -1;
        const bool native = readMarkOfTheWeb(path, &zone);
        bool final = native;
        if (!native && d->state() == QWebEngineDownloadRequest::DownloadCompleted)
            final = writeMarkOfTheWeb(path, source, isPrivate) && readMarkOfTheWeb(path, &zone);
        emit finished(path, int(d->state()), native, final, zone);
    });
    d->accept();
}

bool readMarkOfTheWeb(const QString &path, int *zone)
{
    *zone = -1;
#ifdef Q_OS_WIN
    const std::wstring ads = QDir::toNativeSeparators(path).toStdWString() + L":Zone.Identifier";
    HANDLE h = CreateFileW(ads.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE)
        return false;
    char buf[4096];
    DWORD n = 0;
    const BOOL ok = ReadFile(h, buf, sizeof(buf) - 1, &n, nullptr);
    CloseHandle(h);
    if (!ok)
        return false;
    buf[n] = 0;
    const QByteArray text(buf, int(n));
    const int at = text.indexOf("ZoneId=");
    if (at >= 0)
        *zone = text.mid(at + 7, 2).trimmed().toInt();
    return true;
#elif defined(Q_OS_LINUX)
    // Linux has no Mark of the Web. Chromium may record the origin as an xattr.
    const QByteArray p = QFile::encodeName(path);
    const ssize_t n = getxattr(p.constData(), "user.xdg.origin.url", nullptr, 0);
    return n > 0;
#else
    Q_UNUSED(path);
    return false;
#endif
}

bool writeMarkOfTheWeb(const QString &path, const QUrl &source, bool isPrivate)
{
#ifdef Q_OS_WIN
    QByteArray text = "[ZoneTransfer]\r\nZoneId=3\r\n";
    if (!isPrivate && (source.scheme() == QLatin1String("http") || source.scheme() == QLatin1String("https")))
        text += "HostUrl=" + source.toEncoded(QUrl::RemoveUserInfo) + "\r\n";
    const std::wstring ads = QDir::toNativeSeparators(path).toStdWString() + L":Zone.Identifier";
    HANDLE h = CreateFileW(ads.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE)
        return false;
    DWORD written = 0;
    const BOOL ok = WriteFile(h, text.constData(), DWORD(text.size()), &written, nullptr);
    CloseHandle(h);
    return ok && written == DWORD(text.size());
#else
    Q_UNUSED(path);
    Q_UNUSED(source);
    Q_UNUSED(isPrivate);
    return false;
#endif
}

} // namespace Birch
