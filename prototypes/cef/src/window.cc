// Minimal CEF Views window: back / forward / reload / new tab, an address
// field showing the committed origin, tab buttons, and one BrowserView per
// tab. Just enough to test the engine; not Birch's interface.
#include <algorithm>

#include "include/views/cef_box_layout.h"
#include "include/views/cef_fill_layout.h"

#include "birch.h"

namespace birch {

namespace {

enum ButtonId { kBack = 1, kForward, kReload, kNewTab, kTabBase = 1000 };

class PrivateContextHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> context) override {
    RegisterBirchScheme(context);
    ApplyPrivacyPrefs(context, "private");
  }

 private:
  IMPLEMENT_REFCOUNTING(PrivateContextHandler);
};

CefRefPtr<CefLabelButton> MakeButton(CefRefPtr<CefButtonDelegate> delegate,
                                     const std::string& text, int id) {
  CefRefPtr<CefLabelButton> b = CefLabelButton::CreateLabelButton(delegate, text);
  b->SetID(id);
  return b;
}

}  // namespace

BrowserWindow::BrowserWindow(Style style, bool is_private)
    : style_(style), private_(is_private) {
  if (private_) {
    // Empty cache_path: an off-the-record ("incognito") context. Cookies,
    // cache, storage and history live in memory only.
    CefRequestContextSettings settings;
    context_ = CefRequestContext::CreateContext(settings,
                                                new PrivateContextHandler());
  }
}

BrowserWindow* BrowserWindow::Open(Style style, bool is_private,
                                   const std::string& url) {
  CefRefPtr<BrowserWindow> w = new BrowserWindow(style, is_private);
  w->pending_url_ = url;
  state().windows.push_back(w);
  CefWindow::CreateTopLevelWindow(w);
  return w.get();
}

void BrowserWindow::OnWindowCreated(CefRefPtr<CefWindow> window) {
  window_ = window;
  window_->SetTitle(private_ ? "Birch (private) - CEF prototype"
                             : "Birch - CEF prototype");
  if (style_ == Style::kChrome) {
    window_->SetToFillLayout();
  } else {
    CefBoxLayoutSettings column;
    column.horizontal = false;
    CefRefPtr<CefBoxLayout> layout = window_->SetToBoxLayout(column);

    CefRefPtr<CefPanel> toolbar = CefPanel::CreatePanel(nullptr);
    CefBoxLayoutSettings row;
    row.horizontal = true;
    row.between_child_spacing = 4;
    CefRefPtr<CefBoxLayout> toolbar_layout = toolbar->SetToBoxLayout(row);
    back_ = MakeButton(this, "<", kBack);
    forward_ = MakeButton(this, ">", kForward);
    reload_ = MakeButton(this, "Reload", kReload);
    new_tab_ = MakeButton(this, "+", kNewTab);
    address_ = CefTextfield::CreateTextfield(this);
    address_->SetAccessibleName("Address");
    toolbar->AddChildView(back_);
    toolbar->AddChildView(forward_);
    toolbar->AddChildView(reload_);
    toolbar->AddChildView(address_);
    toolbar->AddChildView(new_tab_);
    toolbar_layout->SetFlexForView(address_, 1);

    tab_strip_ = CefPanel::CreatePanel(nullptr);
    tab_strip_->SetToBoxLayout(row);
    content_ = CefPanel::CreatePanel(nullptr);
    content_->SetToFillLayout();

    window_->AddChildView(toolbar);
    window_->AddChildView(tab_strip_);
    window_->AddChildView(content_);
    layout->SetFlexForView(content_, 1);
  }
  AddTab(pending_url_.empty() ? "birch://blank/" : pending_url_);
  window_->Show();
}

std::shared_ptr<Tab> BrowserWindow::AddTab(const std::string& url) {
  if (!window_ || (style_ == Style::kChrome && !tabs_.empty())) {
    return nullptr;  // Chrome-style windows host exactly one tab here.
  }
  auto tab = std::make_shared<Tab>();
  tab->id = state().next_tab_id++;
  tab->window = this;
  CefRefPtr<BirchClient> client = new BirchClient(tab);
  CefBrowserSettings browser_settings;
  tab->view = CefBrowserView::CreateBrowserView(client, url, browser_settings,
                                                nullptr, context_, this);
  tabs_.push_back(tab);
  if (style_ == Style::kChrome) {
    window_->AddChildView(tab->view);
  } else {
    content_->AddChildView(tab->view);
    CefRefPtr<CefLabelButton> button =
        MakeButton(this, "Tab " + std::to_string(tab->id), kTabBase + tab->id);
    tab_buttons_[tab->id] = button;
    tab_strip_->AddChildView(button);
  }
  SelectTab(tab->id);
  return tab;
}

void BrowserWindow::SelectTab(int tab_id) {
  active_id_ = tab_id;
  for (auto& t : tabs_) {
    if (t->view) {
      t->view->SetVisible(t->id == tab_id);
    }
  }
  if (content_) {
    content_->Layout();
  }
  if (window_) {
    window_->Layout();
  }
  RefreshToolbar();
}

void BrowserWindow::CloseTab(int tab_id) {
  std::shared_ptr<Tab> t = tab(tab_id);
  if (!t || !t->browser) {
    return;
  }
  t->closing_single = true;
  t->browser->GetHost()->CloseBrowser(false);
}

void BrowserWindow::Close() {
  if (window_ && !window_->IsClosed()) {
    window_->Close();
  }
}

std::shared_ptr<Tab> BrowserWindow::active() const {
  return tab(active_id_);
}

