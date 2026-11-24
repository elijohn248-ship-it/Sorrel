#include "Gates.h"
#include "BrowserWindow.h"
#include "Engine.h"
#include "Log.h"
#include "ProcInfo.h"
#include "Sidebar.h"

#include <QApplication>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTimer>
#include <QWebEngineDownloadRequest>
#include <QWebEngineExtensionInfo>
#include <QWebEngineExtensionManager>
#include <QWebEngineProfile>
#include <QWebEngineView>
#include <QtWebEngineCore/qtwebenginecoreglobal.h>
#include <memory>

namespace Birch {

namespace {

QString envOr(const char *name, const QString &fallback = QString())
{
    const QString v = qEnvironmentVariable(name);
    return v.isEmpty() ? fallback : v;
}

QString boolText(const QVariant &v)
{
    if (!v.isValid())
        return QStringLiteral("none");
    return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
}

// Counts files under the roots that contain `marker` as ASCII or UTF-16LE.
struct ScanResult {
    int hits = 0;
    int scanned = 0;
    int unreadable = 0;
    QStringList hitFiles;
};

ScanResult scanFor(const QStringList &roots, const QByteArray &marker)
{
    ScanResult r;
    QByteArray wide;
    for (char c : marker) {
        wide.append(c);
        wide.append('\0');
    }
    for (const QString &root : roots) {
        if (root.isEmpty() || !QDir(root).exists())
            continue;
        QDirIterator it(root, QDir::Files | QDir::Hidden | QDir::System, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            QFile f(path);
            if (f.size() > 256LL * 1024 * 1024)
                continue;
            if (!f.open(QIODevice::ReadOnly)) {
                ++r.unreadable;
                continue;
            }
            const QByteArray data = f.readAll();
            ++r.scanned;
            if (data.contains(marker) || data.contains(wide)) {
                ++r.hits;
                if (r.hitFiles.size() < 8)
                    r.hitFiles << QDir(root).relativeFilePath(path);
            }
        }
    }
    return r;
}

} // namespace

Gates::Gates(BrowserWindow *main, QObject *parent) : QObject(parent), m_main(main)
{
    m_gates = envOr("BIRCH_GATES").split(QLatin1Char(','), Qt::SkipEmptyParts);
    m_port = envOr("BIRCH_FIXTURE_PORT", QStringLiteral("0")).toInt();
    m_tlsPort = envOr("BIRCH_TLS_PORT", QStringLiteral("0")).toInt();
    m_pid = QCoreApplication::applicationPid();
}

bool Gates::wants(const QString &gate) const { return m_gates.contains(gate); }

QUrl Gates::fx(const QString &host, const QString &path) const
{
    return QUrl(QStringLiteral("http://%1:%2%3").arg(host).arg(m_port).arg(path));
}

QString Gates::origin(const QString &host) const { return QStringLiteral("http://%1:%2").arg(host).arg(m_port); }

void Gates::add(const QString &name, Step step) { m_steps.append({name, std::move(step)}); }

void Gates::start()
{
    const int deadline = envOr("BIRCH_DELAY", QStringLiteral("300")).toInt();
    QTimer::singleShot(deadline * 1000, qApp, [this]() {
        log(QStringLiteral("gates: deadline-reached expected=0 got=1 step=%1").arg(m_current));
        qApp->exit(4);
    });

    addVersion();
    if (wants(QStringLiteral("nav")))
        addNavigation();
    if (wants(QStringLiteral("tls")))
        addTls();
    if (wants(QStringLiteral("perm")))
        addPermissions();
    if (wants(QStringLiteral("download")))
        addDownload();
    if (wants(QStringLiteral("sandbox")))
        addSandbox();
    if (wants(QStringLiteral("ads")))
        addAds(QStringLiteral("ads-control"), false);
    if (wants(QStringLiteral("codecs")))
        addCodecs();
    if (wants(QStringLiteral("ext")))
        addExtensions();
    if (wants(QStringLiteral("private")))
        addPrivateStorage();
    if (wants(QStringLiteral("sidebar")))
        addSidebar();
    if (wants(QStringLiteral("cost")))
        addCost();

    const int idle = envOr("BIRCH_IDLE", QStringLiteral("0")).toInt();
    if (idle > 0)
        add(QStringLiteral("idle"), [this, idle](Next next) {
            log(QStringLiteral("gates: idle seconds=%1").arg(idle));
            after(idle * 1000, next);
        });
    add(QStringLiteral("end"), [this](Next) {
        const QString snap = envOr("BIRCH_SNAPSHOT");
        if (!snap.isEmpty())
            m_main->grab().save(snap);
        log(QStringLiteral("gates: done"));
        QTimer::singleShot(500, qApp, []() { qApp->quit(); });
    });
    QTimer::singleShot(0, this, &Gates::runNext);
}

void Gates::runNext()
{
    if (m_index >= m_steps.size())
        return;
    auto &step = m_steps[m_index++];
    m_current = step.first;
    log(QStringLiteral("gates: step %1").arg(m_current));
    step.second([this]() { QTimer::singleShot(0, this, &Gates::runNext); });
}

// ---------------------------------------------------------------- helpers

void Gates::after(int ms, std::function<void()> fn) { QTimer::singleShot(ms, this, std::move(fn)); }

void Gates::waitFor(std::function<bool()> cond, int timeoutMs, std::function<void(bool)> done)
{
    auto *timer = new QTimer(this);
    auto clock = std::make_shared<QElapsedTimer>();
    clock->start();
    timer->setInterval(100);
    connect(timer, &QTimer::timeout, this, [timer, clock, cond, done, timeoutMs]() {
        if (cond()) {
            timer->stop();
            timer->deleteLater();
            done(true);
        } else if (clock->elapsed() > timeoutMs) {
            timer->stop();
            timer->deleteLater();
            done(false);
        }
    });
    timer->start();
}

void Gates::waitLoaded(Tab *t, int before, int timeoutMs, std::function<void(bool)> done)
{
    QPointer<Tab> tp = t;
    waitFor([tp, before]() { return !tp || tp->loadsFinished > before; }, timeoutMs,
            [tp, done](bool ok) { done(ok && tp && tp->lastLoadOk); });
}

void Gates::loadAndWait(Tab *t, const QUrl &url, int timeoutMs, std::function<void(bool)> done)
{
    const int before = t->loadsFinished;
    t->view->load(url);
    waitLoaded(t, before, timeoutMs, std::move(done));
}

void Gates::eval(Tab *t, const QString &js, std::function<void(const QVariant &)> done)
{
    // Fixed scripts only; nothing a page controls is pasted into them (rule 4).
    t->page->runJavaScript(js, 0, [done](const QVariant &v) { done(v); });
}

void Gates::pollJs(Tab *t, const QString &js, int timeoutMs, std::function<void(const QVariant &)> done)
{
    auto clock = std::make_shared<QElapsedTimer>();
    clock->start();
    auto again = std::make_shared<std::function<void()>>();
    QPointer<Tab> tp = t;
    *again = [this, tp, js, timeoutMs, done, clock, again]() {
        if (!tp) {
            done(QVariant());
            return;
        }
        eval(tp, js, [this, done, clock, again, timeoutMs](const QVariant &v) {
            const bool have = v.isValid() && !v.toString().isEmpty();
            if (have)
                done(v);
            else if (clock->elapsed() > timeoutMs)
                done(QVariant());
            else
                after(250, *again);
        });
    };
    (*again)();
}

void Gates::shot(QWidget *w, const QString &name)
{
    const QString dir = envOr("BIRCH_SHOTS");
    if (dir.isEmpty() || !w)
        return;
    QDir().mkpath(dir);
    const bool ok = w->grab().save(QDir(dir).filePath(name));
    log(QStringLiteral("shot: %1 saved=%2").arg(name, yesNo(ok)));
}

// ---------------------------------------------------------------- gates

void Gates::addVersion()
{
    add(QStringLiteral("version"), [](Next next) {
        log(QStringLiteral("version: qt=%1 webengine=%2 chromium=%3 security-patch=%4")
                .arg(QString::fromLatin1(qVersion()), QString::fromLatin1(qWebEngineVersion()),
                     QString::fromLatin1(qWebEngineChromiumVersion()),
                     QString::fromLatin1(qWebEngineChromiumSecurityPatchVersion())));
        log(QStringLiteral("flags: chromium=%1").arg(chromiumFlagsInUse()));
        // Qt's default QUrl::host() shows some IDNs in Unicode (TLD allow-list).
        // Birch always shows ASCII, so lookalikes appear as punycode.
        const QUrl lookalike(QStringLiteral("http://xn--80ak6aa92e.com/"));
        log(QStringLiteral("nav: qt-default-host-display host=%1 (info: never used for the address bar)")
                .arg(lookalike.host()));
        check(QStringLiteral("nav"), QStringLiteral("birch-display-of-lookalike"),
              QStringLiteral("http://xn--80ak6aa92e.com"), displayOrigin(lookalike));
        next();
    });
}

void Gates::addNavigation()
{
    add(QStringLiteral("nav-two-tabs"), [this](Next next) {
        m_tabA = m_main->newTab(fx(QStringLiteral("a.test"), QStringLiteral("/page1.html")));
        waitLoaded(m_tabA, 0, 15000, [this, next](bool ok) {
            check(QStringLiteral("nav"), QStringLiteral("load-a"), QStringLiteral("1"), yesNo(ok));
            loadAndWait(m_tabA, fx(QStringLiteral("a.test"), QStringLiteral("/page2.html")), 10000,
                        [this, next](bool ok2) {
                            check(QStringLiteral("nav"), QStringLiteral("load-a2"), QStringLiteral("1"), yesNo(ok2));
                            next();
                        });
        });
    });
    add(QStringLiteral("nav-back-forward-reload"), [this](Next next) {
        m_tabA->page->triggerAction(QWebEnginePage::Back);
        waitFor([this]() { return m_tabA->page->url().path() == QLatin1String("/page1.html"); }, 6000,
                [this, next](bool) {
                    check(QStringLiteral("nav"), QStringLiteral("back"), QStringLiteral("/page1.html"),
                          m_tabA->page->url().path());
                    m_tabA->page->triggerAction(QWebEnginePage::Forward);
                    waitFor([this]() { return m_tabA->page->url().path() == QLatin1String("/page2.html"); },
                            6000, [this, next](bool) {
                                check(QStringLiteral("nav"), QStringLiteral("forward"),
                                      QStringLiteral("/page2.html"), m_tabA->page->url().path());
                                const int before = m_tabA->loadsFinished;
                                m_tabA->page->triggerAction(QWebEnginePage::Reload);
                                waitLoaded(m_tabA, before, 8000, [this, next](bool ok) {
                                    check(QStringLiteral("nav"), QStringLiteral("reload"), QStringLiteral("1"),
                                          yesNo(ok));
                                    check(QStringLiteral("nav"), QStringLiteral("address-shows-origin"),
                                          origin(QStringLiteral("a.test")), m_main->addressText());
                                    next();
                                });
                            });
                });
    });
    add(QStringLiteral("nav-second-tab-punycode"), [this](Next next) {
        m_tabB = m_main->newTab(fx(QStringLiteral("b.test"), QStringLiteral("/page1.html")));
        waitLoaded(m_tabB, 0, 10000, [this, next](bool ok) {
            check(QStringLiteral("nav"), QStringLiteral("load-b"), QStringLiteral("1"), yesNo(ok));
            check(QStringLiteral("nav"), QStringLiteral("tab-count"), QStringLiteral("2"),
                  QString::number(m_main->tabCount()));
            // Cyrillic "аррӏе.com" (a lookalike of apple.com), mapped to the fixture server.
            const QString host = QString(u"аррӏе.com");
            const QUrl url(QStringLiteral("http://%1:%2/page1.html").arg(host).arg(m_port));
            loadAndWait(m_tabB, url, 10000, [this, next](bool ok2) {
                check(QStringLiteral("nav"), QStringLiteral("lookalike-load"), QStringLiteral("1"), yesNo(ok2));
                check(QStringLiteral("nav"), QStringLiteral("lookalike-address-is-punycode"),
                      origin(QStringLiteral("xn--80ak6aa92e.com")), m_main->addressText());
                next();
            });
        });
    });
    add(QStringLiteral("nav-pending-does-not-spoof"), [this](Next next) {
        m_main->select(m_tabA);
        // The fixture page starts a navigation to another site that never answers.
        eval(m_tabA, QStringLiteral("goHang()"), [](const QVariant &) {});
        after(2500, [this, next]() {
            check(QStringLiteral("nav"), QStringLiteral("address-during-pending-page-navigation"),
                  origin(QStringLiteral("a.test")), m_main->addressText());
            m_tabA->page->triggerAction(QWebEnginePage::Stop);
            after(500, next);
        });
    });
    add(QStringLiteral("nav-teardown"), [this](Next next) {
        const qint64 pid = m_tabB->page->renderProcessPid();
        QPointer<Page> page = m_tabB->page;
        m_main->closeTab(m_tabB);
        waitFor([pid]() { return !processAlive(pid); }, 10000, [this, pid, page, next](bool) {
            check(QStringLiteral("teardown"), QStringLiteral("page-deleted"), QStringLiteral("1"),
                  yesNo(page.isNull()));
            check(QStringLiteral("teardown"), QStringLiteral("renderer-exited"), QStringLiteral("1"),
                  yesNo(pid > 0 && !processAlive(pid)), QStringLiteral("pid-known=%1").arg(yesNo(pid > 0)));
            check(QStringLiteral("teardown"), QStringLiteral("tab-count"), QStringLiteral("1"),
                  QString::number(m_main->tabCount()));
            next();
        });
    });
    add(QStringLiteral("nav-crash"), [this](Next next) {
        m_main->select(m_tabA);
        const qint64 pid = m_tabA->page->renderProcessPid();
        const int before = m_tabA->terminations;
        m_tabA->view->load(QUrl(QStringLiteral("chrome://crash")));
        waitFor([this, before]() { return m_tabA->terminations > before; }, 4000,
                [this, pid, before, next](bool crashed) {
                    auto finish = [this, pid, next](const QString &method) {
                        check(QStringLiteral("crash"), QStringLiteral("renderer-terminated"), QStringLiteral("1"),
                              yesNo(m_tabA->terminations > 0), QStringLiteral("method=%1").arg(method));
                        after(800, [this, pid, next]() {
                            check(QStringLiteral("crash"), QStringLiteral("error-page-shown"), QStringLiteral("1"),
                                  yesNo(m_tabA->showingCrashPage));
                            check(QStringLiteral("crash"), QStringLiteral("address-during-crash"),
                                  QStringLiteral("birch:crashed"), m_main->addressText());
                            const int loads = m_tabA->loadsFinished;
                            m_tabA->recover();
                            waitFor([this, loads]() { return m_tabA->loadsFinished > loads; }, 10000,
                                    [this, pid, next](bool) {
                                        check(QStringLiteral("crash"), QStringLiteral("recovered"),
                                              QStringLiteral("1"), yesNo(m_tabA->lastLoadOk));
                                        const qint64 now = m_tabA->page->renderProcessPid();
                                        check(QStringLiteral("crash"), QStringLiteral("new-renderer"),
                                              QStringLiteral("1"), yesNo(now > 0 && now != pid));
                                        check(QStringLiteral("crash"), QStringLiteral("address-after-recovery"),
                                              origin(QStringLiteral("a.test")), m_main->addressText());
                                        next();
                                    });
                        });
                    };
                    if (crashed) {
                        finish(QStringLiteral("chrome-crash-url"));
                        return;
                    }
                    log(QStringLiteral("crash: chrome://crash did not crash the renderer; killing pid"));
                    killProcess(pid);
                    waitFor([this, before]() { return m_tabA->terminations > before; }, 5000,
                            [finish](bool) { finish(QStringLiteral("os-kill")); });
                });
    });
}

void Gates::addTls()
{
    add(QStringLiteral("tls-bad-certificate"), [this](Next next) {
        const QUrl url(QStringLiteral("https://bad.test:%1/secret.html").arg(m_tlsPort));
        Tab *t = m_main->newTab(url);
        waitLoaded(t, 0, 12000, [this, t, next](bool ok) {
            check(QStringLiteral("tls"), QStringLiteral("error-reached-app"), QStringLiteral("1"),
                  yesNo(t->page->certificateErrors > 0));
            check(QStringLiteral("tls"), QStringLiteral("load-succeeded"), QStringLiteral("0"), yesNo(ok));
            check(QStringLiteral("tls"), QStringLiteral("address"),
                  QStringLiteral("https://bad.test:%1").arg(m_tlsPort), m_main->addressText());
            eval(t,
                 QStringLiteral("document.documentElement ? String(document.documentElement.innerText"
                                ".indexOf('BIRCH-SECRET') >= 0) : 'nodoc'"),
                 [this, t, next](const QVariant &v) {
                     check(QStringLiteral("tls"), QStringLiteral("secret-content-shown"), QStringLiteral("false"),
                           v.toString());
                     m_main->closeTab(t);
                     next();
                 });
        });
    });
}

void Gates::addPermissions()
{
    // Round 1 asks once; round 2 reloads the page (a new document) and asks again:
    // with AskEveryTime nothing may be remembered, so the app must be asked again.
    auto tab = std::make_shared<QPointer<Tab>>();
    auto round = [this, tab](int n) {
        return [this, tab, n](Next next) {
            const QUrl url(QStringLiteral("http://localhost:%1/perm.html").arg(m_port));
            auto run = [this, tab, n, next](bool) {
                Tab *t = *tab;
                eval(t, QStringLiteral("runPermTests(%1)").arg(n), [](const QVariant &) {});
                pollJs(t,
                       QStringLiteral("(window.__perm && window.__perm.done && window.__perm.round === %1) ? "
                                      "JSON.stringify(window.__perm) : ''")
                           .arg(n),
                       20000, [this, t, n, next](const QVariant &v) {
                           const QJsonObject o = QJsonDocument::fromJson(v.toString().toUtf8()).object();
                           const auto &asked = t->page->permissionRequests;
                           const int cam = asked.value(QStringLiteral("camera+microphone")) +
                               asked.value(QStringLiteral("camera")) + asked.value(QStringLiteral("microphone"));
                           const QString want = QString::number(n);
                           auto refused = [&o](const char *key) {
                               const QString r = o.value(QString::fromLatin1(key)).toString();
                               return (r.isEmpty() || r == QLatin1String("granted")) ? QStringLiteral("granted-or-missing")
                                                                                     : QStringLiteral("refused");
                           };
                           const QString detail = QStringLiteral("round=%1 page-says=%2").arg(n);
                           check(QStringLiteral("perm"), QStringLiteral("camera-mic-asked-app-times"), want,
                                 QString::number(cam));
                           check(QStringLiteral("perm"), QStringLiteral("camera-mic-page-result"),
                                 QStringLiteral("refused"), refused("cam"),
                                 detail.arg(o.value(QStringLiteral("cam")).toString()));
                           check(QStringLiteral("perm"), QStringLiteral("location-asked-app-times"), want,
                                 QString::number(asked.value(QStringLiteral("location"))));
                           check(QStringLiteral("perm"), QStringLiteral("location-page-result"),
                                 QStringLiteral("denied"), o.value(QStringLiteral("geo")).toString());
                           check(QStringLiteral("perm"), QStringLiteral("notifications-asked-app-times"), want,
                                 QString::number(asked.value(QStringLiteral("notifications"))));
                           check(QStringLiteral("perm"), QStringLiteral("notifications-page-result"),
                                 QStringLiteral("denied"), o.value(QStringLiteral("notif")).toString());
                           if (n == 2)
                               m_main->closeTab(t);
                           next();
                       });
            };
            if (n == 1) {
                *tab = m_main->newTab(url);
                waitLoaded(*tab, 0, 10000, run);
            } else {
                loadAndWait(*tab, url, 10000, run);
            }
        };
    };
    add(QStringLiteral("perm-round-1"), round(1));
    add(QStringLiteral("perm-round-2-new-document-asks-again"), round(2));
}

void Gates::addDownload()
{
    add(QStringLiteral("download"), [this](Next next) {
        struct Result {
            bool done = false;
            QString path;
            int state = -1;
            bool native = false, final = false;
            int zone = -1;
        };
        auto res = std::make_shared<Result>();
        auto conn = std::make_shared<QMetaObject::Connection>();
        *conn = connect(Downloads::instance(), &Downloads::finished, this,
                        [res](const QString &path, int state, bool native, bool final, int zone) {
                            res->done = true;
                            res->path = path;
                            res->state = state;
                            res->native = native;
                            res->final = final;
                            res->zone = zone;
                        });
        Tab *t = m_main->newTab(fx(QStringLiteral("dl.test"), QStringLiteral("/download.bin")));
        waitFor([res]() { return res->done; }, 20000, [this, res, conn, t, next](bool) {
            disconnect(*conn);
            const QString dir = envOr("BIRCH_DOWNLOADS");
            check(QStringLiteral("download"), QStringLiteral("state"), QStringLiteral("completed"),
                  res->state == int(QWebEngineDownloadRequest::DownloadCompleted) ? QStringLiteral("completed")
                                                                                  : QString::number(res->state));
            check(QStringLiteral("download"), QStringLiteral("in-scratch-folder"), QStringLiteral("1"),
                  yesNo(!dir.isEmpty() && QDir::cleanPath(res->path).startsWith(QDir::cleanPath(dir))));
            check(QStringLiteral("download"), QStringLiteral("file-exists"), QStringLiteral("1"),
                  yesNo(QFile::exists(res->path)));
#ifdef Q_OS_WIN
            check(QStringLiteral("motw"), QStringLiteral("set-by-engine"), QStringLiteral("1"), yesNo(res->native));
            check(QStringLiteral("motw"), QStringLiteral("present-after-birch"), QStringLiteral("1"),
                  yesNo(res->final));
            check(QStringLiteral("motw"), QStringLiteral("zone"), QStringLiteral("3"), QString::number(res->zone));
#else
            log(QStringLiteral("motw: linux-origin-xattr got=%1 (info; Linux has no Mark of the Web)")
                    .arg(yesNo(res->native)));
#endif
            m_main->closeTab(t);
            next();
        });
    });
}

void Gates::addSandbox()
{
    add(QStringLiteral("sandbox-processes"), [this](Next next) {
        log(QStringLiteral("sandbox: ready"));
        after(3000, [this, next]() {
            const QList<ProcRow> rows = processTree(m_pid);
            // On Linux renderers are forked from the zygote and keep its command line,
            // so they are found by the pids Qt reports for the open tabs.
            QSet<qint64> rendererPids;
            for (Tab *t : m_main->tabs())
                if (t->page->renderProcessPid() > 0)
                    rendererPids.insert(t->page->renderProcessPid());
            log(QStringLiteral("sandbox: tab-renderer-pids count=%1").arg(rendererPids.size()));
            int renderers = 0, rendererOk = 0, noSandbox = 0, gpu = 0;
            QStringList types;
            for (const ProcRow &r : rows) {
                log(QStringLiteral("sandbox: proc pid=%1 exe=%2 type=%3 integrity=%4 restricted=%5 appcontainer=%6 "
                                   "job=%7 seccomp=%8 pidns-depth=%9 no-sandbox-switch=%10 private-mb=%11")
                        .arg(r.pid)
                        .arg(r.exe, r.type, r.integrity.isEmpty() ? QStringLiteral("n/a") : r.integrity)
                        .arg(r.restricted)
                        .arg(r.appContainer)
                        .arg(r.inJob)
                        .arg(r.seccomp)
                        .arg(r.pidNamespaceDepth)
                        .arg(yesNo(r.noSandboxSwitch))
                        .arg(r.privateMb, 0, 'f', 1));
                types << r.type;
                if (r.noSandboxSwitch)
                    ++noSandbox;
                if (r.type.startsWith(QLatin1String("gpu")))
                    ++gpu;
                if (r.type == QLatin1String("renderer") || rendererPids.contains(r.pid)) {
                    log(QStringLiteral("sandbox: renderer pid=%1 seccomp=%2 pidns-depth=%3 integrity=%4 restricted=%5 job=%6")
                            .arg(r.pid)
                            .arg(r.seccomp)
                            .arg(r.pidNamespaceDepth)
                            .arg(r.integrity)
                            .arg(r.restricted)
                            .arg(r.inJob));
                    ++renderers;
#ifdef Q_OS_WIN
                    const bool ok = (r.integrity == QLatin1String("untrusted") || r.integrity == QLatin1String("low")) &&
                        r.restricted == 1 && r.inJob == 1;
#else
                    const bool ok = r.seccomp == 2 && r.pidNamespaceDepth >= 2;
#endif
                    if (ok)
                        ++rendererOk;
                }
            }
            log(QStringLiteral("sandbox: process-types %1").arg(types.join(QLatin1Char(','))));
            check(QStringLiteral("sandbox"), QStringLiteral("renderers-found"), QStringLiteral("1"),
                  yesNo(renderers > 0), QStringLiteral("count=%1").arg(renderers));
            check(QStringLiteral("sandbox"), QStringLiteral("all-renderers-sandboxed"), QStringLiteral("1"),
                  yesNo(renderers > 0 && rendererOk == renderers),
                  QStringLiteral("ok=%1/%2").arg(rendererOk).arg(renderers));
            check(QStringLiteral("sandbox"), QStringLiteral("no-sandbox-switch-count"), QStringLiteral("0"),
                  QString::number(noSandbox));
            log(QStringLiteral("sandbox: separate-gpu-process-count got=%1 (info: 0 means GPU work runs inside the "
                               "unsandboxed app process)")
                    .arg(gpu));
            if (!rows.isEmpty())
                log(QStringLiteral("sandbox: app-process integrity=%1 restricted=%2 appcontainer=%3 (whole-app "
                                   "confinement info)")
                        .arg(rows.first().integrity)
                        .arg(rows.first().restricted)
                        .arg(rows.first().appContainer));
            next();
        });
    });
    add(QStringLiteral("sandbox-status-page"), [this](Next next) {
        Tab *t = m_main->newTab(QUrl(QStringLiteral("chrome://sandbox")));
        waitLoaded(t, 0, 8000, [this, t, next](bool ok) {
            eval(t,
                 QStringLiteral("(document.title || '') + ' | ' + ((document.body ? document.body.innerText : '')"
                                ".split('\\n').filter(l => /sandbox|seccomp|namespace|adequate|yes|no\\b/i.test(l))"
                                ".slice(0, 30).map(l => l.trim().slice(0, 100)).join(' ; '))"),
                 [this, t, ok, next](const QVariant &v) {
                     log(QStringLiteral("sandbox: chrome-sandbox-page loaded=%1 text=%2").arg(yesNo(ok), v.toString()));
                     shot(m_main, QStringLiteral("chrome-sandbox.png"));
                     m_main->closeTab(t);
                     next();
                 });
        });
    });
}

void Gates::addAds(const QString &area, bool expectBlocked)
{
    add(QStringLiteral("ads-") + area, [this, area, expectBlocked](Next next) {
        Tab *t = m_main->newTab(fx(QStringLiteral("site.test"), QStringLiteral("/ads.html")));
        waitLoaded(t, 0, 10000, [this, t, area, expectBlocked, next](bool) {
            pollJs(t, QStringLiteral("(window.__ads && window.__ads.done) ? JSON.stringify(window.__ads) : ''"), 10000,
                   [this, t, area, expectBlocked, next](const QVariant &v) {
                       const QJsonObject o = QJsonDocument::fromJson(v.toString().toUtf8()).object();
                       check(area, QStringLiteral("tracker-request-loaded"),
                             expectBlocked ? QStringLiteral("false") : QStringLiteral("true"),
                             boolText(o.value(QStringLiteral("tracker")).toVariant()));
                       check(area, QStringLiteral("first-party-loaded"), QStringLiteral("true"),
                             boolText(o.value(QStringLiteral("firstParty")).toVariant()));
                       m_main->closeTab(t);
                       next();
                   });
        });
    });
}

void Gates::addCodecs()
{
    add(QStringLiteral("codecs"), [this](Next next) {
        Tab *t = m_main->newTab(QUrl(QStringLiteral("http://127.0.0.1:%1/codecs.html").arg(m_port)));
        waitLoaded(t, 0, 10000, [this, t, next](bool) {
            eval(t, QStringLiteral("runCodecTests()"), [](const QVariant &) {});
            pollJs(t, QStringLiteral("(window.__codec && window.__codec.done) ? JSON.stringify(window.__codec) : ''"),
                   150000, [this, t, next](const QVariant &v) {
                       const QJsonObject o = QJsonDocument::fromJson(v.toString().toUtf8()).object();
                       for (const QJsonValue &f : o.value(QStringLiteral("files")).toArray()) {
                           const QJsonObject r = f.toObject();
                           log(QStringLiteral("codec: name=%1 canplay=%2 mse=%3 load=%4 width=%5 duration=%6 played=%7")
                                   .arg(r.value(QStringLiteral("name")).toString(),
                                        r.value(QStringLiteral("canplay")).toString(),
                                        r.value(QStringLiteral("mse")).toString(),
                                        r.value(QStringLiteral("load")).toString())
                                   .arg(r.value(QStringLiteral("width")).toInt())
                                   .arg(r.value(QStringLiteral("duration")).toDouble())
                                   .arg(r.value(QStringLiteral("played")).toVariant().toString()));
                       }
                       for (const char *k : {"widevine_mp4", "widevine_webm", "clearkey"})
                           log(QStringLiteral("drm: %1 got=%2")
                                   .arg(QString::fromLatin1(k), o.value(QString::fromLatin1(k)).toString()));
                       if (o.isEmpty())
                           log(QStringLiteral("codec: results expected=present got=none"));
                       m_main->closeTab(t);
                       next();
                   });
        });
    });
}

void Gates::addSidebar()
{
    add(QStringLiteral("sidebar"), [this](Next next) {
        Tab *t = m_main->newTab(fx(QStringLiteral("site.test"), QStringLiteral("/page1.html")));
        waitLoaded(t, 0, 10000, [this, t, next](bool) {
            // The real hover logic would hide the overlay again (the CI pointer is far
            // from the sidebar), so the test drives reveal() itself.
            m_main->setHoverTracking(false);
            m_main->setSidebarMode(BrowserWindow::SidebarMode::Pinned);
            after(600, [this, t, next]() {
                shot(m_main, QStringLiteral("sidebar-pinned.png"));
                m_main->setSidebarMode(BrowserWindow::SidebarMode::Hidden);
                after(400, [this, t, next]() {
                    shot(m_main, QStringLiteral("sidebar-hidden.png"));
                    m_main->reveal(true);
                    after(110, [this]() { shot(m_main, QStringLiteral("sidebar-reveal-mid.png")); });
                    after(600, [this, t, next]() {
                        shot(m_main, QStringLiteral("sidebar-revealed.png"));
                        const Sidebar::MotionStats s = m_main->sidebar()->lastMotion();
                        log(QStringLiteral("motion: reveal frames=%1 duration-ms=%2 mean-gap-ms=%3 max-gap-ms=%4")
                                .arg(s.frames)
                                .arg(s.durationMs, 0, 'f', 1)
                                .arg(s.meanGapMs, 0, 'f', 1)
                                .arg(s.maxGapMs, 0, 'f', 1));
                        check(QStringLiteral("motion"), QStringLiteral("revealed-x"), QStringLiteral("0"),
                              QString::number(m_main->sidebar()->x()));
                        m_main->reveal(false);
                        after(500, [this, t, next]() {
                            const Sidebar::MotionStats h = m_main->sidebar()->lastMotion();
                            log(QStringLiteral("motion: hide frames=%1 duration-ms=%2 mean-gap-ms=%3 max-gap-ms=%4")
                                    .arg(h.frames)
                                    .arg(h.durationMs, 0, 'f', 1)
                                    .arg(h.meanGapMs, 0, 'f', 1)
                                    .arg(h.maxGapMs, 0, 'f', 1));
                            check(QStringLiteral("motion"), QStringLiteral("hidden-x"), QStringLiteral("-240"),
                                  QString::number(m_main->sidebar()->x()));
                            m_main->setSidebarMode(BrowserWindow::SidebarMode::Pinned);
                            m_main->setHoverTracking(true);
                            m_main->closeTab(t);
                            next();
                        });
                    });
                });
            });
        });
    });
}

void Gates::addExtensions()
{
    auto ubolInfo = std::make_shared<QWebEngineExtensionInfo>();
    add(QStringLiteral("ext-builtins"), [this](Next next) {
        QWebEngineExtensionManager *em = normalProfile()->extensionManager();
        check(QStringLiteral("ext"), QStringLiteral("manager-available"), QStringLiteral("1"), yesNo(em != nullptr));
        if (!em) {
            next();
            return;
        }
        int unloading = 0;
        for (const QWebEngineExtensionInfo &info : em->extensions()) {
            log(QStringLiteral("ext: builtin name=%1 id=%2 enabled=%3 loaded=%4 installed=%5")
                    .arg(info.name(), info.id(), yesNo(info.isEnabled()), yesNo(info.isLoaded()),
                         yesNo(info.isInstalled())));
            if (info.name().contains(QLatin1String("Hangouts"), Qt::CaseInsensitive)) {
                // Talks to *.google.com pages; Birch has no use for it.
                em->unloadExtension(info);
                ++unloading;
            }
        }
        after(unloading ? 2000 : 0, [em, next]() {
            for (const QWebEngineExtensionInfo &info : em->extensions())
                if (info.name().contains(QLatin1String("Hangouts"), Qt::CaseInsensitive))
                    check(QStringLiteral("ext"), QStringLiteral("hangouts-unloaded"), QStringLiteral("0"),
                          yesNo(info.isLoaded()));
            next();
        });
    });
    add(QStringLiteral("ext-install-ubol"), [this, ubolInfo](Next next) {
        QWebEngineExtensionManager *em = normalProfile()->extensionManager();
        const QString zip = envOr("BIRCH_UBOL_ZIP");
        if (!em || zip.isEmpty()) {
            log(QStringLiteral("ext: ubol-install expected=run got=skipped (no manager or BIRCH_UBOL_ZIP)"));
            next();
            return;
        }
        auto got = std::make_shared<bool>(false);
        auto conn = std::make_shared<QMetaObject::Connection>();
        *conn = connect(em, &QWebEngineExtensionManager::installFinished, this,
                        [got, ubolInfo](const QWebEngineExtensionInfo &info) {
                            *ubolInfo = info;
                            *got = true;
                        });
        em->installExtension(zip);
        waitFor([got]() { return *got; }, 30000, [this, em, got, conn, ubolInfo, next](bool) {
            disconnect(*conn);
            check(QStringLiteral("ext"), QStringLiteral("ubol-installed"), QStringLiteral("1"),
                  yesNo(*got && ubolInfo->error().isEmpty()),
                  QStringLiteral("error=[%1] name=[%2] id=%3")
                      .arg(ubolInfo->error(), ubolInfo->name(), ubolInfo->id()));
            if (!*got || !ubolInfo->error().isEmpty()) {
                next();
                return;
            }
            em->setExtensionEnabled(*ubolInfo, true);
            after(5000, [em, ubolInfo, next]() {
                bool enabled = false;
                for (const QWebEngineExtensionInfo &info : em->extensions())
                    if (info.id() == ubolInfo->id()) {
                        enabled = info.isEnabled();
                        *ubolInfo = info;
                    }
                check(QStringLiteral("ext"), QStringLiteral("ubol-enabled"), QStringLiteral("1"), yesNo(enabled));
                next();
            });
        });
    });
    addAds(QStringLiteral("ubol"), true);
    add(QStringLiteral("ext-ubol-popup"), [this, ubolInfo](Next next) {
        const QUrl popup = ubolInfo->actionPopupUrl();
        check(QStringLiteral("ext"), QStringLiteral("popup-url-scheme"), QStringLiteral("chrome-extension"),
              popup.scheme().isEmpty() ? QStringLiteral("none") : popup.scheme());
        if (popup.isEmpty()) {
            next();
            return;
        }
        // Qt has no browser-action popover: Birch would host this URL in its own popup view.
        Tab *t = m_main->newTab(popup);
        waitLoaded(t, 0, 10000, [this, t, next](bool ok) {
            check(QStringLiteral("ext"), QStringLiteral("popup-loaded"), QStringLiteral("1"), yesNo(ok));
            after(2500, [this, t, next]() {
                eval(t, QStringLiteral("String(document.querySelectorAll('*').length)"),
                     [this, t, next](const QVariant &v) {
                         check(QStringLiteral("ext"), QStringLiteral("popup-has-content"), QStringLiteral("1"),
                               yesNo(v.toString().toInt() > 20), QStringLiteral("elements=%1").arg(v.toString()));
                         shot(m_main, QStringLiteral("ubol-popup.png"));
                         // Which extension APIs Qt exposes to an extension page (names only).
                         eval(t,
                              QStringLiteral("(typeof chrome === 'object' ? Object.keys(chrome).sort().join(',') : 'none')"
                                             " + ' | dnr=' + typeof (chrome.declarativeNetRequest)"
                                             " + ' tabs=' + typeof (chrome.tabs) + ' permissions=' + typeof (chrome.permissions)"
                                             " + ' action=' + typeof (chrome.action) + ' scripting=' + typeof (chrome.scripting)"
                                             " + ' storage=' + typeof (chrome.storage) + ' offscreen=' + typeof (chrome.offscreen)"
                                             " + ' userScripts=' + typeof (chrome.userScripts) + ' windows=' + typeof (chrome.windows)"),
                              [this, t, next](const QVariant &apis) {
                                  log(QStringLiteral("ext: apis-in-extension-page %1").arg(apis.toString()));
                                  m_main->closeTab(t);
                                  next();
                              });
                     });
            });
        });
    });
    add(QStringLiteral("ext-dnr-probe"), [this](Next next) {
        // A minimal MV3 extension with one static declarativeNetRequest rule and no
        // background script: tells "Qt has no DNR" apart from "uBOL's background failed".
        QWebEngineExtensionManager *em = normalProfile()->extensionManager();
        const QString dir = envOr("BIRCH_DNR_PROBE");
        if (!em || dir.isEmpty()) {
            log(QStringLiteral("dnr-probe: install expected=run got=skipped"));
            next();
            return;
        }
        auto info = std::make_shared<QWebEngineExtensionInfo>();
        auto got = std::make_shared<bool>(false);
        auto conn = std::make_shared<QMetaObject::Connection>();
        *conn = connect(em, &QWebEngineExtensionManager::installFinished, this,
                        [info, got](const QWebEngineExtensionInfo &i) {
                            *info = i;
                            *got = true;
                        });
        em->installExtension(dir);
        waitFor([got]() { return *got; }, 20000, [this, em, info, got, conn, next](bool) {
            disconnect(*conn);
            check(QStringLiteral("dnr-probe"), QStringLiteral("installed"), QStringLiteral("1"),
                  yesNo(*got && info->error().isEmpty()), QStringLiteral("error=[%1]").arg(info->error()));
            if (*got && info->error().isEmpty())
                em->setExtensionEnabled(*info, true);
            after(4000, next);
        });
    });
    addAds(QStringLiteral("dnr-probe"), true);
    add(QStringLiteral("ext-private-window"), [this](Next next) {
        m_private = new BrowserWindow(privateProfile(), true);
        m_private->setAttribute(Qt::WA_ShowWithoutActivating);
        m_private->show();
        QWebEngineExtensionManager *pem = m_private->profile()->extensionManager();
        log(QStringLiteral("private-ubol: extension-manager-object-exists got=%1 extensions-listed=%2 (info: Qt "
                           "documents no extensions off the record)")
                .arg(yesNo(pem != nullptr))
                .arg(pem ? pem->extensions().size() : -1));
        int ubolInPrivate = 0;
        if (pem)
            for (const QWebEngineExtensionInfo &i : pem->extensions())
                if (i.name().contains(QLatin1String("uBlock"), Qt::CaseInsensitive) && i.isEnabled())
                    ++ubolInPrivate;
        check(QStringLiteral("private-ubol"), QStringLiteral("ubol-active-in-private-window"), QStringLiteral("0"),
              QString::number(ubolInPrivate));
        Tab *t = m_private->newTab(fx(QStringLiteral("site.test"), QStringLiteral("/ads.html")));
        waitLoaded(t, 0, 10000, [this, t, next](bool) {
            pollJs(t, QStringLiteral("(window.__ads && window.__ads.done) ? JSON.stringify(window.__ads) : ''"), 10000,
                   [this, next](const QVariant &v) {
                       const QJsonObject o = QJsonDocument::fromJson(v.toString().toUtf8()).object();
                       check(QStringLiteral("private-ubol"), QStringLiteral("tracker-loaded-with-birch-interceptor"),
                             QStringLiteral("false"), boolText(o.value(QStringLiteral("tracker")).toVariant()));
                       delete m_private;
                       next();
                   });
        });
    });
}

void Gates::addPrivateStorage()
{
    const QString markNorm = envOr("BIRCH_MARK_NORM", QStringLiteral("norm-x.test"));
    const QString markPriv = envOr("BIRCH_MARK_PRIV", QStringLiteral("priv-x.test"));
    add(QStringLiteral("private-normal-visit"), [this, markNorm](Next next) {
        Tab *t = m_main->newTab(fx(markNorm, QStringLiteral("/mark.html")));
        waitLoaded(t, 0, 10000, [this, t, next](bool ok) {
            check(QStringLiteral("private"), QStringLiteral("normal-visit-loaded"), QStringLiteral("1"), yesNo(ok));
            pollJs(t, QStringLiteral("window.__markDone ? 'yes' : ''"), 8000, [next](const QVariant &) { next(); });
        });
    });
    add(QStringLiteral("private-window-visit"), [this, markPriv](Next next) {
        m_private = new BrowserWindow(privateProfile(), true);
        m_private->setAttribute(Qt::WA_ShowWithoutActivating);
        m_private->show();
        Tab *t = m_private->newTab(fx(markPriv, QStringLiteral("/mark.html")));
        waitLoaded(t, 0, 10000, [this, t, markPriv, next](bool ok) {
            check(QStringLiteral("private"), QStringLiteral("private-visit-loaded"), QStringLiteral("1"), yesNo(ok));
            pollJs(t, QStringLiteral("window.__markDone ? 'yes' : ''"), 8000, [this, t, markPriv, next](const QVariant &) {
                eval(t, QStringLiteral("document.cookie.indexOf('birchmark_') >= 0 ? 'true' : 'false'"),
                     [this, t, markPriv, next](const QVariant &v) {
                         check(QStringLiteral("private"), QStringLiteral("cookie-works-in-memory"),
                               QStringLiteral("true"), v.toString());
                         // A second visit exercises the (in-memory) cache.
                         loadAndWait(t, fx(markPriv, QStringLiteral("/mark.html?again=1")), 10000,
                                     [this, next](bool) {
                                         shot(m_private, QStringLiteral("private-window.png"));
                                         after(2000, next);
                                     });
                     });
            });
        });
    });
    add(QStringLiteral("private-close-and-scan"), [this, markPriv, markNorm](Next next) {
        m_private->close();
        delete m_private;
        after(4000, [markPriv, markNorm, next]() {
            const QStringList roots = envOr("BIRCH_SCAN_ROOTS").split(QDir::listSeparator(), Qt::SkipEmptyParts);
            const ScanResult p = scanFor(roots, markPriv.toLatin1());
            check(QStringLiteral("private"), QStringLiteral("files-with-private-marker-after-close"),
                  QStringLiteral("0"), QString::number(p.hits),
                  QStringLiteral("scanned=%1 unreadable=%2 roots=%3").arg(p.scanned).arg(p.unreadable).arg(roots.size()));
            for (const QString &f : p.hitFiles)
                log(QStringLiteral("private: hit file=%1").arg(f));
            const ScanResult n = scanFor(roots, markNorm.toLatin1());
            log(QStringLiteral("private: normal-marker-files-while-running got=%1 (positive control; cookies may only "
                               "flush at exit)")
                    .arg(n.hits));
            next();
        });
    });
}

void Gates::addCost()
{
    add(QStringLiteral("cost-idle-memory"), [this](Next next) {
        // One blank tab, then 15 s of idle before measuring.
        Tab *t = m_main->newTab(QUrl(QStringLiteral("about:blank")));
        Q_UNUSED(t);
        after(15000, [this, next]() {
            const QList<ProcRow> rows = processTree(m_pid);
            double priv = 0, res = 0;
            QStringList parts;
            for (const ProcRow &r : rows) {
                priv += qMax(0.0, r.privateMb);
                res += qMax(0.0, r.residentMb);
                parts << QStringLiteral("%1:%2/%3").arg(r.type).arg(r.privateMb, 0, 'f', 0).arg(r.residentMb, 0, 'f', 0);
            }
            log(QStringLiteral("cost: idle-one-blank-tab processes=%1 private-mb=%2 resident-mb=%3 per-process=%4")
                    .arg(rows.size())
                    .arg(priv, 0, 'f', 1)
                    .arg(res, 0, 'f', 1)
                    .arg(parts.join(QLatin1Char(' '))));
            next();
        });
    });
}

} // namespace Birch
