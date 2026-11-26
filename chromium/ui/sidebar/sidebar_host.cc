#include "ui/sidebar/sidebar_host.h"

#include "platform/platform.h"

namespace birch::ui {

namespace uc = core::ui_channel;

SidebarHost::SidebarHost(WindowActions* actions, int width, bool is_private)
    : actions_(actions),
      page_(engine::UiPage::Create("sidebar", this, width, is_private)) {
  state_.is_private = is_private;
}

SidebarHost::~SidebarHost() = default;

void SidebarHost::Update(uc::SidebarState state) {
  state_ = std::move(state);
  page_->Send("state", uc::SidebarStateJson(state_));
}

void SidebarHost::BeginNewTab() {
  new_tab_mode_ = true;
  SendFocus();
}

void SidebarHost::FocusAddress() {
  new_tab_mode_ = false;
  SendFocus();
}

void SidebarHost::SendFocus() {
  page_->Focus();
  focus_pending_ = !page_->ready();
  page_->Send("address.focus",
              uc::FocusAddressJson(new_tab_mode_, state_.full_url));
}

std::string SidebarHost::address_text() const {
  return state_.address.text.value_or(std::string());
}

std::vector<std::string> SidebarHost::RowTitles() const {
  std::vector<std::string> out;
  for (const core::SidebarRow& r : state_.rows) {
    if (!r.target_id.empty()) {
      out.push_back(r.title);
    }
  }
  return out;
}

bool SidebarHost::IsShownTab(const std::string& id) const {
  for (const core::SidebarRow& r : state_.rows) {
    if (!r.target_id.empty() && r.target_id == id) {
      return true;
    }
  }
  return false;
}

void SidebarHost::OnUiMessage(const uc::Message& m) {
  switch (m.kind) {
    case uc::Kind::kSidebarAction:
      actions_->SidebarAction(m);
      break;
    case uc::Kind::kUiReady:
      page_->Send("state", uc::SidebarStateJson(state_));
      if (focus_pending_ || new_tab_mode_) {
        SendFocus();
      }
      break;
    case uc::Kind::kTabSelect:
      if (IsShownTab(m.id)) {
        actions_->SelectTab(m.id);
      } else {
        platform::Log("sidebar: select of a tab it doesn't show ignored");
      }
      break;
    case uc::Kind::kTabClose:
      if (IsShownTab(m.id)) {
        actions_->CloseTab(m.id);
      } else {
        platform::Log("sidebar: close of a tab it doesn't show ignored");
      }
      break;
    case uc::Kind::kTabNew:
      actions_->StartNewTab();
      break;
    case uc::Kind::kNavBack:
      actions_->GoBack();
      break;
    case uc::Kind::kNavForward:
      actions_->GoForward();
      break;
    case uc::Kind::kNavReload:
      actions_->Reload();
      break;
    case uc::Kind::kAddressSubmit: {
      bool in_new_tab = new_tab_mode_;
      new_tab_mode_ = false;
      if (!m.text.empty()) {
        actions_->SubmitAddress(m.text, in_new_tab);
      }
      break;
    }
    case uc::Kind::kAddressCancel:
      new_tab_mode_ = false;
      actions_->CancelAddress();
      break;
    case uc::Kind::kAddressBlur:
      new_tab_mode_ = false;
      break;
  }
}

void SidebarHost::OnUiCrashed() {
  platform::Log("sidebar: page ended; reloading");
}

}  // namespace birch::ui
