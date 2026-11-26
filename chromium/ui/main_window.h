// A Birch window (CEF Views, Alloy style): the HTML sidebar (UI host page
// "sidebar": nav buttons, address box, the current space's tabs) beside the
// page card, inset in the space's colour. It keeps the live pages of
// its tabs by item id, creates them when a tab is first selected, and turns
// page reports into store updates. Normal windows share the profile's Store;
// a private window has its own Store and private engine Profile, never saved.
//
// Owner: shared (wave 2). Collision hotspot like the Mac's App.swift: keep
// additions small and local; new panels go in their own ui/<area>/ folder.
#ifndef BIRCH_UI_MAIN_WINDOW_H_
#define BIRCH_UI_MAIN_WINDOW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "include/views/cef_panel.h"
#include "include/views/cef_overlay_controller.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

#include "core/settings.h"
#include "core/lifecycle.h"
#include <set>
#include "core/store.h"
#include "engine/engine.h"
#include "ui/sidebar/sidebar_host.h"
#include "ui/rounded_card.h"
#include "ui/window_actions.h"

namespace birch::ui {

class MainWindow;

// Implemented by app/: what a window needs from the application.
class WindowHost {
 public:
  virtual ~WindowHost() = default;
  // The window's store changed (debounced save for normal windows).
  virtual void StoreChanged(MainWindow* window) = 0;
  virtual void OpenPrivateWindow() = 0;
  virtual void SetAutomaticUpdateChecks(bool enabled) = 0;
  virtual void CheckForUpdates() = 0;
  virtual void InstallUpdate() = 0;
  virtual bool UpdateInstalling() const = 0;
  virtual std::string UpdateStatus() const = 0;
  virtual void OpenNormalWindow() = 0;
  virtual void UpdateSidebarSettings(double edge,double overshoot,double delay,double speed) = 0;
  virtual std::set<std::string> ProtectedTabs(bool archive = true) const = 0;
  virtual bool FocusExistingTab(MainWindow* source, const std::string& id) = 0;
  virtual void EvictTab(const std::string& id) = 0;
  virtual bool HasLiveTab(const std::string& id) const = 0;
  // The window starts closing (its session is still readable).
  virtual void WindowClosing(MainWindow* window) = 0;
  // The window is gone; the host releases it.
  virtual void WindowDestroyed(MainWindow* window) = 0;
};

struct WindowContext {
  core::Store* store = nullptr;
  core::WindowSession session;
  std::shared_ptr<engine::Profile> profile;
  const core::Settings* settings = nullptr;
  bool is_private = false;
  WindowHost* host = nullptr;
};

class MainWindow : public CefWindowDelegate, public WindowActions {
 public:
  explicit MainWindow(WindowContext context);
  ~MainWindow() override;

  // Creates and shows the native window. Test runs show it minimized (so it
  // never takes focus) unless BIRCH_SHOW=1.
  void Open();
  void Close();
  void Activate();

  bool is_private() const { return ctx_.is_private; }
  bool destroyed() const { return destroyed_; }
  const core::WindowSession& session() const { return ctx_.session; }
  core::Store& store() { return *ctx_.store; }
  std::optional<std::string> selected_id() const;

  // Runs a command by its Mac command id (spec/keybindings.md): tab.new,
  // tab.close, tab.editURL, tab.reload, nav.back, nav.forward, private.new,
  // window.close. Shortcuts call this; agent 6's registry replaces the list.
  bool RunCommand(const std::string& id);

  // A new tab with |url| at the top of the current space. Returns its id.
  std::string NewTab(const std::string& url, bool foreground);
  // The live page of a tab (nullptr when not loaded).
  engine::Page* PageFor(const std::string& item_id) const;
  size_t LivePageCount() const { return pages_.size(); }

  CefRefPtr<CefWindow> cef_window() const { return window_; }
  bool new_tab_mode() const { return sidebar_ && sidebar_->new_tab_mode(); }
  // "Private", or the current space's icon and name.
  std::string space_title() const;
  // The HTML sidebar's page (tests drive and read it through DevTools).
  engine::UiPage* sidebar_page() const {
    return sidebar_ ? sidebar_->page() : nullptr;
  }

