// Just enough window to test: tabs in a sidebar list, an address label that
// shows the committed page's real origin, back/forward/reload, crash recovery,
// and a sidebar that can be pinned or hidden (hover reveal).
#pragma once
#include <QMainWindow>
#include <QPointer>
#include <QUrl>

class QStackedWidget;
class QTimer;
class QWebEngineProfile;
class QWebEngineView;

namespace Birch {

class Page;
class Sidebar;

class Tab : public QObject {
    Q_OBJECT
public:
    QWebEngineView *view = nullptr;
    Page *page = nullptr;
    QUrl lastGoodUrl;          // last committed http(s) URL, for crash recovery
    bool showingCrashPage = false;
    int terminations = 0;
    int lastTerminationStatus = -1;
    int loadsFinished = 0;
    bool lastLoadOk = false;
    void recover();
signals:
    void terminated();
    void loaded(bool ok);
};

class BrowserWindow : public QMainWindow {
    Q_OBJECT
public:
    BrowserWindow(QWebEngineProfile *profile, bool isPrivate, QWidget *parent = nullptr);
    ~BrowserWindow() override;

    Tab *newTab(const QUrl &url);
    void closeTab(Tab *tab);
    void select(Tab *tab);
    Tab *current() const;
    int tabCount() const { return int(m_tabs.size()); }
    QString addressText() const;
    QWebEngineProfile *profile() const { return m_profile; }
    bool isPrivate() const { return m_private; }
    Sidebar *sidebar() const { return m_sidebar; }

    enum class SidebarMode { Pinned, Hidden };
    void setSidebarMode(SidebarMode mode);
    SidebarMode sidebarMode() const { return m_mode; }
    void reveal(bool show);  // hidden mode: slide the overlay in/out

protected:
    void resizeEvent(QResizeEvent *e) override;

private:
    void layoutChildren();
    void refreshAddress();
    void refreshTabList();
    void pollPointer();

    QWebEngineProfile *m_profile;
    bool m_private;
    QWidget *m_root = nullptr;
    QStackedWidget *m_stack = nullptr;
    Sidebar *m_sidebar = nullptr;
    QList<Tab *> m_tabs;
    SidebarMode m_mode = SidebarMode::Pinned;
    bool m_revealed = false;
    QTimer *m_pointerTimer = nullptr;
    qint64 m_leftAt = 0;
    static constexpr int kSidebarWidth = 240;
};

} // namespace Birch