std::shared_ptr<Tab> BrowserWindow::tab(int tab_id) const {
  for (auto& t : tabs_) {
    if (t->id == tab_id) {
      return t;
    }
  }
  return nullptr;
}

size_t BrowserWindow::open_tab_count() const {
  return static_cast<size_t>(std::count_if(
      tabs_.begin(), tabs_.end(),
      [](const std::shared_ptr<Tab>& t) { return !t->closed && t->view; }));
}

std::string BrowserWindow::address_text() const {
  if (address_) {
    return address_->GetText().ToString();
  }
  std::shared_ptr<Tab> t = active();
  return t ? DisplayOrigin(t->committed_url) : std::string();
}

void BrowserWindow::RefreshToolbar() {
  std::shared_ptr<Tab> t = active();
  if (!address_ || !t) {
    return;
  }
  address_->SetText(DisplayOrigin(t->committed_url));
  back_->SetEnabled(t->browser && t->browser->CanGoBack());
  forward_->SetEnabled(t->browser && t->browser->CanGoForward());
}

void BrowserWindow::OnTabAddressChanged(Tab* t) {
  if (t->id == active_id_) {
    RefreshToolbar();
  }
}

bool BrowserWindow::OnTabDoClose(Tab* t) {
  if (!t->closing_single || window_closing_) {
    return false;  // whole window is closing: let CanClose() finish it
  }
  // Closing one tab: tear down its view; that destroys the browser.
  int id = t->id;
  PostUI([self = CefRefPtr<BrowserWindow>(this), id]() {
    std::shared_ptr<Tab> gone = self->tab(id);
    if (!gone || !self->content_) {
      return;
    }
    self->content_->RemoveChildView(gone->view);
    gone->view = nullptr;
    auto it = self->tab_buttons_.find(id);
    if (it != self->tab_buttons_.end()) {
      self->tab_strip_->RemoveChildView(it->second);
      self->tab_buttons_.erase(it);
    }
    if (self->active_id_ == id) {
      for (auto& other : self->tabs_) {
        if (other->view && !other->closed) {
          self->SelectTab(other->id);
          break;
        }
      }
    }
    self->window_->Layout();
  });
  return true;
}

void BrowserWindow::OnTabClosed(Tab*) {}

void BrowserWindow::OnWindowDestroyed(CefRefPtr<CefWindow>) {
  destroyed_ = true;
  for (auto& t : tabs_) {
    t->window = nullptr;
    t->view = nullptr;
  }
  window_ = nullptr;
  content_ = nullptr;
  tab_strip_ = nullptr;
  address_ = nullptr;
  back_ = forward_ = reload_ = new_tab_ = nullptr;
  tab_buttons_.clear();
  CefRefPtr<BrowserWindow> keep(this);
  auto& ws = state().windows;
  ws.erase(std::remove_if(ws.begin(), ws.end(),
                          [this](const CefRefPtr<BrowserWindow>& w) {
                            return w.get() == this;
                          }),
           ws.end());
  MaybeQuit();
}

bool BrowserWindow::CanClose(CefRefPtr<CefWindow>) {
  window_closing_ = true;
  bool all_ready = true;
  for (auto& t : tabs_) {
    if (t->browser && !t->closed && t->view) {
      if (!t->browser->GetHost()->TryCloseBrowser()) {
        all_ready = false;
      }
    }
  }
  return all_ready;
}

CefRect BrowserWindow::GetInitialBounds(CefRefPtr<CefWindow>) {
  int offset = static_cast<int>(state().windows.size()) * 40;
  return CefRect(40 + offset, 40 + offset, 1100, 760);
}

cef_runtime_style_t BrowserWindow::GetWindowRuntimeStyle() {
  return style_ == Style::kChrome ? CEF_RUNTIME_STYLE_CHROME
                                  : CEF_RUNTIME_STYLE_ALLOY;
}

cef_runtime_style_t BrowserWindow::GetBrowserRuntimeStyle() {
  return GetWindowRuntimeStyle();
}

CefBrowserViewDelegate::ChromeToolbarType BrowserWindow::GetChromeToolbarType(
    CefRefPtr<CefBrowserView>) {
  return style_ == Style::kChrome ? CEF_CTT_LOCATION : CEF_CTT_NONE;
}

void BrowserWindow::OnButtonPressed(CefRefPtr<CefButton> button) {
  int id = button->GetID();
  std::shared_ptr<Tab> t = active();
  if (id >= kTabBase) {
    SelectTab(id - kTabBase);
    return;
  }
  if (id == kNewTab) {
    AddTab("birch://blank/");
    return;
  }
  if (!t || !t->browser) {
    return;
  }
  if (id == kBack) {
    t->browser->GoBack();
  } else if (id == kForward) {
    t->browser->GoForward();
  } else if (id == kReload) {
    t->browser->Reload();
  }
}

bool BrowserWindow::OnKeyEvent(CefRefPtr<CefTextfield> textfield,
                               const CefKeyEvent& event) {
  const int kReturn = 0x0D;
  if (event.type != KEYEVENT_RAWKEYDOWN || event.windows_key_code != kReturn) {
    return false;
  }
  std::shared_ptr<Tab> t = active();
  std::string text = textfield->GetText().ToString();
  if (!t || !t->browser || text.empty()) {
    return true;
  }
  if (text.find("://") == std::string::npos) {
    text = "https://" + text;
  }
  t->browser->GetMainFrame()->LoadURL(text);
  return true;
}

}  // namespace birch
