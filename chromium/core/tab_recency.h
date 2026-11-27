// Control+Tab recency, per spec/tab-recency.md (fixture `tab-recency`).
// Engine-free: the window hands in what is open and when each tab was last
// used; this keeps the per-window recent list (memory only) and the held
// cycle, and says which tab to select and what the switcher shows.
//
// Owner: wave-3 agent 6 (cx-commandbar).
#ifndef BIRCH_CORE_TAB_RECENCY_H_
#define BIRCH_CORE_TAB_RECENCY_H_

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace birch::core {

struct CycleContext {
  // The current space's cycle order: favorites, then pinned tabs depth-first
  // (folders and split panes included), then unpinned tabs depth-first.
  std::vector<std::string> order;
  // Tabs that take part: a loaded page, or the selected tab. Tabs never
  // opened, slept, or shown in another window are not in here.
  std::set<std::string> open;
  std::map<std::string, int64_t> last_active;  // seconds, bigger = newer
  std::optional<std::string> selected;
};

class TabRecency {
 public:
  // The window selected |now|; |previous| was selected before (may be empty).
  void NoteSelected(const std::optional<std::string>& previous,
                    const std::string& now);
  // A tab went away.
  void Forget(const std::string& id);

  // One Control+Tab (or menu / command-bar) press. Returns the tab to select;
  // nullopt when nothing is eligible. |holding| = a physical press with the
  // modifier still down: the cycle stays open and the switcher shows.
  std::optional<std::string> Press(const CycleContext& context, bool forward,
                                   bool holding, bool use_recency);

  // The switcher's tabs in order; empty when it is hidden.
  const std::vector<std::string>& switcher() const { return switcher_; }
  bool active() const { return active_; }
  // Modifier released, a click, a space change, focus lost, ...
  void End();

  const std::vector<std::string>& recent() const { return recent_; }

 private:
  std::vector<std::string> recent_;
  std::vector<std::string> cycle_;
  std::vector<std::string> switcher_;
  size_t index_ = 0;
  bool active_ = false;
};

}  // namespace birch::core

#endif  // BIRCH_CORE_TAB_RECENCY_H_
