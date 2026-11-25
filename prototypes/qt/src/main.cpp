// Birch Qt WebEngine prototype (wave 1). Throwaway: just enough browser to run
// the 12 engine gates in docs/chromium-agents.md. Not the product.
//
// Test hooks (shared rule 7): BIRCH_HOME (scratch profile folder; required for
// any test), BIRCH_OPEN, BIRCH_DELAY, BIRCH_SNAPSHOT, BIRCH_GATES, plus the
// gate-specific variables read in Gates.cpp.
#include "BrowserWindow.h"
#include "Engine.h"
#include "Gates.h"
#include "Log.h"

#include <QApplication>
#include <QNetworkProxy>
#include <QNetworkProxyFactory>
#include <QTimer>
#include <QUrl>

int main(int argc, char **argv)
{
    // Chromium's switches must be fixed before Qt WebEngine starts.
    if (!Birch::prepareChromiumFlags(argc, argv))
        return 3;

    QCoreApplication::setOrganizationName(QStringLiteral("Birch"));
    QCoreApplication::setApplicationName(QStringLiteral("BirchQtPrototype"));
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
    QApplication app(argc, argv);
    if (qEnvironmentVariable("BIRCH_BASELINE") != QLatin1String("1")) {
        // Qt WebEngine takes its proxy from Qt Network. Pin "no proxy" so nothing
        // tries Windows' proxy auto-discovery (WPAD); see REPORT.md, gate 5.
        QNetworkProxyFactory::setUseSystemConfiguration(false);
        QNetworkProxy::setApplicationProxy(QNetworkProxy(QNetworkProxy::NoProxy));
    }

    const bool testing = !qEnvironmentVariable("BIRCH_HOME").isEmpty();
    const bool quiet = !qEnvironmentVariable("BIRCH_SNAPSHOT").isEmpty();
    if (!testing && !qEnvironmentVariable("BIRCH_GATES").isEmpty()) {
        Birch::log(QStringLiteral("gates: refused expected=BIRCH_HOME got=unset (tests never use a real profile)"));
        return 2;
    }

    Birch::BrowserWindow window(Birch::normalProfile(), false);
    if (quiet) {
        // Test windows stay in the background and never take focus.
        window.setAttribute(Qt::WA_ShowWithoutActivating);
        window.setWindowFlag(Qt::WindowDoesNotAcceptFocus);
    }
    window.show();

    if (!qEnvironmentVariable("BIRCH_GATES").isEmpty()) {
        auto *gates = new Birch::Gates(&window, &app);
        gates->start();
    } else {
        window.newTab(QUrl::fromUserInput(qEnvironmentVariable("BIRCH_OPEN", QStringLiteral("about:blank"))));
        const int delay = qEnvironmentVariable("BIRCH_DELAY").toInt();
        if (delay > 0) {
            QTimer::singleShot(delay * 1000, &app, [&window]() {
                const QString snap = qEnvironmentVariable("BIRCH_SNAPSHOT");
                if (!snap.isEmpty())
                    window.grab().save(snap);
                qApp->quit();
            });
        }
    }
    const int code = app.exec();
    Birch::log(QStringLiteral("app: exit code=%1").arg(code));
    return code;
}
