#include "ui/main_window.h"

#include <algorithm>

#include "include/cef_image.h"
#include "include/cef_color_ids.h"
#include "core/theme.h"
#include "ui/sidebar/pointer.h"
#include "include/cef_task.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_fill_layout.h"

#include "core/codec.h"
#include "core/json.h"
#include "core/typed_url.h"
#include "core/ui_channel.h"
#include "platform/platform.h"

namespace birch::ui {

namespace {

class FnTask : public CefTask {
 public:
  explicit FnTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(FnTask);
};

void PostUi(std::function<void()> fn) {
  CefPostTask(TID_UI, new FnTask(std::move(fn)));
}

// "#RRGGBB" (from core::ui_channel::SurroundColor) -> an opaque CEF colour.
cef_color_t ColorFromHex(const std::string& hex) {
  unsigned v = 0;
  for (size_t i = 1; i < hex.size() && i < 7; ++i) {
    char c = hex[i];
    v = v * 16 + static_cast<unsigned>((c >= '0' && c <= '9')   ? c - '0'
                                       : (c >= 'A' && c <= 'F') ? c - 'A' + 10
                                       : (c >= 'a' && c <= 'f') ? c - 'a' + 10
                                                                : 0);
  }
  return CefColorSetARGB(255, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}

// The page card's inset from the window edge (Arc's look).
constexpr int kCardInset = 8;

}  // namespace

class MainWindow::TabObserver : public engine::PageObserver {
 public:
  TabObserver(MainWindow* window, std::string id)
      : window_(window), id_(std::move(id)) {}
  const std::string& id() const { return id_; }

  void OnPageAddress(const std::string& url, bool is_error_page) override {
    window_->PageAddress(id_, url, is_error_page);
  }
  void OnPageTitle(const std::string& title) override {
    window_->PageTitle(id_, title);
  }
  void OnPageLoading(bool, bool, bool) override { window_->PageLoading(id_); }
  void OnPageCrashed() override { window_->PageLoading(id_); }
  void OnPageClosed() override { window_->PageClosed(this); }
  void OnPageWantsNewTab(const std::string& url, bool foreground) override {
    window_->NewTab(url, foreground);
  }