  // For tests: what the app last gave the sidebar (the address box text and
  // the tab rows' titles); channel/shell tests compare the page's DOM to it.
  std::string address_text() const { return sidebar_->address_text(); }
  bool not_secure_shown() const { return sidebar_->not_secure_shown(); }
  // For tests: "sidebar=<w> content=<w>" from the laid-out views.
  std::string LayoutForTest() const;
  std::vector<std::string> sidebar_titles() const {
    return sidebar_->RowTitles();
  }

  // WindowActions
  void SelectTab(const std::string& item_id) override;
  void RefreshUpdate();
  void SetAutomaticUpdateChecks(bool enabled) override {if(!ctx_.is_private) ctx_.host->SetAutomaticUpdateChecks(enabled);}
  void CheckForUpdates() override {if(!ctx_.is_private) ctx_.host->CheckForUpdates();}
  void InstallUpdate() override {if(!ctx_.is_private) ctx_.host->InstallUpdate();}
  void SidebarClosed() override;
  void SidebarAction(const core::ui_channel::Message& message) override;
  void SelectSpace(const std::string& id);
  void SynchronizeSidebar();
  void SleepTabs(core::SleepTrigger trigger);
  void MaintainTabs(bool manual_archive = false, bool manual_sleep = false, bool include_sleep = true);
  std::set<std::string> VisibleTabs() const;
  void SleepPage(const std::string& id);
  void CloseTab(const std::string& item_id) override;
  void StartNewTab() override;
  void GoBack() override;
  void GoForward() override;
  void Reload() override;
  void SubmitAddress(const std::string& text, bool in_new_tab) override;
  void CancelAddress() override;
  std::string AddressForEditing() const override;

  // CefWindowDelegate
  void OnWindowCreated(CefRefPtr<CefWindow> window) override;
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override;
  bool CanClose(CefRefPtr<CefWindow> window) override;
  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override;
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override;
  cef_runtime_style_t GetWindowRuntimeStyle() override;
  bool OnAccelerator(CefRefPtr<CefWindow> window, int command_id) override;
  void OnThemeChanged(CefRefPtr<CefView> view) override;
  CefSize GetPreferredSize(CefRefPtr<CefView> view) override;
  void OnLayoutChanged(CefRefPtr<CefView> view, const CefRect& bounds) override;

 private:
  class TabObserver;
  struct Live {
    std::unique_ptr<TabObserver> observer;
    std::unique_ptr<engine::Page> page;
  };

  // Page reports (through TabObserver).
  void PageAddress(const std::string& id, const std::string& url,
                   bool is_error_page);
  void PageTitle(const std::string& id, const std::string& title);
  void PageLoading(const std::string& id);
  void PageClosed(TabObserver* observer);

  void ShowPage(const std::string& item_id);
  void Refresh();
  void PushSidebar();
  void ApplySurroundColor();
  void LayoutSidebar();
  void WatchSidebar();
  std::string ThemeSurround() const;
  void ScheduleMaintenance(int64_t delay_ms);
  void UpdateTitle();
  void ScheduleSidebarRebuild();
  std::optional<std::string> UrlOf(const std::string& item_id) const;
  void SetIcon();

  WindowContext ctx_;
  CefRefPtr<CefWindow> window_;
  std::unique_ptr<SidebarHost> sidebar_;
  CefRefPtr<CefPanel> sidebar_spacer_;
  CefRefPtr<CefOverlayController> sidebar_overlay_;
  CefRefPtr<CefPanel> frame_;    // the coloured surround of the page card
  CefRefPtr<CefPanel> content_;  // the page card
  std::unique_ptr<RoundedCard> rounded_card_;
  std::string surround_;
  std::string sidebar_mode_ = "pinned";
  bool sidebar_watch_ = false, sidebar_hold_ = false;
  int64_t sidebar_outside_since_ = 0;
  std::map<std::string, Live> pages_;
  std::vector<Live> closing_;
  bool rebuild_pending_ = false;
  bool closing_window_ = false;
  bool destroyed_ = false;
  IMPLEMENT_REFCOUNTING(MainWindow);
};

}  // namespace birch::ui

#endif  // BIRCH_UI_MAIN_WINDOW_H_
