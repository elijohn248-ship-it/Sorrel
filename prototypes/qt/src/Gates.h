// BIRCH_* test hooks for the 12 prototype gates. Each check logs
// "<area>: <what> expected=<x> got=<y>"; tests/run_gates.py reads them.
#pragma once
#include <QList>
#include <QObject>
#include <QPair>
#include <QPointer>
#include <QUrl>
#include <QVariant>
#include <functional>

namespace Birch {

class BrowserWindow;
class Tab;

class Gates : public QObject {
    Q_OBJECT
public:
    Gates(BrowserWindow *main, QObject *parent = nullptr);
    void start();

private:
    using Next = std::function<void()>;
    using Step = std::function<void(Next)>;
    void add(const QString &name, Step step);
    void runNext();
    bool wants(const QString &gate) const;

    void addVersion();
    void addNavigation();
    void addTls();
    void addPermissions();
    void addDownload();
    void addSandbox();
    void addAds(bool ubolExpected);
    void addCodecs();
    void addSidebar();
    void addExtensions();
    void addPrivateStorage();
    void addCost();

    // helpers
    void waitFor(std::function<bool()> cond, int timeoutMs, std::function<void(bool)> done);
    void after(int ms, std::function<void()> fn);
    void loadAndWait(Tab *t, const QUrl &url, int timeoutMs, std::function<void(bool)> done);
    void waitLoaded(Tab *t, int before, int timeoutMs, std::function<void(bool)> done);
    void eval(Tab *t, const QString &js, std::function<void(const QVariant &)> done);
    void pollJs(Tab *t, const QString &js, int timeoutMs, std::function<void(const QVariant &)> done);
    void shot(QWidget *w, const QString &name);
    QUrl fx(const QString &host, const QString &path) const;
    QString origin(const QString &host) const;

    BrowserWindow *m_main;
    QPointer<BrowserWindow> m_private;
    QList<QPair<QString, Step>> m_steps;
    int m_index = 0;
    QString m_current;
    QStringList m_gates;
    int m_port = 0;
    int m_tlsPort = 0;
    QPointer<Tab> m_tabA;
    QPointer<Tab> m_tabB;
    qint64 m_pid = 0;
};

} // namespace Birch
