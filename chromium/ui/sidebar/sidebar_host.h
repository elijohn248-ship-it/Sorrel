// The HTML sidebar (chromium/ui/web/sidebar/) on the UI host: space title,
// back/forward/reload, the address box (real origin, "Not secure"), the
// current space's tabs and "+ New Tab". MainWindow pushes a SidebarState;
// the page's messages (core::ui_channel, already checked by engine/) come
// back here and become WindowActions. Tab ids in messages are acted on only
// when they are rows this sidebar was given.
//
// Owner: wave-3 agent 5 (cx-spaces-sidebar), with ui/web/sidebar/.
#ifndef BIRCH_UI_SIDEBAR_SIDEBAR_HOST_H_
#define BIRCH_UI_SIDEBAR_SIDEBAR_HOST_H_

#include <memory>
#include <string>
#include <vector>

#include "core/ui_channel.h"
#include "engine/ui_page.h"
#include "ui/window_actions.h"

namespace birch::ui {

class SidebarHost : public engine::UiPageObserver {
 public:
  SidebarHost(WindowActions* actions, int width, bool is_private);
  ~SidebarHost() override;

  CefRefPtr<CefView> view() const { return page_->view(); }
  engine::UiPage* page() const { return page_.get(); }

  // What the sidebar shows; sent now if the page is ready, else on ui.ready.
  void Update(core::ui_channel::SidebarState state);
  // Ctrl+T / "+ New Tab": an empty address field takes the typing.
  void BeginNewTab();
  void UpdateStatus(const std::string& json);
  // Ctrl+L: the address field with the full address, selected.
  void FocusAddress();
  void EndAddressEditing();
  bool new_tab_mode() const { return new_tab_mode_; }

  // What the app last gave the sidebar (tests compare the page's DOM to it).
  std::string address_text() const;
  bool not_secure_shown() const { return state_.address.not_secure_lock; }
  std::vector<std::string> RowTitles() const;

  // engine::UiPageObserver
  void OnUiMessage(const core::ui_channel::Message& message) override;
  void OnUiCrashed() override;
  void OnUiClosed() override { actions_->SidebarClosed(); }

 private:
  bool IsShownTab(const std::string& id) const;
  void SendFocus();

  WindowActions* actions_;
  std::unique_ptr<engine::UiPage> page_;
  core::ui_channel::SidebarState state_;
  std::string update_status_ = "{\"supported\":false}";
  bool new_tab_mode_ = false;
  bool focus_pending_ = false;
};

}  // namespace birch::ui

#endif  // BIRCH_UI_SIDEBAR_SIDEBAR_HOST_H_
