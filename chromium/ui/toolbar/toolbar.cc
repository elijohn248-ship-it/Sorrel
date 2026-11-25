#include "ui/toolbar/toolbar.h"

#include "include/views/cef_box_layout.h"

#include "core/site.h"

namespace birch::ui {

namespace {

enum ButtonId { kBack = 101, kForward, kReload };
constexpr int kKeyReturn = 0x0D;
constexpr int kKeyEscape = 0x1B;
constexpr char kPlaceholder[] = "Search or enter address";

CefRefPtr<CefLabelButton> Button(CefRefPtr<CefButtonDelegate> delegate,
                                 const std::string& text, int id,
                                 const std::string& name) {
  CefRefPtr<CefLabelButton> b = CefLabelButton::CreateLabelButton(delegate, text);
  b->SetID(id);
  b->SetAccessibleName(name);
  b->SetTooltipText(name);
  return b;
}

}  // namespace

Toolbar::Toolbar(WindowActions* actions) : actions_(actions) {
  panel_ = CefPanel::CreatePanel(nullptr);
  CefBoxLayoutSettings column;
  column.horizontal = false;
  column.between_child_spacing = 4;
  panel_->SetToBoxLayout(column);

  CefRefPtr<CefPanel> nav = CefPanel::CreatePanel(nullptr);
  CefBoxLayoutSettings row;
  row.horizontal = true;
  row.between_child_spacing = 2;
  nav->SetToBoxLayout(row);
  back_ = Button(this, "\xE2\x86\x90", kBack, "Back");          // ←
  forward_ = Button(this, "\xE2\x86\x92", kForward, "Forward");  // →
  reload_ = Button(this, "\xE2\x86\xBB", kReload, "Reload");     // ↻
  not_secure_label_ = Button(this, "Not secure", 0, "Not secure");
  not_secure_label_->SetEnabled(false);
  not_secure_label_->SetEnabledTextColors(CefColorSetARGB(255, 0xC2, 0x5A, 0x00));
  not_secure_label_->SetVisible(false);
  nav->AddChildView(back_);
  nav->AddChildView(forward_);
  nav->AddChildView(reload_);
  nav->AddChildView(not_secure_label_);

  address_ = CefTextfield::CreateTextfield(this);
  address_->SetAccessibleName("Address");
  address_->SetPlaceholderText(kPlaceholder);

  panel_->AddChildView(nav);
  panel_->AddChildView(address_);
  Update(std::nullopt, false, false);
}

void Toolbar::Update(const std::optional<std::string>& url, bool can_go_back,
                     bool can_go_forward) {
  core::AddressBox box = core::AddressBoxFor(url);
  shown_ = box.text.value_or(std::string());
  not_secure_ = box.not_secure_lock;
  back_->SetEnabled(can_go_back);
  forward_->SetEnabled(can_go_forward);
  reload_->SetEnabled(url.has_value());
  not_secure_label_->SetVisible(not_secure_);
  if (!editing_ && !new_tab_mode_) {
    ShowDisplayText();
  }
  panel_->Layout();
}

void Toolbar::ShowDisplayText() {
  address_->SetText(shown_);
}

void Toolbar::BeginNewTab() {
  new_tab_mode_ = true;
  editing_ = true;
  address_->SetText("");
  address_->RequestFocus();
}

void Toolbar::FocusAddress() {
  address_->RequestFocus();
  address_->SelectAll(false);
}

void Toolbar::Submit(const std::string& text) {
  bool was_new_tab = new_tab_mode_;
  new_tab_mode_ = false;
  editing_ = false;
  if (!text.empty()) {
    actions_->SubmitAddress(text, was_new_tab);
  }
  ShowDisplayText();
}

void Toolbar::OnButtonPressed(CefRefPtr<CefButton> button) {
  switch (button->GetID()) {
    case kBack:
      actions_->GoBack();
      break;
    case kForward:
      actions_->GoForward();
      break;
    case kReload:
      actions_->Reload();
      break;
    default:
      break;
  }
}

bool Toolbar::OnKeyEvent(CefRefPtr<CefTextfield> textfield,
                         const CefKeyEvent& event) {
  if (event.type != KEYEVENT_RAWKEYDOWN) {
    return false;
  }
  if (event.windows_key_code == kKeyReturn) {
    Submit(textfield->GetText().ToString());
    return true;
  }
  if (event.windows_key_code == kKeyEscape) {
    new_tab_mode_ = false;
    editing_ = false;
    ShowDisplayText();
    actions_->CancelAddress();
    return true;
  }
  return false;
}

void Toolbar::OnFocus(CefRefPtr<CefView> view) {
  if (!view->IsSame(address_)) {
    return;
  }
  if (!new_tab_mode_) {
    editing_ = true;
    address_->SetText(actions_->AddressForEditing());
  }
  address_->SelectAll(false);
}

void Toolbar::OnBlur(CefRefPtr<CefView> view) {
  if (!view->IsSame(address_)) {
    return;
  }
  editing_ = false;
  new_tab_mode_ = false;
  ShowDisplayText();
}

}  // namespace birch::ui
