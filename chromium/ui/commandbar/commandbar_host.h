// The HTML command bar and Control+Tab switcher (chromium/ui/web/commandbar/)
// on the UI host. One UI page serves both: Ctrl+T (a centred bar), Ctrl+L
// (the same bar anchored near the sidebar's address pill) and the switcher.
// The window gives it what it may show (SuggestInput, tabs); the page's
// messages (already checked by engine/ and core::ui_channel) come back here
// and become CommandBarActions. The page never sees addresses or tab ids of
// result rows (opaque keys); the host acts only on keys and tab ids it sent.
//
// Owner: wave-3 agent 6 (cx-commandbar), with ui/web/commandbar/.
#ifndef BIRCH_UI_COMMANDBAR_COMMANDBAR_HOST_H_
#define BIRCH_UI_COMMANDBAR_COMMANDBAR_HOST_H_

#include <memory>
#include <string>
#include <vector>

#include "core/suggest.h"
#include "core/ui_channel.h"
#include "engine/ui_page.h"

namespace birch::ui {

class CommandBarActions {
 public:
  virtual ~CommandBarActions() = default;
  // What the bar may list for |text| right now.
  virtual core::SuggestInput BarSuggestInput(const std::string& text) = 0;
  // The bar chose an address (already resolved), a tab or a command.
  virtual void BarGo(const std::string& url) = 0;
  virtual void BarSelectTab(const std::string& id) = 0;
  virtual void BarRunCommand(const std::string& id) = 0;
  // Return with no row chosen: the window resolves the typed text.
  virtual void BarSubmit(const std::string& text) = 0;
  virtual void BarCancelled() = 0;
  // The rows changed: the window resizes the overlay.
  virtual void BarRowsChanged(size_t rows) = 0;
  virtual void SwitcherReleased() = 0;
  virtual void SwitcherPicked(const std::string& id) = 0;
  virtual void SwitcherCancelled() = 0;
  virtual void BarClosedForWindow() {}
};

class CommandBarHost : public engine::UiPageObserver {
 public:
  enum class Mode { kHidden, kNew, kEdit, kSwitcher };

  CommandBarHost(CommandBarActions* actions, bool is_private);
  ~CommandBarHost() override;

  CefRefPtr<CefView> view() const { return page_->view(); }
  engine::UiPage* page() const { return page_.get(); }
  Mode mode() const { return mode_; }
  size_t row_count() const { return results_.size(); }
  const std::vector<core::SuggestResult>& results() const { return results_; }

  void ShowBar(bool edit, const std::string& text,
               const std::vector<std::string>& colors,
               const std::string& background);
  void ShowSwitcher(const std::vector<core::ui_channel::SwitcherTab>& tabs,
                    const std::string& selected_id, const std::string& modifier,
                    const std::vector<std::string>& colors,
                    const std::string& background);
  void Hide();

  // engine::UiPageObserver
  void OnUiMessage(const core::ui_channel::Message& message) override;
  void OnUiCrashed() override;
  void OnUiClosed() override { actions_->BarClosedForWindow(); }

 private:
  void Send(const std::string& name, const std::string& json);
  void FlushPending();

  CommandBarActions* actions_;
  bool is_private_;
  std::unique_ptr<engine::UiPage> page_;
  Mode mode_ = Mode::kHidden;
  std::vector<core::SuggestResult> results_;
  std::vector<std::string> switcher_ids_;
  std::vector<std::pair<std::string, std::string>> pending_;  // until ui.ready
};

}  // namespace birch::ui

#endif  // BIRCH_UI_COMMANDBAR_COMMANDBAR_HOST_H_
