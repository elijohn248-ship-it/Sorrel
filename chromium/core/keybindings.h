// Shortcuts and command ids, per spec/keybindings.md (fixture `keybindings`).
// The stroke grammar, the keybindings.json merge rules and Settings ▸
// Shortcuts' edits are the Mac's. What differs is the default table:
//
//   * MacDefaults() is the Mac's table, used by the spec tests only.
//   * PcDefaults() is the Windows/Linux table the app runs with. The Mac's
//     Cmd is Ctrl here; the Mac's Control strokes move so nothing collides
//     (see the table in keybindings.cc). In stroke text, `cmd` still parses
//     (it is the grammar's name for the Super/Windows key) but no default
//     uses it, and the window never registers it.
//
// Owner: wave-3 agent 6 (cx-commandbar). Pure; no files are touched here
// (the window reads and writes keybindings.json and gives the text).
#ifndef BIRCH_CORE_KEYBINDINGS_H_
#define BIRCH_CORE_KEYBINDINGS_H_

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace birch::core {

enum class StrokeStyle { kMac, kPc };

class Keybindings {
 public:
  using Defaults = std::vector<std::pair<std::string, std::string>>;
  static const Defaults& MacDefaults();
  static const Defaults& PcDefaults();

  static std::optional<std::string> NormalizeStroke(const std::string& stroke);
  static std::vector<std::string> NormalizeSequence(const std::string& text);
  // "⇧⌘T" (kMac) or "Ctrl+Shift+T" (kPc).
  static std::string Pretty(const std::string& stroke, StrokeStyle style);

  explicit Keybindings(Defaults defaults);

  // Merges the person's keybindings.json text over the defaults. Text that
  // is not a JSON object leaves the defaults alone.
  void Reload(const std::string& user_json_text);

  // The reference file: sorted JSON object, stroke -> command id.
  std::string DefaultsFileText() const;
  static constexpr const char* kEmptyUserFile = "{\n}\n";

  std::optional<std::string> CommandOnStroke(const std::string& stroke) const;
  // Every shortcut for a command, shortest first, joined by three spaces.
  std::string DisplayAll(const std::string& command, StrokeStyle style) const;

  // Settings ▸ Shortcuts: the new keybindings.json text after giving
  // |command| one stroke (nullopt = none). |user_json_text| is the old one.
  std::string SetShortcut(const std::optional<std::string>& stroke,
                          const std::string& command,
                          const std::string& user_json_text) const;

  // Chords. Feed each physical stroke; kRun fills |command|, kPending means
  // a chord has begun (swallow the key), kNone means not ours.
  enum class Dispatch { kNone, kPending, kRun };
  Dispatch OnStroke(const std::string& stroke, int64_t now_ms,
                    std::string* command);
  void ResetChord() { pending_.clear(); }

  // Every stroke used by any binding (the window registers accelerators for
  // those that can be registered), as "first strokes".
  std::set<std::string> AllStrokes() const;

 private:
  Defaults defaults_;
  std::map<std::vector<std::string>, std::string> map_;
  std::vector<std::string> pending_;
  int64_t pending_expiry_ms_ = 0;
};

}  // namespace birch::core

#endif  // BIRCH_CORE_KEYBINDINGS_H_