 private:
  MainWindow* window_;
  std::string id_;
};

MainWindow::MainWindow(WindowContext context) : ctx_(std::move(context)) {}

MainWindow::~MainWindow() = default;

void MainWindow::Open() {
  CefWindow::CreateTopLevelWindow(this);
}

void MainWindow::Close() {
  if (window_ && !window_->IsClosed()) {
    window_->Close();
  }
}

void MainWindow::Activate() {
  if (window_) {
    if (window_->IsMinimized()) {
      window_->Restore();
    }
    window_->Activate();
  }
}

std::optional<std::string> MainWindow::selected_id() const {
  return ctx_.session.SelectedIn(ctx_.store->CurrentSpace(ctx_.session).id);
}

void MainWindow::OnWindowCreated(CefRefPtr<CefWindow> window) {
  window_ = window;
  window_->SetTitle(ctx_.is_private ? "Birch Private" : "Birch");
  SetIcon();
  CefBoxLayoutSettings row;
  row.horizontal = true;
  CefRefPtr<CefBoxLayout> layout = window_->SetToBoxLayout(row);

  int width = static_cast<int>(ctx_.store->state().sidebar_width);
  sidebar_mode_ = ctx_.store->state().sidebar_collapsed ? "hidden" : "pinned";
  sidebar_ = std::make_unique<SidebarHost>(this, std::clamp(width, 180, 480),
                                           ctx_.is_private);
  // The page card sits inset in a panel of the space's colour, so it reads
  // as a card on the same surface as the sidebar's gradient.
  frame_ = CefPanel::CreatePanel(this);
  CefBoxLayoutSettings inset;
  inset.horizontal = true;
  inset.inside_border_insets = {kCardInset, 0, kCardInset, kCardInset};
  CefRefPtr<CefBoxLayout> frame_layout = frame_->SetToBoxLayout(inset);
  rounded_card_ = std::make_unique<RoundedCard>();
  content_ = rounded_card_->view();
  frame_->AddChildView(content_);
  frame_layout->SetFlexForView(content_, 1);
  sidebar_spacer_ = CefPanel::CreatePanel(this);
  window_->AddChildView(sidebar_spacer_);
  window_->AddChildView(frame_);
  layout->SetFlexForView(frame_, 1);
  sidebar_overlay_ = window_->AddOverlayView(sidebar_->view(), CEF_DOCKING_MODE_CUSTOM, true);
  sidebar_overlay_->SetVisible(true);
  bar_ = std::make_unique<CommandBarHost>(this, ctx_.is_private);
  bar_overlay_ = window_->AddOverlayView(bar_->view(), CEF_DOCKING_MODE_CUSTOM, true);
  bar_overlay_->SetVisible(false);
  LayoutSidebar();
  rounded_card_->Attach(window_);
  ApplySurroundColor();

  RegisterShortcuts();
  if (std::optional<std::string> sel = selected_id()) {
    SelectTab(*sel);
  } else if (ctx_.is_private) {
    PostUi([self = CefRefPtr<MainWindow>(this)] {
      if(!self->selected_id() && !self->destroyed_) self->StartNewTab();
    });
  }
  Refresh();
  RefreshUpdate();
  ScheduleMaintenance(20000);
  WatchSidebar();
  window_->Show();
}

void MainWindow::SetIcon() {
  std::string png;
  if (!core::ReadFileUtf8Path(
          core::JoinPath(platform::ExecutableDir(), "birch.png"), &png) ||
      png.empty()) {
    return;
  }
  CefRefPtr<CefImage> image = CefImage::CreateImage();
  if (image->AddPNG(1.0f, png.data(), png.size())) {
    window_->SetWindowIcon(image);
    window_->SetWindowAppIcon(image);
  }
}

CefRect MainWindow::GetInitialBounds(CefRefPtr<CefWindow>) {
  return CefRect(80, 60, 1280, 840);
}

cef_show_state_t MainWindow::GetInitialShowState(CefRefPtr<CefWindow>) {
  if (platform::IsTestRun() && !platform::EnvOn("BIRCH_SHOW")) {
    return CEF_SHOW_STATE_MINIMIZED;  // never take focus on someone's desktop
  }
  return CEF_SHOW_STATE_NORMAL;
}

cef_runtime_style_t MainWindow::GetWindowRuntimeStyle() {
  return CEF_RUNTIME_STYLE_ALLOY;
}

void MainWindow::OnThemeChanged(CefRefPtr<CefView> view) {
  // CEF clears custom backgrounds when attaching views and changing themes.
  // This delegate serves both the window and the page's surround panel.
  if (!surround_.empty()) view->SetBackgroundColor(ColorFromHex(surround_));
  if(window_ && view->IsSame(window_) && sidebar_) ScheduleSidebarRebuild();
}

bool MainWindow::OnAccelerator(CefRefPtr<CefWindow>, int command_id) {
  const int index = command_id - kAcceleratorBase;
  if (index < 0 || static_cast<size_t>(index) >= accel_strokes_.size()) {
    return false;
  }
  return HandleStroke(accel_strokes_[static_cast<size_t>(index)]);
}

bool MainWindow::RunCommand(const std::string& id, bool physical) {
  platform::Log("command: " + id);
  last_command_ = id;
  if (id != "tab.new" && id != "tab.editURL" && id != "tab.cycleNext" &&
      id != "tab.cyclePrevious") {
    CloseCommandBar(false);  // any other command puts the bar away
  }
  if (id == "window.new") {
    if(!ctx_.is_private) ctx_.host->OpenNormalWindow();
  } else if (id == "space.next" || id == "space.previous") {
    const auto& spaces=ctx_.store->state().spaces;
    for(size_t i=0;i<spaces.size();++i) if(spaces[i].id==ctx_.session.current_space_id) {
      auto next=id=="space.next"?(i+1)%spaces.size():(i+spaces.size()-1)%spaces.size();
      SelectSpace(spaces[next].id);break;
    }
  } else if (id.size()==7 && id.rfind("space.",0)==0 && id[6]>='1' && id[6]<='9') {
    size_t index=static_cast<size_t>(id[6]-'1');
    if(index<ctx_.store->state().spaces.size()) SelectSpace(ctx_.store->state().spaces[index].id);
  } else if (id.size()==12 && id.rfind("tab.select.",0)==0 && id[11]>='1' && id[11]<='9') {
    SelectNumbered(static_cast<size_t>(id[11]-'0'));
  } else if (id == "sidebar.toggle") {
    core::ui_channel::Message message;message.action="sidebar.mode";
    message.text=sidebar_mode_=="pinned"?"hidden":"pinned";SidebarAction(message);
  } else if (id == "archive.now" || id == "tabs.sleepNow") {
    MaintainTabs(id=="archive.now",id=="tabs.sleepNow");
  } else if (id == "tab.new") {
    StartNewTab();
  } else if (id == "tab.cycleNext" || id == "tab.cyclePrevious") {
    CycleTabs(id == "tab.cycleNext", physical);
  } else if (id == "tab.next" || id == "tab.previous") {
    StepTab(id == "tab.next");
  } else if (id == "config.reload") {
    ReloadConfig();
  } else if (id == "tab.close") {
    if (std::optional<std::string> sel = selected_id()) {
      CloseTab(*sel);
    }
  } else if (id == "tab.editURL") {
    OpenCommandBar(true);
  } else if (id == "tab.reload") {
    Reload();
  } else if (id == "nav.back") {
    GoBack();
  } else if (id == "nav.forward") {
    GoForward();
  } else if (id == "private.new") {
    ctx_.host->OpenPrivateWindow();
  } else if (id == "window.close") {
    Close();
  } else {
    return false;
  }
  return true;
}

bool MainWindow::CanClose(CefRefPtr<CefWindow>) {
  if(!ctx_.is_private && ctx_.host->UpdateInstalling()) return false;
  if (!closing_window_) {
    closing_window_ = true;
    // An overlay hosting a browser view must be gone before the window
    // closes, or its browser never finishes closing.
    if (sidebar_overlay_) {
      sidebar_overlay_->Destroy();
      sidebar_overlay_ = nullptr;
    }
    sidebar_->page()->CloseDetached();
    if (bar_overlay_) {
      bar_overlay_->Destroy();
      bar_overlay_ = nullptr;
    }
    if (bar_) bar_->page()->CloseDetached();
    ctx_.host->WindowClosing(this);
  }
  bool ready = true;
  for (auto& kv : pages_) {
    bool r = kv.second.page->TryCloseForWindow();
    ready = r && ready;
  }
  for (Live& live : closing_) {
    bool r = live.page->TryCloseForWindow();
    ready = r && ready;
  }
  if (sidebar_) {
    bool r = sidebar_->page()->closed();
    ready = r && ready;
  }
  if (bar_) {
    bool r = bar_->page()->closed();
    ready = r && ready;
  }
  return ready;
}

void MainWindow::OnWindowDestroyed(CefRefPtr<CefWindow>) {
  destroyed_ = true;
  sidebar_overlay_ = nullptr; sidebar_spacer_ = nullptr; bar_overlay_ = nullptr;
  rounded_card_.reset();
  pages_.clear();
  closing_.clear();
  window_ = nullptr;
  content_ = nullptr;
  frame_ = nullptr;
  CefRefPtr<MainWindow> self(this);
  PostUi([self] { self->ctx_.host->WindowDestroyed(self.get()); });
}

// ---- tabs ----------------------------------------------------------------------

std::optional<std::string> MainWindow::UrlOf(const std::string& item_id) const {
  auto live = pages_.find(item_id);
  if (live != pages_.end() && !live->second.page->committed_url().empty()) {
    return live->second.page->committed_url();
  }
  const core::Item* item = ctx_.store->FindItem(item_id);
  return item ? item->url : std::nullopt;
}

std::string MainWindow::NewTab(const std::string& url, bool foreground) {
  if (destroyed_) {
    return std::string();
  }
  std::string space = ctx_.store->CurrentSpace(ctx_.session).id;
  std::string id = ctx_.store->AddTab(space, url, "");
  ctx_.host->StoreChanged(this);
  if (foreground) {
    SelectTab(id);
  } else {
    ScheduleSidebarRebuild();
  }
  return id;
}

void MainWindow::SelectTab(const std::string& item_id) {
  if (destroyed_ || !ctx_.store->FindItem(item_id)) {
    return;
  }
  if (ctx_.host->FocusExistingTab(this,item_id)) return;
  OnTabSelected(selected_id(), item_id);
  sidebar_->EndAddressEditing();
  if (const core::Space* sp = ctx_.store->SpaceOf(item_id)) {
    ctx_.session.current_space_id = sp->id;
  }
  ctx_.session.SetSelected(ctx_.store->CurrentSpace(ctx_.session).id, item_id);
  ctx_.store->Touch(item_id, core::NowSeconds());
  ctx_.host->StoreChanged(this);
  ShowPage(item_id);
  Refresh();
}

void MainWindow::ShowPage(const std::string& item_id) {
  if (!content_) {
    return;
  }
  if (!pages_.count(item_id)) {
    const core::Item* item = ctx_.store->FindItem(item_id);
    std::string url = item && item->url ? core::bundled_page::Current(*item->url)
                                        : std::string("about:blank");
    Live live;
    live.observer = std::make_unique<TabObserver>(this, item_id);
    auto profile = ctx_.profile;
    if (!ctx_.is_private) {
      const core::Space* owner = ctx_.store->SpaceOf(item_id);
      // Favorites deliberately use the shared normal login store.
      profile = owner && owner->profile_id ? engine::Profile::ForSpace(*owner->profile_id)
                                          : engine::Profile::Normal();
    }
    live.page = engine::Page::Create(profile, url, live.observer.get());
    content_->AddChildView(live.page->view());
    pages_[item_id] = std::move(live);
  }
  for (auto& kv : pages_) {
    if (CefRefPtr<CefView> v = kv.second.page->view()) {
      v->SetVisible(kv.first == item_id);
    }
  }
  content_->Layout();
  // The switcher receives modifier key-up. Keep focus there while the
  // selection changes underneath it during a held cycle.
  if (!cycling_select_ || recency_.switcher().size() < 2) {
    pages_[item_id].page->Focus();
  }
}

void MainWindow::CloseTab(const std::string& item_id) {
  if (destroyed_) {
    return;
  }
  recency_.Forget(item_id);
  std::string space = ctx_.store->CurrentSpace(ctx_.session).id;
  bool was_selected = selected_id() == item_id;
  std::optional<std::string> next =
      ctx_.store->NeighbourAfterClose(space, item_id);
  core::Store::CloseResult result = ctx_.store->CloseTab(item_id);
  auto live = pages_.find(item_id);
  if (live != pages_.end()) {
    // The page leaves the window; pinned tabs stay in the sidebar, asleep.
    if (CefRefPtr<CefView> v = live->second.page->view()) {
      v->SetVisible(false);
    }
    live->second.page->Close();
    closing_.push_back(std::move(live->second));
    pages_.erase(live);
  }
  if (result == core::Store::CloseResult::kRemoved && was_selected) {
    ctx_.session.SetSelected(space, std::nullopt);
    if (next) {
      SelectTab(*next);
    }
  }
  ctx_.host->StoreChanged(this);
  Refresh();
}

engine::Page* MainWindow::PageFor(const std::string& item_id) const {
  auto it = pages_.find(item_id);
  return it == pages_.end() ? nullptr : it->second.page.get();
}

// ---- page reports -------------------------------------------------------------------

void MainWindow::PageAddress(const std::string& id, const std::string& url,
                             bool is_error_page) {
  if (!is_error_page) {
    // Birch's error page never replaces the tab's saved address.
    ctx_.store->UpdatePage(id, url, std::nullopt);
    ctx_.host->StoreChanged(this);
  }
  if (selected_id() == id) {
    Refresh();
  }
}

void MainWindow::PageTitle(const std::string& id, const std::string& title) {
  ctx_.store->UpdatePage(id, std::nullopt, title);
  ctx_.host->StoreChanged(this);
  ScheduleSidebarRebuild();
  if (selected_id() == id) {
    UpdateTitle();
  }
}

void MainWindow::UpdateTitle() {
  if (!window_) {
    return;
  }
  std::optional<std::string> sel = selected_id();
  const core::Item* item = sel ? ctx_.store->FindItem(*sel) : nullptr;
  std::string title = item ? item->DisplayTitle() : std::string();
  window_->SetTitle((title.empty() ? std::string() : title + " - ") +
                    (ctx_.is_private ? "Birch Private" : "Birch"));
}

void MainWindow::PageLoading(const std::string& id) {
  if (auto* page = PageFor(id); page && !page->IsLoading()) ctx_.store->Touch(id,core::NowSeconds());
  if (selected_id() == id) {
    Refresh();
  }
}

void MainWindow::PageClosed(TabObserver* observer) {
  CefRefPtr<MainWindow> self(this);
  PostUi([self, observer] {
    auto& c = self->closing_;
    c.erase(std::remove_if(c.begin(), c.end(),
                           [observer](const Live& l) {
                             return l.observer.get() == observer;
                           }),
            c.end());
    // A page that closed by itself (not through CloseTab).
    for (auto it = self->pages_.begin(); it != self->pages_.end(); ++it) {
      if (it->second.observer.get() == observer) {
        self->pages_.erase(it);
        self->Refresh();
        break;
      }
    }
  });
}

// ---- the sidebar ----------------------------------------------------------------------

void MainWindow::Refresh() {
  if (!sidebar_ || destroyed_) {
    return;
  }
  PushSidebar();
  UpdateTitle();
}

void MainWindow::PushSidebar() {
  if (!sidebar_ || destroyed_) {
    return;
  }
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  std::optional<std::string> sel = selected_id();
  engine::Page* page = sel ? PageFor(*sel) : nullptr;
  std::optional<std::string> url = sel ? UrlOf(*sel) : std::nullopt;
  core::ui_channel::SidebarState st;
  st.space_title = space_title();
  st.spaces = ctx_.store->state().spaces; st.current_space = space.id;
  st.theme = space.theme; st.sidebar_mode = sidebar_mode_;
  st.native_hover = SidebarCursor().has_value();
  st.reveal_width = ctx_.settings->sidebarHoverEdgeWidth;
  st.overshoot = ctx_.settings->sidebarOvershootReach;
  st.hide_delay = ctx_.settings->sidebarHideDelay;
  st.slide_speed = ctx_.settings->sidebarAnimationDuration;
  st.is_private = ctx_.is_private;
  st.colors = space.theme.colors;
  st.background = ThemeSurround();
  st.rows = ctx_.store->SidebarRows(space.id);
  st.selected_id = sel.value_or(std::string());
  st.address = core::AddressBoxFor(url);
  st.full_url = url.value_or(std::string());
  st.can_go_back = page && page->CanGoBack();
  st.can_go_forward = page && page->CanGoForward();
  st.can_reload = url.has_value();
  st.loading = page && page->IsLoading();
  sidebar_->Update(std::move(st));
  ApplySurroundColor();
}

void MainWindow::ApplySurroundColor() {
  if (!frame_ || !window_) {
    return;
  }
  std::string color = ThemeSurround();
  if (color == surround_) {
    return;
  }
  surround_ = color;
  frame_->SetBackgroundColor(ColorFromHex(color));
  window_->SetBackgroundColor(ColorFromHex(color));
  if (rounded_card_) rounded_card_->SetColor(ColorFromHex(color));
}

void MainWindow::ScheduleSidebarRebuild() {
  if (rebuild_pending_) {
    return;
  }
  rebuild_pending_ = true;
  // Coalesces bursts of page reports (titles, loading) into one push.
  PostUi([self = CefRefPtr<MainWindow>(this)] {
    self->rebuild_pending_ = false;
    self->PushSidebar();
  });
}

std::string MainWindow::LayoutForTest() const {
  if (!sidebar_ || !content_ || !window_) {
    return "none";
  }
  window_->Layout();
  std::optional<std::string> sel = selected_id();
  engine::Page* page = sel ? PageFor(*sel) : nullptr;
  int page_width = page && page->view() ? page->view()->GetBounds().width : 0;
  return "sidebar=" + std::to_string(sidebar_->view()->GetBounds().width) +
         " content=" + std::to_string(content_->GetBounds().width) +
         " page=" + std::to_string(page_width) +
         " window=" + std::to_string(window_->GetBounds().width);
}

std::string MainWindow::space_title() const {
  if (ctx_.is_private) {
    return "Private";
  }
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  return space.icon + "  " + space.name;
}

// ---- WindowActions ---------------------------------------------------------------------

void MainWindow::StartNewTab() {
  OpenCommandBar(false);
}

void MainWindow::GoBack() {
  if (std::optional<std::string> sel = selected_id()) {
    if (engine::Page* p = PageFor(*sel)) {
      p->Back();
    }
  }
}

void MainWindow::GoForward() {
  if (std::optional<std::string> sel = selected_id()) {
    if (engine::Page* p = PageFor(*sel)) {
      p->Forward();
    }
  }
}

void MainWindow::Reload() {
  if (std::optional<std::string> sel = selected_id()) {
    if (engine::Page* p = PageFor(*sel)) {
      p->Reload();
    } else {
      ShowPage(*sel);
    }
  }
}

void MainWindow::SubmitAddress(const std::string& text, bool in_new_tab) {
  LoadAddress(core::Destination(text, ctx_.settings->searchEngineURL, &BangsTable()),
              in_new_tab);
}

void MainWindow::LoadAddress(const std::string& url, bool in_new_tab) {
  std::optional<std::string> sel = selected_id();
  if (in_new_tab || !sel) {
    NewTab(url, true);
    return;
  }
  ShowPage(*sel);
  if (engine::Page* p = PageFor(*sel)) {
    p->Load(url);
    p->Focus();
  }
}

void MainWindow::CancelAddress() {
  if (std::optional<std::string> sel = selected_id()) {
    if (engine::Page* p = PageFor(*sel)) {
      p->Focus();
    }
  }
}

std::string MainWindow::AddressForEditing() const {
  std::optional<std::string> sel = selected_id();
  std::optional<std::string> url = sel ? UrlOf(*sel) : std::nullopt;
  return url ? *url : std::string();
}

}  // namespace birch::ui

namespace birch::ui {
void MainWindow::SleepPage(const std::string& id) {
  auto it=pages_.find(id);
  if(it==pages_.end()) return;
  if(auto view=it->second.page->view()) view->SetVisible(false);
  it->second.page->Close();
  closing_.push_back(std::move(it->second));pages_.erase(it);
}
}

namespace birch::ui {
void MainWindow::SidebarClosed() {
  if (closing_window_ && window_ && !destroyed_) window_->Close();
}
}

namespace birch::ui {
std::string MainWindow::ThemeSurround() const {
  if(ctx_.is_private) return "#26232E";
  auto color=window_?window_->GetThemeColor(CEF_ColorPrimaryBackground):CefColorSetARGB(255,255,255,255);
  bool dark=(CefColorGetR(color)+CefColorGetG(color)+CefColorGetB(color))<384;
  return core::Hex(core::GradientStops(ctx_.store->CurrentSpace(ctx_.session).theme,dark).back());
}
}

namespace birch::ui {
void MainWindow::RefreshUpdate() {
  if(sidebar_ && !destroyed_) sidebar_->UpdateStatus(ctx_.is_private ? "{\"supported\":false}" : ctx_.host->UpdateStatus());
}
}
