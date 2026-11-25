// What sidebar, toolbar and (later) command bar views ask their window to do.
// Views never touch pages or the store directly; MainWindow implements this.
#ifndef BIRCH_UI_WINDOW_ACTIONS_H_
#define BIRCH_UI_WINDOW_ACTIONS_H_

#include <string>

namespace birch::ui {

class WindowActions {
 public:
  virtual ~WindowActions() = default;
  virtual void SelectTab(const std::string& item_id) = 0;
  virtual void CloseTab(const std::string& item_id) = 0;
  // Ctrl+T / "+ New Tab": the address field takes typing for a new tab.
  virtual void StartNewTab() = 0;
  virtual void GoBack() = 0;
  virtual void GoForward() = 0;
  virtual void Reload() = 0;
  // Enter in the address field; |in_new_tab| after StartNewTab().
  virtual void SubmitAddress(const std::string& text, bool in_new_tab) = 0;
  // Escape in the address field.
  virtual void CancelAddress() = 0;
  // The full address of the selected tab, for editing.
  virtual std::string AddressForEditing() const = 0;
};

}  // namespace birch::ui

#endif  // BIRCH_UI_WINDOW_ACTIONS_H_
