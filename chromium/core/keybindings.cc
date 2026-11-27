#include "core/keybindings.h"

#include <algorithm>

#include "core/codec.h"
#include "core/json.h"

namespace birch::core {

namespace {

// "cmd++" means the plus key: parts of a stroke, split on '+'.
std::vector<std::string> StrokeParts(const std::string& stroke) {
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
  if (EndsWith(stroke, "++")) {
    parts.pop_back();
    parts.pop_back();
    parts.push_back("+");
  }
  return parts;
}

std::string UpperAscii(std::string s) {
  for (char& c : s) {
    if (c >= 'a' && c <= 'z') {
      c = static_cast<char>(c - 32);
    }
  }
  return s;
}

std::string JoinSequence(const std::vector<std::string>& seq) {
  std::string out;
  for (size_t i = 0; i < seq.size(); ++i) {
    out += (i ? " " : "") + seq[i];
  }
  return out;
}

Keybindings::Defaults Build(std::initializer_list<std::pair<const char*, const char*>> list) {
  Keybindings::Defaults out;
  for (const auto& p : list) {
    out.emplace_back(p.first, p.second);
  }
  return out;
}

}  // namespace

const Keybindings::Defaults& Keybindings::MacDefaults() {
  static const Defaults table = [] {
    Defaults d = Build({
        {"cmd+t", "tab.new"}, {"cmd+l", "tab.editURL"}, {"cmd+w", "tab.close"},
        {"cmd+shift+t", "tab.reopen"}, {"cmd+r", "tab.reload"},
        {"cmd+shift+r", "tab.hardReload"}, {"cmd+d", "tab.togglePin"},
        {"cmd+shift+d", "tab.toggleFavorite"}, {"cmd+shift+c", "tab.copyURL"},
        {"cmd+shift+o", "tab.openInFallback"}, {"ctrl+tab", "tab.cycleNext"},
        {"ctrl+shift+tab", "tab.cyclePrevious"}, {"alt+cmd+down", "tab.next"},
        {"alt+cmd+up", "tab.previous"}, {"cmd+[", "nav.back"},
        {"cmd+]", "nav.forward"}, {"cmd+s", "sidebar.toggle"},
        {"cmd+f", "find.show"}, {"cmd+g", "find.next"},
        {"cmd+shift+g", "find.previous"}, {"cmd+=", "view.zoomIn"},
        {"cmd+-", "view.zoomOut"}, {"cmd+0", "view.zoomReset"},
        {"alt+cmd+right", "space.next"}, {"alt+cmd+left", "space.previous"},
        {"alt+cmd+n", "mini.new"}, {"cmd+o", "mini.expand"},
        {"cmd+n", "window.new"}, {"cmd+shift+w", "window.close"},
        {"ctrl+cmd+n", "folder.new"}, {"cmd+shift+n", "private.new"},
        {"cmd+p", "tab.print"}, {"alt+cmd+l", "downloads.show"},
        {"cmd+y", "history.show"}, {"cmd+shift+delete", "data.clearRecent"},
        {"cmd+,", "settings.open"}, {"cmd+k cmd+r", "config.reload"},
        {"cmd+k cmd+t", "theme.edit"}, {"ctrl+shift+=", "split.add"},
        {"ctrl+shift+-", "split.separate"}, {"ctrl+shift+]", "split.focusNext"},
        {"ctrl+shift+[", "split.focusPrevious"}});
    for (int i = 1; i <= 9; ++i) {
      d.emplace_back("ctrl+" + std::to_string(i), "space." + std::to_string(i));
    }
    for (int i = 1; i <= 9; ++i) {
      d.emplace_back("cmd+" + std::to_string(i), "tab.select." + std::to_string(i));
    }
    return d;
  }();
  return table;
}

// The Windows/Linux table. Cmd -> Ctrl. Where the Mac used Control or
// Option+Cmd, strokes that Windows and Ubuntu's desktop already own (Ctrl+Alt+
// arrows switch workspaces; Alt+Shift switches the input language; Ctrl+Alt is
// AltGr on many layouts) are avoided:
//   tab.next/previous   Ctrl+PageDown / Ctrl+PageUp (sidebar order)
//   space.next/previous Alt+PageDown / Alt+PageUp
//   space.1..9          Alt+1..9     (the Mac's Ctrl+1..9)
//   tab.select.1..9     Ctrl+1..9    (the Mac's Cmd+1..9)
//   split.*             Alt+= Alt+- Alt+] Alt+[
//   folder.new          Ctrl+Shift+F, downloads Ctrl+J, history Ctrl+H
//   mini.new            none (no mini windows in this edition yet)
//   config.reload / theme.edit  none: Ctrl+K chords would swallow Ctrl+K in
//                       web pages. Chords still work if added to keybindings.json.
// Ctrl+Tab and Ctrl+Shift+Tab stay as on the Mac (tab recency).
const Keybindings::Defaults& Keybindings::PcDefaults() {
  static const Defaults table = [] {
    Defaults d = Build({
        {"ctrl+t", "tab.new"}, {"ctrl+l", "tab.editURL"}, {"ctrl+w", "tab.close"},
        {"ctrl+shift+t", "tab.reopen"}, {"ctrl+r", "tab.reload"},
        {"f5", "tab.reload"}, {"ctrl+shift+r", "tab.hardReload"},
        {"ctrl+d", "tab.togglePin"}, {"ctrl+shift+d", "tab.toggleFavorite"},
        {"ctrl+shift+c", "tab.copyURL"}, {"ctrl+shift+o", "tab.openInFallback"},
        {"ctrl+tab", "tab.cycleNext"}, {"ctrl+shift+tab", "tab.cyclePrevious"},
        {"ctrl+pagedown", "tab.next"}, {"ctrl+pageup", "tab.previous"},
        {"alt+left", "nav.back"}, {"alt+right", "nav.forward"},
        {"ctrl+s", "sidebar.toggle"}, {"ctrl+f", "find.show"},
        {"ctrl+g", "find.next"}, {"ctrl+shift+g", "find.previous"},
        {"ctrl+=", "view.zoomIn"}, {"ctrl+-", "view.zoomOut"},
        {"ctrl+0", "view.zoomReset"}, {"alt+pagedown", "space.next"},
        {"alt+pageup", "space.previous"}, {"ctrl+o", "mini.expand"},
        {"ctrl+n", "window.new"}, {"ctrl+shift+w", "window.close"},
        {"ctrl+shift+f", "folder.new"}, {"ctrl+shift+n", "private.new"},
        {"ctrl+p", "tab.print"}, {"ctrl+j", "downloads.show"},
        {"ctrl+h", "history.show"}, {"ctrl+shift+delete", "data.clearRecent"},
        {"ctrl+,", "settings.open"}, {"alt+=", "split.add"},
        {"alt+-", "split.separate"}, {"alt+]", "split.focusNext"},
        {"alt+[", "split.focusPrevious"}});
    for (int i = 1; i <= 9; ++i) {
      d.emplace_back("alt+" + std::to_string(i), "space." + std::to_string(i));
    }
    for (int i = 1; i <= 9; ++i) {
      d.emplace_back("ctrl+" + std::to_string(i), "tab.select." + std::to_string(i));
    }
    return d;
  }();
  return table;
}

std::optional<std::string> Keybindings::NormalizeStroke(const std::string& raw) {
  const std::string stroke = ToLowerAscii(raw);
  std::vector<std::string> parts = StrokeParts(stroke);
  if (parts.empty() || parts.back().empty()) {
    return std::nullopt;
  }
  std::string key = parts.back();
  std::set<std::string> mods;
  for (size_t i = 0; i + 1 < parts.size(); ++i) {
    const std::string& m = parts[i];
    if (m == "cmd" || m == "command" || m == "meta" || m == "super") {
      mods.insert("cmd");
    } else if (m == "ctrl" || m == "control") {
      mods.insert("ctrl");
    } else if (m == "alt" || m == "opt" || m == "option") {
      mods.insert("alt");
    } else if (m == "shift") {
      mods.insert("shift");
    } else {
      return std::nullopt;
    }
  }
  if (key == "return") {
    key = "enter";
  } else if (key == "esc") {
    key = "escape";
  } else if (key == "plus") {
    key = "+";
  } else if (key == "backspace") {
    key = "delete";
  }
  std::string out;
  for (const char* m : {"ctrl", "alt", "shift", "cmd"}) {
    if (mods.count(m)) {
      out += std::string(m) + "+";
    }
  }
  return out + key;
}

std::vector<std::string> Keybindings::NormalizeSequence(const std::string& text) {
  std::vector<std::string> out;
  for (const std::string& word : Split(ToLowerAscii(text), ' ')) {
    if (word.empty()) {
      continue;
    }
    if (std::optional<std::string> s = NormalizeStroke(word)) {
      out.push_back(*s);
    }
  }
  return out;
}

std::string Keybindings::Pretty(const std::string& stroke, StrokeStyle style) {
  std::vector<std::string> parts = StrokeParts(stroke);
  std::string key = parts.empty() ? "" : parts.back();
  std::string out;
  for (size_t i = 0; i + 1 < parts.size(); ++i) {
    const std::string& m = parts[i];
    if (style == StrokeStyle::kMac) {
      out += m == "ctrl" ? "\xE2\x8C\x83" : m == "alt" ? "\xE2\x8C\xA5"
           : m == "shift" ? "\xE2\x87\xA7" : m == "cmd" ? "\xE2\x8C\x98" : "";
    } else {
      out += m == "ctrl" ? "Ctrl+" : m == "alt" ? "Alt+" : m == "shift" ? "Shift+"
           : m == "cmd" ? "Super+" : "";
    }
  }
  if (style == StrokeStyle::kMac) {
    static const std::map<std::string, std::string> names = {
        {"tab", "\xE2\x87\xA5"}, {"enter", "\xE2\x86\xA9"}, {"escape", "\xE2\x8E\x8B"},
        {"space", "Space"}, {"delete", "\xE2\x8C\xAB"}, {"left", "\xE2\x86\x90"},
        {"right", "\xE2\x86\x92"}, {"up", "\xE2\x86\x91"}, {"down", "\xE2\x86\x93"}};
    auto it = names.find(key);
    return out + (it != names.end() ? it->second : UpperAscii(key));
  }
  static const std::map<std::string, std::string> names = {
      {"tab", "Tab"}, {"enter", "Enter"}, {"escape", "Esc"}, {"space", "Space"},
      {"delete", "Delete"}, {"left", "Left"}, {"right", "Right"}, {"up", "Up"},
      {"down", "Down"}, {"pageup", "PageUp"}, {"pagedown", "PageDown"},
      {"home", "Home"}, {"end", "End"}};
  auto it = names.find(key);
  return out + (it != names.end() ? it->second : UpperAscii(key));
}

Keybindings::Keybindings(Defaults defaults) : defaults_(std::move(defaults)) {
  Reload(kEmptyUserFile);
}

void Keybindings::Reload(const std::string& user_json_text) {
  // key text -> command (nullopt = switched off); order does not matter.
  std::vector<std::pair<std::string, std::optional<std::string>>> merged;
  for (const auto& d : defaults_) {
    merged.emplace_back(d.first, d.second);
  }
  Json user;
  if (ParseJson(user_json_text, &user) && user.is_object()) {
    for (auto it = user.begin(); it != user.end(); ++it) {
      std::string key = JoinSequence(NormalizeSequence(it.key()));
      for (auto& m : merged) {
        if (JoinSequence(NormalizeSequence(m.first)) == key) {
          m.second = std::nullopt;
        }
      }
      std::optional<std::string> value;
      if (it.value().is_string()) {
        value = it.value().get<std::string>();
      }
      merged.emplace_back(it.key(), value);
    }
  }
  map_.clear();
  for (const auto& m : merged) {
    if (!m.second || m.second->empty()) {
      continue;
    }
    std::vector<std::string> seq = NormalizeSequence(m.first);
    if (!seq.empty()) {
      map_[seq] = *m.second;
    }
  }
  pending_.clear();
}

std::string Keybindings::DefaultsFileText() const {
  Json ref = Json::object();
  for (const auto& d : defaults_) {
    ref[d.first] = d.second;
  }
  return DumpJson(ref);
}

std::optional<std::string> Keybindings::CommandOnStroke(const std::string& stroke) const {
  auto it = map_.find({stroke});
  if (it == map_.end()) {
    return std::nullopt;
  }
  return it->second;
}

std::string Keybindings::DisplayAll(const std::string& command, StrokeStyle style) const {
  std::vector<std::vector<std::string>> seqs;
  for (const auto& e : map_) {
    if (e.second == command) {
      seqs.push_back(e.first);
    }
  }
  std::sort(seqs.begin(), seqs.end(), [](const auto& a, const auto& b) {
    return std::make_pair(a.size(), JoinSequence(a)) < std::make_pair(b.size(), JoinSequence(b));
  });
  std::string out;
  for (size_t i = 0; i < seqs.size(); ++i) {
    if (i) {
      out += "   ";
    }
    for (size_t j = 0; j < seqs[i].size(); ++j) {
      out += (j ? " " : "") + Pretty(seqs[i][j], style);
    }
  }
  return out;
}

std::string Keybindings::SetShortcut(const std::optional<std::string>& stroke,
                                     const std::string& command,
                                     const std::string& user_json_text) const {
  Json user;
  if (!ParseJson(user_json_text, &user) || !user.is_object()) {
    user = Json::object();
  }
  std::vector<std::string> own;
  for (auto it = user.begin(); it != user.end(); ++it) {
    if (it.value().is_string() && it.value().get<std::string>() == command) {
      own.push_back(it.key());
    }
  }
  for (const std::string& k : own) {
    user.erase(k);
  }
  bool default_has_stroke = false;
  for (const auto& d : defaults_) {
    if (d.second != command) {
      continue;
    }
    std::vector<std::string> seq = NormalizeSequence(d.first);
    if (stroke && seq == std::vector<std::string>{*stroke}) {
      user.erase(d.first);  // the default already says this
      default_has_stroke = true;
    } else {
      user[d.first] = nullptr;  // switch the default off
    }
  }
  if (stroke && !default_has_stroke) {
    user[*stroke] = command;
  }
  return DumpJson(user);
}

Keybindings::Dispatch Keybindings::OnStroke(const std::string& stroke,
                                            int64_t now_ms, std::string* command) {
  if (now_ms > pending_expiry_ms_) {
    pending_.clear();
  }
  std::vector<std::string> candidate = pending_;
  candidate.push_back(stroke);
  auto hit = map_.find(candidate);
  if (hit != map_.end()) {
    pending_.clear();
    *command = hit->second;
    return Dispatch::kRun;
  }
  for (const auto& e : map_) {
    if (e.first.size() > candidate.size() &&
        std::equal(candidate.begin(), candidate.end(), e.first.begin())) {
      pending_ = candidate;
      pending_expiry_ms_ = now_ms + 1500;
      return Dispatch::kPending;
    }
  }
  if (!pending_.empty()) {
    pending_.clear();
    auto single = map_.find({stroke});
    if (single != map_.end()) {
      *command = single->second;
      return Dispatch::kRun;
    }
  }
  return Dispatch::kNone;
}

std::set<std::string> Keybindings::AllStrokes() const {
  std::set<std::string> out;
  for (const auto& e : map_) {
    for (const std::string& s : e.first) {
      out.insert(s);
    }
  }
  return out;
}

}  // namespace birch::core
