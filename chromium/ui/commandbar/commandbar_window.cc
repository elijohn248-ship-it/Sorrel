// MainWindow's side of the command bar, the shortcut registry and Control+Tab
// (wave 3, agent 6): opening and placing the bar, turning accelerators into
// commands through core::Keybindings, the tab cycle and its switcher. Kept
// out of main_window.cc so that file's diff stays small.
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <map>
#include <functional>
#include <set>

#include "core/archive_history.h"
#include "core/bangs.h"
#include "core/codec.h"
#include "core/commands.h"
#include "core/keybindings.h"
#include "core/typed_url.h"
#include "platform/platform.h"
#include "ui/main_window.h"

namespace birch::ui {

namespace {

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void ReadKeysFromDisk(core::Keybindings* kb) {
  const std::string dir = platform::ProfileDir();
  core::MakeDirectories(dir);
  // The reference copy of the defaults, rewritten at every launch; the
  // person's own file is created empty once and never rewritten.
  core::WriteFileAtomic(core::JoinPath(dir, "keybindings.default.json"), kb->DefaultsFileText());
  const std::string user_path = core::JoinPath(dir, "keybindings.json");
  std::string text;
  if (!core::FileExists(user_path)) {
    core::WriteFileAtomic(user_path, core::Keybindings::kEmptyUserFile);
    text = core::Keybindings::kEmptyUserFile;
  } else {
    core::ReadFileUtf8Path(user_path, &text);
  }
  kb->Reload(text);
}

void ReadBangsFromDisk(core::Bangs* bangs) {
  bangs->Clear();
  std::string text;
  if (core::ReadFileUtf8Path(core::JoinPath(platform::ExecutableDir(), "bangs.json"), &text)) {
    bangs->Ingest(text);
  }
  const std::string custom = core::JoinPath(platform::ProfileDir(), "bangs.json");
  if (!core::FileExists(custom)) {
    core::MakeDirectories(platform::ProfileDir());
    core::WriteFileAtomic(custom, "[\n]\n");
  } else if (core::ReadFileUtf8Path(custom, &text)) {
    bangs->Ingest(text);  // the person's bangs win over the bundled list
  }
}

core::Keybindings& Keys() {
  static core::Keybindings kb(core::Keybindings::PcDefaults());
  static bool loaded = false;
  if (!loaded) {
    loaded = true;
    ReadKeysFromDisk(&kb);
  }
  return kb;
}

core::Bangs& BangTable() {
  static bool loaded = false;
  if (!loaded) {
    loaded = true;
    ReadBangsFromDisk(&core::SharedBangs());
  }
  return core::SharedBangs();
}

struct Accel {
  int vk;
  bool shift, ctrl, alt;
};

// Windows virtual-key codes (CEF uses them on every OS). Only strokes with
// Ctrl or Alt (or a function key) become accelerators, so typing is never
// swallowed; strokes with `cmd` (the Super key) cannot be registered.
std::vector<Accel> AccelsFor(const std::string& stroke) {
  std::vector<std::string> parts;
  size_t start = 0;
  for (;;) {
    size_t plus = stroke.find('+', start);
    if (plus == std::string::npos) {
      parts.push_back(stroke.substr(start));
      break;
    }
    parts.push_back(stroke.substr(start, plus - start));
    start = plus + 1;
  }
  if (parts.size() < 2 && stroke.find('+') != std::string::npos) {
    return {};
  }
  std::string key = parts.back();
  bool shift = false, ctrl = false, alt = false;
  for (size_t i = 0; i + 1 < parts.size(); ++i) {
    if (parts[i] == "shift") shift = true;
    else if (parts[i] == "ctrl") ctrl = true;
    else if (parts[i] == "alt") alt = true;
    else return {};  // cmd / empty
  }
  static const std::map<std::string, int> named = {
      {"tab", 0x09}, {"enter", 0x0D}, {"escape", 0x1B}, {"space", 0x20},
      {"left", 0x25}, {"up", 0x26}, {"right", 0x27}, {"down", 0x28},
      {"pageup", 0x21}, {"pagedown", 0x22}, {"end", 0x23}, {"home", 0x24},
      {",", 0xBC}, {"-", 0xBD}, {".", 0xBE}, {"=", 0xBB}, {"[", 0xDB},
      {"]", 0xDD}, {"\\", 0xDC}, {";", 0xBA}, {"'", 0xDE}, {"/", 0xBF}, {"`", 0xC0}};
  std::vector<int> vks;
  bool function_key = false;
  if (key == "delete") {
    vks = {0x08, 0x2E};  // Backspace (the Mac's delete) and Delete
  } else if (named.count(key)) {
    vks = {named.at(key)};
  } else if (key.size() == 1 && ((key[0] >= 'a' && key[0] <= 'z') || (key[0] >= '0' && key[0] <= '9'))) {
    vks = {key[0] >= 'a' ? key[0] - 'a' + 0x41 : key[0]};
  } else if (key.size() >= 2 && key[0] == 'f' && key.size() <= 3) {
    int n = std::atoi(key.c_str() + 1);
    if (n < 1 || n > 12) return {};
    vks = {0x70 + n - 1};
    function_key = true;
  } else {
    return {};
  }
  if (!(ctrl || alt || function_key)) {
    return {};
  }
  std::vector<Accel> out;
  for (int vk : vks) out.push_back({vk, shift, ctrl, alt});
  return out;
}

// What this window can run today (the rest of the Mac's ids belong to
// features other agents are still porting). Listed in the command bar.
const std::set<std::string>& Supported() {
  static const std::set<std::string> ids = [] {
    std::set<std::string> s = {"window.new", "window.close", "private.new", "tab.new",
                               "tab.editURL", "tab.close", "tab.reload", "nav.back",
                               "nav.forward", "tab.cycleNext", "tab.cyclePrevious",
                               "tab.next", "tab.previous", "space.next", "space.previous",
                               "sidebar.toggle", "archive.now", "tabs.sleepNow", "config.reload"};
    for (int i = 1; i <= 9; ++i) {
      s.insert("tab.select." + std::to_string(i));
      s.insert("space." + std::to_string(i));
    }
    return s;
  }();
  return ids;
}

void Leaves(const core::Item& item, std::vector<const core::Item*>* out) {
  if (item.IsTab()) {
    out->push_back(&item);
  } else {
    for (const core::Item& c : item.children) Leaves(c, out);
  }
}

}  // namespace

core::Bangs& MainWindow::BangsTable() { return BangTable(); }

// ---- shortcuts ---------------------------------------------------------------------------

void MainWindow::RegisterShortcuts() {
  if (!window_) return;
  window_->RemoveAllAccelerators();
  accel_strokes_.clear();
  for (const std::string& stroke : Keys().AllStrokes()) {
    for (const Accel& a : AccelsFor(stroke)) {
      int id = kAcceleratorBase + static_cast<int>(accel_strokes_.size());
      accel_strokes_.push_back(stroke);
      window_->SetAccelerator(id, a.vk, a.shift, a.ctrl, a.alt, true);
    }
  }
}

std::set<std::string> MainWindow::accelerator_strokes() const {
  return std::set<std::string>(accel_strokes_.begin(), accel_strokes_.end());
}

bool MainWindow::HandleStroke(const std::string& stroke) {
  std::string command;
  switch (Keys().OnStroke(stroke, NowMs(), &command)) {
    case core::Keybindings::Dispatch::kPending:
      return true;
    case core::Keybindings::Dispatch::kNone:
      return false;
    case core::Keybindings::Dispatch::kRun:
      break;
  }
  if (command == "tab.cycleNext" || command == "tab.cyclePrevious") {
    cycle_modifier_ = stroke.rfind("ctrl", 0) == 0 ? "Control"
                      : stroke.rfind("alt", 0) == 0 ? "Alt" : "Shift";
  }
  return RunCommand(command, /*physical=*/true);
}

void MainWindow::ReloadConfig() {
  ReadKeysFromDisk(&Keys());
  ReadBangsFromDisk(&core::SharedBangs());
  RegisterShortcuts();
}

// ---- the command bar -----------------------------------------------------------------------

std::string MainWindow::command_bar_mode() const {
  if (!bar_) return "none";
  switch (bar_->mode()) {
    case CommandBarHost::Mode::kNew: return "new";
    case CommandBarHost::Mode::kEdit: return "edit";
    case CommandBarHost::Mode::kSwitcher: return "switcher";
    case CommandBarHost::Mode::kHidden: break;
  }
  return "hidden";
}

engine::UiPage* MainWindow::command_bar_page() const {
  return bar_ ? bar_->page() : nullptr;
}

CefRect MainWindow::BarBounds() const {
  if (!window_ || !bar_) return CefRect();
  const CefRect win = window_->GetBounds();
  const int w_all = win.width, h_all = win.height;
  const int width = std::clamp(static_cast<int>(ctx_.store->state().sidebar_width), 180, 480);
  const int reserved = sidebar_mode_ == "pinned" ? width : 0;
  const int page_w = std::max(200, w_all - reserved);
  const int rows = static_cast<int>(bar_->row_count());
  switch (bar_->mode()) {
    case CommandBarHost::Mode::kNew: {
      int w = std::clamp(page_w - 48, 320, 640);
      int h = 56 + (rows ? rows * 40 + 10 : 0);
      return CefRect(reserved + (page_w - w) / 2, std::max(40, h_all / 6), w, h);
    }
    case CommandBarHost::Mode::kEdit: {
      int w = std::clamp(std::max(reserved - 16, 420), 320, std::max(320, w_all - 16));
      int h = 56 + (rows ? rows * 40 + 10 : 0);
      return CefRect(8, 46, w, h);
    }
    case CommandBarHost::Mode::kSwitcher: {
      int n = static_cast<int>(bar_switcher_count_);
      int w = std::clamp(n * 156 + 24, 200, std::max(200, page_w - 48));
      return CefRect(reserved + (page_w - w) / 2, std::max(20, h_all / 2 - 58), w, 116);
    }
    case CommandBarHost::Mode::kHidden:
      break;
  }
  return CefRect();
}

void MainWindow::PlaceBar() {
  if (!bar_overlay_ || !bar_) return;
  if (bar_->mode() == CommandBarHost::Mode::kHidden) {
    bar_overlay_->SetVisible(false);
    return;
  }
  bar_overlay_->SetBounds(BarBounds());
  bar_overlay_->SetVisible(true);
}

void MainWindow::OpenCommandBar(bool edit) {
  if (destroyed_ || closing_window_ || !bar_) return;
  sidebar_->EndAddressEditing();
  recency_.End();
  if (edit && !selected_id()) edit = false;
  bar_history_.clear();
  if (!ctx_.is_private) {
    std::string text;
    if (core::ReadFileUtf8Path(core::JoinPath(platform::ProfileDir(), "history.json"), &text)) {
      std::string error;
      core::DecodeHistory(text, &bar_history_, &error);
    }
  }
  BangTable();  // loaded before the first keystroke
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  bar_->ShowBar(edit, edit ? AddressForEditing() : std::string(),
                ctx_.is_private ? std::vector<std::string>() : space.theme.colors, ThemeSurround());
  PlaceBar();
  bar_->page()->Focus();
}

void MainWindow::CloseCommandBar(bool focus_page) {
  if (!bar_ || bar_->mode() == CommandBarHost::Mode::kHidden) return;
  bar_->Hide();
  PlaceBar();
  if (focus_page && !destroyed_) CancelAddress();
}

core::SuggestInput MainWindow::BarSuggestInput(const std::string& text) {
  core::SuggestInput in;
  in.text = text;
  in.search_engine_name = ctx_.settings->searchEngineName;
  in.search_template = ctx_.settings->searchEngineURL;
  in.bangs = &BangTable();
  in.now = core::NowSeconds();
  in.history = bar_history_;
  if (auto sel = selected_id()) in.selected_id = *sel;
  auto add = [&](const core::Item& item, const std::string& place) {
    std::vector<const core::Item*> leaves;
    Leaves(item, &leaves);
    for (const core::Item* t : leaves) {
      core::SuggestTab st;
      st.id = t->id;
      st.title = t->DisplayTitle();
      st.url = t->url.value_or("");
      st.place = place;
      st.last_active = t->last_active;
      in.tabs.push_back(st);
    }
  };
  for (const core::Item& f : ctx_.store->state().favorites) add(f, "Favorites");
  for (const core::Space& sp : ctx_.store->state().spaces) {
    for (const core::Item& i : sp.pinned) add(i, sp.icon + " " + sp.name);
    for (const core::Item& i : sp.today) add(i, sp.icon + " " + sp.name);
  }
  std::vector<std::string> recent = CycleOrder();
  std::stable_sort(recent.begin(), recent.end(), [&](const std::string& a, const std::string& b) {
    const core::Item* x = ctx_.store->FindItem(a);
    const core::Item* y = ctx_.store->FindItem(b);
    return (x ? x->last_active : 0) > (y ? y->last_active : 0);
  });
  in.recent = recent;
  for (const core::CommandInfo& c : core::AllCommands()) {
    if (!Supported().count(c.id)) continue;
    std::string hint = Keys().DisplayAll(c.id, core::StrokeStyle::kPc);
    size_t gap = hint.find("   ");
    in.commands.push_back({c.id, c.title, gap == std::string::npos ? hint : hint.substr(0, gap)});
  }
  return in;
}

void MainWindow::BarGo(const std::string& url) {
  const bool in_new_tab = bar_->mode() == CommandBarHost::Mode::kNew;
  CloseCommandBar(false);
  LoadAddress(url, in_new_tab);
}

void MainWindow::BarSubmit(const std::string& text) {
  const bool in_new_tab = bar_->mode() == CommandBarHost::Mode::kNew;
  CloseCommandBar(false);
  SubmitAddress(text, in_new_tab);
}

void MainWindow::BarSelectTab(const std::string& id) {
  CloseCommandBar(false);
  SelectTab(id);
}

void MainWindow::BarRunCommand(const std::string& id) {
  CloseCommandBar(false);
  RunCommand(id);
}

void MainWindow::BarCancelled() { CloseCommandBar(true); }
void MainWindow::BarRowsChanged(size_t) { PlaceBar(); }

// ---- Control+Tab -------------------------------------------------------------------------

std::vector<std::string> MainWindow::CycleOrder() const {
  std::vector<std::string> out;
  std::vector<const core::Item*> leaves;
  for (const core::Item& f : ctx_.store->state().favorites) Leaves(f, &leaves);
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  for (const core::Item& i : space.pinned) Leaves(i, &leaves);
  for (const core::Item& i : space.today) Leaves(i, &leaves);
  for (const core::Item* t : leaves) out.push_back(t->id);
  return out;
}

void MainWindow::CycleTabs(bool forward, bool physical) {
  core::CycleContext ctx;
  ctx.order = CycleOrder();
  for (const auto& kv : pages_) ctx.open.insert(kv.first);
  ctx.selected = selected_id();
  if (ctx.selected) ctx.open.insert(*ctx.selected);
  for (const std::string& id : ctx.order) {
    if (const core::Item* item = ctx_.store->FindItem(id)) ctx.last_active[id] = item->last_active;
  }
  std::optional<std::string> target =
      recency_.Press(ctx, forward, physical, ctx_.settings->controlTabUsesRecency);
  if (target) {
    cycling_select_ = true;
    SelectTab(*target);
    cycling_select_ = false;
  }
  if (physical && recency_.switcher().size() >= 2) {
    ShowSwitcher();
  } else {
    HideSwitcher();
  }
}

void MainWindow::ShowSwitcher() {
  if (!bar_) return;
  std::vector<core::ui_channel::SwitcherTab> tabs;
  for (const std::string& id : recency_.switcher()) {
    if (const core::Item* item = ctx_.store->FindItem(id)) {
      tabs.push_back({id, item->DisplayTitle(), item->Host().value_or("")});
    }
  }
  bar_switcher_count_ = tabs.size();
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  bar_->ShowSwitcher(tabs, selected_id().value_or(""), cycle_modifier_,
                     ctx_.is_private ? std::vector<std::string>() : space.theme.colors,
                     ThemeSurround());
  PlaceBar();
  bar_->page()->Focus();
}

void MainWindow::HideSwitcher() {
  if (bar_ && bar_->mode() == CommandBarHost::Mode::kSwitcher) {
    bar_->Hide();
    PlaceBar();
  }
}

void MainWindow::OnTabSelected(const std::optional<std::string>& previous, const std::string& id) {
  recency_.NoteSelected(previous, id);
  if (!cycling_select_) {  // a click, a command or a space change ends a held cycle
    recency_.End();
    HideSwitcher();
  }
}

void MainWindow::SwitcherReleased() {
  recency_.End();
  HideSwitcher();
  CancelAddress();
}

void MainWindow::SwitcherPicked(const std::string& id) {
  recency_.End();
  HideSwitcher();
  SelectTab(id);
}

void MainWindow::SwitcherCancelled() { SwitcherReleased(); }

void MainWindow::StepTab(bool forward) {
  // Sidebar order over every tab, sleeping ones included.
  std::vector<std::string> order = CycleOrder();
  if (order.empty()) return;
  auto sel = selected_id();
  size_t i = 0;
  if (sel) {
    auto it = std::find(order.begin(), order.end(), *sel);
    if (it != order.end()) {
      size_t at = static_cast<size_t>(it - order.begin());
      i = forward ? (at + 1) % order.size() : (at + order.size() - 1) % order.size();
    }
  }
  SelectTab(order[i]);
}

void MainWindow::SelectNumbered(size_t n) {
  // "Go to Favorite or Pinned Tab N": favorites, then pinned tabs.
  std::vector<const core::Item*> leaves;
  for (const core::Item& f : ctx_.store->state().favorites) Leaves(f, &leaves);
  const core::Space& space = ctx_.store->CurrentSpace(ctx_.session);
  for (const core::Item& i : space.pinned) Leaves(i, &leaves);
  if (n >= 1 && n <= leaves.size()) SelectTab(leaves[n - 1]->id);
}

}  // namespace birch::ui
