// Everything that touches Qt WebEngine's engine-level policy: Chromium switches,
// profiles (normal / private), privacy settings, permissions, certificate
// errors, navigation policy and downloads.
#pragma once
#include <QHash>
#include <QObject>
#include <QSet>
#include <QUrl>
#include <QWebEnginePage>
#include <QWebEnginePermission>
#include <QWebEngineUrlRequestInterceptor>

class QWebEngineProfile;
class QWebEngineDownloadRequest;

namespace Birch {

// Must run before QApplication exists. Refuses any switch or variable that
// turns Chromium's sandbox off; prepends Birch's hardening switches unless
// BIRCH_BASELINE=1 (used only to measure what Qt does out of the box).
bool prepareChromiumFlags(int argc, char **argv);
QString chromiumFlagsInUse();

// The address bar text: scheme://host[:port], host always in ASCII (punycode),
// never Qt's "pretty" Unicode form.
QString displayOrigin(const QUrl &url);

QWebEngineProfile *normalProfile();
QWebEngineProfile *privateProfile();  // a fresh off-the-record profile per private window
void applyPrivacy(QWebEngineProfile *profile);

// Demo only: shows that private windows (which can't host extensions in Qt)
// can still get blocking through a request interceptor. A real build would
// compile EasyList/EasyPrivacy into this; the prototype blocks one ad domain.
class PrivateBlocker : public QWebEngineUrlRequestInterceptor {
    Q_OBJECT
public:
    using QWebEngineUrlRequestInterceptor::QWebEngineUrlRequestInterceptor;
    void interceptRequest(QWebEngineUrlRequestInfo &info) override;
    int blocked = 0;
};

class Page : public QWebEnginePage {
    Q_OBJECT
public:
    Page(QWebEngineProfile *profile, QObject *parent);
    void showInternalHtml(const QString &html);  // Birch's own pages (crash/error)
    QHash<QString, int> permissionRequests;      // type name -> times asked
    int certificateErrors = 0;
    bool lastCertificateOverridable = false;
    int refusedNavigations = 0;

protected:
    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override;

private:
    bool m_allowInternal = false;
};

QString permissionName(QWebEnginePermission::PermissionType t);

// Downloads go to BIRCH_DOWNLOADS (tests) or the user's Downloads folder.
// On Windows the Mark of the Web is checked and, if the engine didn't set it,
// written by Birch (ZoneId=3, without addresses for private windows).
class Downloads : public QObject {
    Q_OBJECT
public:
    static Downloads *instance();
    void watch(QWebEngineProfile *profile, bool isPrivate);
signals:
    void finished(const QString &path, int state, bool nativeMotw, bool finalMotw, int zone);
private:
    void handle(QWebEngineDownloadRequest *d, bool isPrivate);
};

bool readMarkOfTheWeb(const QString &path, int *zone);
bool writeMarkOfTheWeb(const QString &path, const QUrl &source, bool isPrivate);

} // namespace Birch
