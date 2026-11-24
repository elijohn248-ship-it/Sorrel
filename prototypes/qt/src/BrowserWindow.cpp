#include "BrowserWindow.h"
#include "Engine.h"
#include "Log.h"
#include "Sidebar.h"

#include <QCursor>
#include <QDateTime>
#include <QLabel>
#include <QListWidget>
#include <QResizeEvent>
#include <QStackedWidget>
#include <QTimer>
#include <QWebEngineProfile>
#include <QWebEngineView>

namespace Birch {

static const char kCrashPage[] =
    "<!doctype html><meta charset=utf-8><title>Page crashed</title>"
    "<body style='font:15px system-ui;margin:12vh auto;max-width:34em;color:#333'>"
    "<h2>This page stopped working</h2><p>Birch kept the tab. Reload to try again.</p>";

void Tab::recover()
{
    showingCrashPage = false;
    if (lastGoodUrl.isValid())
        view->load(lastGoodUrl);
}

BrowserWindow::BrowserWindow(QWebEngineProfile *profile, bool isPrivate, QWidget *parent)
    : QMainWindow(parent), m_profile(profile), m_private(isPrivate)
{
    setWindowTitle(isPrivate ? QStringLiteral("Birch (Private)") : QStringLiteral("Birch"));
    resize(1200, 800);
    m_root = new QWidget(this);
    setCentralWidget(m_root);
    m_stack = new QStackedWidget(m_root);
    m_sidebar = new Sidebar(isPrivate, m_root);
    connect(m_sidebar->tabs(), &QListWidget::currentRowChanged, this, [this](int row) {
        if (row >= 0 && row < m_tabs.size() && m_stack->currentWidget() != m_tabs[row]->view)
            select(m_tabs[row]);
    });
    m_pointerTimer = new QTimer(this);
    m_pointerTimer->setInterval(40);  // like the Mac: watch the real cursor while hidden/peeking
    connect(m_pointerTimer, &QTimer::timeout, this, &BrowserWindow::pollPointer);
    m_pointerTimer->start();
    layoutChildren();
}

BrowserWindow::~BrowserWindow()
{
    // Pages must go before their profile. A private window owns its
    // off-the-record profile, which takes its in-memory data with it.
    const QList<Tab *> tabs = m_tabs;
    for (Tab *t : tabs)
        closeTab(t);
    if (m_private)
        delete m_profile;
}

Tab *BrowserWindow::newTab(const QUrl &url)
{
    auto *t = new Tab;
    t->setParent(this);
    t->page = new Page(m_profile, t);
    t->view = new QWebEngineView(m_stack);
    t->view->setPage(t->page);
    m_stack->addWidget(t->view);
    m_tabs.append(t);

    connect(t->page, &QWebEnginePage::urlChanged, this, [this, t](const QUrl &u) {
        if (u.scheme() == QLatin1String("http") || u.scheme() == QLatin1String("https"))
            t->lastGoodUrl = u;
        if (current() == t)
            refreshAddress();
    });
    connect(t->page, &QWebEnginePage::titleChanged, this, [this]() { refreshTabList(); });
    connect(t->page, &QWebEnginePage::loadFinished, t, [t](bool ok) {
        ++t->loadsFinished;
        t->lastLoadOk = ok;
        emit t->loaded(ok);
    });
    connect(t->page, &QWebEnginePage::renderProcessTerminated, this,
            [this, t](QWebEnginePage::RenderProcessTerminationStatus status, int code) {
                ++t->terminations;
                t->lastTerminationStatus = int(status);
                log(QStringLiteral("crash: renderer-terminated status=%1 code=%2").arg(int(status)).arg(code));
                QTimer::singleShot(0, t, [this, t]() {
                    t->showingCrashPage = true;
                    t->page->showInternalHtml(QString::fromLatin1(kCrashPage));
                    if (current() == t)
                        refreshAddress();
                    emit t->terminated();
                });
            });

    t->view->load(url);
    select(t);
    refreshTabList();
    return t;
}

void BrowserWindow::closeTab(Tab *t)
{
    if (!m_tabs.contains(t))
        return;
    m_tabs.removeAll(t);
    m_stack->removeWidget(t->view);
    delete t->view;   // the view first, then the page (owned by the tab)
    t->view = nullptr;
    delete t;
    refreshTabList();
    refreshAddress();
}

void BrowserWindow::select(Tab *t)
{
    if (!t)
        return;
    m_stack->setCurrentWidget(t->view);
    const int row = int(m_tabs.indexOf(t));
    if (m_sidebar->tabs()->currentRow() != row)
        m_sidebar->tabs()->setCurrentRow(row);
    refreshAddress();
}

Tab *BrowserWindow::current() const
{
    for (Tab *t : m_tabs)
        if (m_stack->currentWidget() == t->view)
            return t;
    return nullptr;
}

QString BrowserWindow::addressText() const
{
    const Tab *t = current();
    if (!t)
        return QStringLiteral("(none)");
    if (t->showingCrashPage)
        return QStringLiteral("birch:crashed");
    return displayOrigin(t->page->url());
}

void BrowserWindow::refreshAddress()
{
    const Tab *t = current();
    const bool insecure = t && t->page->url().scheme() == QLatin1String("http");
    m_sidebar->address()->setText((insecure ? QStringLiteral("Not secure  ") : QString()) + addressText());
}

void BrowserWindow::refreshTabList()
{
    QListWidget *list = m_sidebar->tabs();
    const QSignalBlocker block(list);
    list->clear();
    for (Tab *t : m_tabs) {
        QString title = t->page->title();
        if (title.isEmpty())
            title = displayOrigin(t->page->url());
        list->addItem(title.left(40));
    }
    list->setCurrentRow(int(m_tabs.indexOf(current())));
}

void BrowserWindow::setSidebarMode(SidebarMode mode)
{
    m_mode = mode;
    m_revealed = false;
    m_sidebar->setFloating(mode == SidebarMode::Hidden);
    layoutChildren();
}

void BrowserWindow::reveal(bool show)
{
    if (m_mode != SidebarMode::Hidden)
        return;
    m_revealed = show;
    m_sidebar->raise();
    m_sidebar->slideTo(show ? 0 : -kSidebarWidth, show);
}

void BrowserWindow::setHoverTracking(bool on)
{
    if (on)
        m_pointerTimer->start();
    else
        m_pointerTimer->stop();
}

void BrowserWindow::resizeEvent(QResizeEvent *e)
{
    QMainWindow::resizeEvent(e);
    layoutChildren();
}

void BrowserWindow::layoutChildren()
{
    const int w = m_root->width(), h = m_root->height();
    if (m_mode == SidebarMode::Pinned) {
        m_sidebar->setGeometry(0, 0, kSidebarWidth, h);
        m_stack->setGeometry(kSidebarWidth, 0, qMax(0, w - kSidebarWidth), h);
    } else {
        m_stack->setGeometry(0, 0, w, h);
        m_sidebar->setGeometry(m_revealed ? 0 : -kSidebarWidth, 0, kSidebarWidth, h);
        m_sidebar->raise();
    }
}

void BrowserWindow::pollPointer()
{
    if (m_mode != SidebarMode::Hidden || !isVisible())
        return;
    const QPoint p = m_root->mapFromGlobal(QCursor::pos());
    if (p.y() < 0 || p.y() > m_root->height())
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!m_revealed && p.x() >= 0 && p.x() <= 6) {
        reveal(true);
    } else if (m_revealed && p.x() > kSidebarWidth + 24) {
        if (m_leftAt == 0)
            m_leftAt = now;
        else if (now - m_leftAt > 300) {
            m_leftAt = 0;
            reveal(false);
        }
    } else {
        m_leftAt = 0;
    }
}

} // namespace Birch
