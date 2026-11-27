#include "ui/commandbar/commandbar_host.h"

#include "platform/platform.h"

namespace birch::ui {

namespace uc = core::ui_channel;

CommandBarHost::CommandBarHost(CommandBarActions* actions, bool is_private)
    : actions_(actions),
      is_private_(is_private),
      page_(engine::UiPage::Create("commandbar", this, 0, is_private)) {}

CommandBarHost::~CommandBarHost() = default;

void CommandBarHost::Send(const std::string& name, const std::string& json) {
  if (page_->ready()) {
    page_->Send(name, json);
  } else {
    pending_.emplace_back(name, json);  // sent in order once the page is up
  }
}

void CommandBarHost::FlushPending() {
  std::vector<std::pair<std::string, std::string>> list;
  list.swap(pending_);
  for (const auto& p : list) {
    page_->Send(p.first, p.second);
  }
}

void CommandBarHost::ShowBar(bool edit, const std::string& text,
                             const std::vector<std::string>& colors,
                             const std::string& background) {
  mode_ = edit ? Mode::kEdit : Mode::kNew;
  results_.clear();
  switcher_ids_.clear();
  pending_.clear();  // an older request that never got drawn
  Send("bar.show",
       uc::CommandBarShowJson(edit ? "edit" : "new", text, is_private_, colors, background));
}

void CommandBarHost::ShowSwitcher(const std::vector<uc::SwitcherTab>& tabs,
                                  const std::string& selected_id,
                                  const std::string& modifier,
                                  const std::vector<std::string>& colors,
                                  const std::string& background) {
  mode_ = Mode::kSwitcher;
  results_.clear();
  switcher_ids_.clear();
  for (const uc::SwitcherTab& t : tabs) {
    switcher_ids_.push_back(t.id);
  }
  pending_.clear();
  Send("switcher.show",
       uc::SwitcherShowJson(tabs, selected_id, modifier, is_private_, colors, background));
}

void CommandBarHost::Hide() {
  mode_ = Mode::kHidden;
  results_.clear();
  switcher_ids_.clear();
  pending_.clear();
  if (page_->ready()) {
    page_->Send("bar.hide", "{}");
  }
}

void CommandBarHost::OnUiMessage(const uc::Message& m) {
  switch (m.kind) {
    case uc::Kind::kUiReady:
      FlushPending();
      break;
    case uc::Kind::kCommandBarQuery:
      if (mode_ == Mode::kNew || mode_ == Mode::kEdit) {
        results_ = core::Suggest(actions_->BarSuggestInput(m.text));
        page_->Send("bar.results", uc::CommandBarResultsJson(m.text, results_));
        actions_->BarRowsChanged(results_.size());
      }
      break;
    case uc::Kind::kCommandBarSubmit:
      if (mode_ == Mode::kNew || mode_ == Mode::kEdit) {
        actions_->BarSubmit(m.text);
      }
      break;
    case uc::Kind::kCommandBarPick:
      if (mode_ == Mode::kNew || mode_ == Mode::kEdit) {
        for (const core::SuggestResult& r : results_) {
          if (r.key != m.text) {
            continue;
          }
          std::string target = r.target;
          switch (r.action) {
            case core::SuggestResult::Action::kGo:
              actions_->BarGo(target);
              break;
            case core::SuggestResult::Action::kTab:
              actions_->BarSelectTab(target);
              break;
            case core::SuggestResult::Action::kCommand:
              actions_->BarRunCommand(target);
              break;
          }
          return;
        }
        platform::Log("commandbar: pick of a row it did not send ignored");
      }
      break;
    case uc::Kind::kCommandBarCancel:
      if (mode_ == Mode::kNew || mode_ == Mode::kEdit) {
        actions_->BarCancelled();
      }
      break;
    case uc::Kind::kSwitcherRelease:
      if (mode_ == Mode::kSwitcher) {
        actions_->SwitcherReleased();
      }
      break;
    case uc::Kind::kSwitcherCancel:
      if (mode_ == Mode::kSwitcher) {
        actions_->SwitcherCancelled();
      }
      break;
    case uc::Kind::kSwitcherPick:
      if (mode_ == Mode::kSwitcher) {
        for (const std::string& id : switcher_ids_) {
          if (id == m.id) {
            actions_->SwitcherPicked(id);
            return;
          }
        }
        platform::Log("commandbar: switcher pick of a tab it does not show ignored");
      }
      break;
    default:
      break;  // other pages' messages
  }
}

void CommandBarHost::OnUiCrashed() {
  platform::Log("commandbar: page ended; reloading");
  mode_ = Mode::kHidden;
  actions_->BarCancelled();
}

}  // namespace birch::ui
