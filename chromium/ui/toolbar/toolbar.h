// The sidebar's top: back, forward, reload, the address field and the
// "Not secure" marker. The address field shows core::AddressBoxFor() of the
// selected tab's committed URL (real host, punycode, only a leading "www."
// dropped); while focused it holds the full address for editing.
// Owner: shared (wave 2); wave-3 agent 6 attaches the command bar here.
#ifndef BIRCH_UI_TOOLBAR_TOOLBAR_H_
#define BIRCH_UI_TOOLBAR_TOOLBAR_H_

#include <optional>
#include <string>

#include "include/views/cef_button_delegate.h"
#include "include/views/cef_label_button.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_textfield.h"
#include "include/views/cef_textfield_delegate.h"

#include "ui/window_actions.h"

namespace birch::ui {

class Toolbar : public CefButtonDelegate, public CefTextfieldDelegate {
 public:
  explicit Toolbar(WindowActions* actions);

  CefRefPtr<CefPanel> panel() const { return panel_; }

  // The selected tab's address (nullopt: no tab) and navigation state.
  void Update(const std::optional<std::string>& url, bool can_go_back,
              bool can_go_forward);
  // Empty field with focus, for a new tab's address.
  void BeginNewTab();
  void FocusAddress();
  // What Enter does with |text| (also used by tests).
  void Submit(const std::string& text);
  bool new_tab_mode() const { return new_tab_mode_; }

  // What the address field shows when not being edited (tests read it).
  std::string address_text() const { return shown_; }
  bool not_secure_shown() const { return not_secure_; }

  // CefButtonDelegate
  void OnButtonPressed(CefRefPtr<CefButton> button) override;
  // CefTextfieldDelegate
  bool OnKeyEvent(CefRefPtr<CefTextfield> textfield,
                  const CefKeyEvent& event) override;
  // CefViewDelegate (the address field)
  void OnFocus(CefRefPtr<CefView> view) override;
  void OnBlur(CefRefPtr<CefView> view) override;

 private:
  void ShowDisplayText();

  WindowActions* actions_;
  CefRefPtr<CefPanel> panel_;
  CefRefPtr<CefLabelButton> back_, forward_, reload_, not_secure_label_;
  CefRefPtr<CefTextfield> address_;
  std::string shown_;
  bool not_secure_ = false;
  bool editing_ = false;
  bool new_tab_mode_ = false;
  IMPLEMENT_REFCOUNTING(Toolbar);
};

}  // namespace birch::ui

#endif  // BIRCH_UI_TOOLBAR_TOOLBAR_H_
