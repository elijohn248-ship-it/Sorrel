// The in-memory profile (spaces, tabs, favorites) and each window's session
// (current space, selected tab per space), with the tab operations the
// wave-2 shell needs. Engine-free and UI-free: the app keeps live pages by
// item id and calls these when pages report changes.
//
// Owners: wave-3 agent 5 extends spaces/favorites/folders/pinning/archive/
// sleep here; agent 8 adds split and closed-tab behaviour. Keep each
// addition a separate method so parallel branches merge cleanly.
#ifndef BIRCH_CORE_STORE_H_
#define BIRCH_CORE_STORE_H_

#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "core/archive_history.h"
#include "core/model.h"

namespace birch::core {

// One window's selections. Saved as BrowserWindowState for normal windows.
struct WindowSession {
  std::string id;
  std::string current_space_id;
  std::vector<std::pair<std::string, std::string>> selections;  // space->tab

  std::optional<std::string> SelectedIn(const std::string& space_id) const;
  void SetSelected(const std::string& space_id,
                   const std::optional<std::string>& item_id);
};

// A row of the plain sidebar (wave 2). Agent 5 replaces the sidebar; the
// rows stay a convenient flattening of the current space.
struct SidebarRow {
  enum class Kind { kFavorite, kPinned, kFolder, kSplit, kSeparator, kToday };
  Kind kind = Kind::kToday;
  std::string item_id;    // for kSplit: the split; select() takes |target_id|
  std::string target_id;  // the tab a click selects ("" = not selectable)
  std::string title;
  int depth = 0;
  std::string parent_id;  // folder id for nested rows
  size_t index = 0;       // position within the section or folder
  bool expanded = false;
  std::string section;   // favorites, pinned or today
};

enum class SidebarSection { kFavorites, kPinned, kToday, kFolder };

struct SidebarDestination {
  SidebarSection section;
  std::string space_id;   // ignored for favorites
  std::string folder_id;  // used only for kFolder
};

class Store {
 public:
  explicit Store(AppState state);

  const AppState& state() const { return state_; }
  // Set by every change; the app saves (debounced) and clears it.
  bool dirty() const { return dirty_; }
  void ClearDirty() { dirty_ = false; }

  // ---- windows ----------------------------------------------------------------
  // The saved windows (or one built from the legacy fields), each cleaned per
  // spec/saved-data.md ▸ On launch: unknown current space -> first space;
  // selections of missing tabs or tabs in another space (favorites excepted)
  // dropped; a tab shown in an earlier window loses its later selection.
  std::vector<WindowSession> RestoreWindows() const;
  // Records |open| (normal windows, |focused| first) for saving.
  void SnapshotWindows(const std::vector<WindowSession>& open,
                       const WindowSession& focused);

  // ---- lookups ------------------------------------------------------------------
  const Space* FindSpace(const std::string& space_id) const;
  // The current space of |session| (first space when unknown).
  const Space& CurrentSpace(const WindowSession& session) const;
  const Item* FindItem(const std::string& item_id) const;
  // The space holding |item_id| (nullptr for favorites or unknown).
  const Space* SpaceOf(const std::string& item_id) const;
  bool IsFavorite(const std::string& item_id) const;
  bool IsPinned(const std::string& item_id) const;
  void SetSidebarCollapsed(bool collapsed);
  // Rows for the plain sidebar: favorites, pinned (folders expanded),
  // separator, today.
  std::vector<SidebarRow> SidebarRows(const std::string& space_id) const;

  // ---- sidebar editing ------------------------------------------------------------
  // The caller selects a new space in its window session.
  std::string AddSpace(const std::string& name = "New Space",
                       const std::string& icon = "✨",
                       const std::optional<Theme>& theme = std::nullopt);
  bool EditSpace(const std::string& space_id,
                 const std::optional<std::string>& name,
                 const std::optional<std::string>& icon,
                 const std::optional<Theme>& theme = std::nullopt);
  bool MoveSpace(const std::string& space_id, size_t index);
  // The caller must rebuild any live pages with the new engine context.
  bool SetSeparateLogins(const std::string& space_id, bool separate);
  std::string AddFolder(const std::string& space_id,
                        const std::string& title = "New Folder",
                        const std::string& parent_folder_id = {});
  bool SetFolderExpanded(const std::string& folder_id, bool expanded);
  // The index is the final slot within the destination, after removal.
  // With no index the item goes at the end. Panes move with their split
  // unless an individual pane is moved to favorites.
  bool MoveItem(const std::string& item_id,
                const SidebarDestination& destination,
                std::optional<size_t> index = std::nullopt);

  // ---- tab operations -------------------------------------------------------------
  // A new unpinned tab at the top of |space_id|'s today list. Returns its id.
  std::string AddTab(const std::string& space_id, const std::string& url,
                     const std::string& title);
  enum class CloseResult { kRemoved, kKeptPinned, kNotFound };
  // Unpinned tabs and favorites-free tabs are removed; pinned tabs and
  // favorites stay in the sidebar (the app unloads their page).
  CloseResult CloseTab(const std::string& item_id);
  // The tab to select after |item_id| closes in |space_id|: the next today
  // tab below it, else above, else nullopt. Call before CloseTab.
  std::optional<std::string> NeighbourAfterClose(const std::string& space_id,
                                                 const std::string& item_id) const;
  // A committed navigation or a new title. Bundled pages are saved under
  // their current birch:// name.
  void UpdatePage(const std::string& item_id,
                  const std::optional<std::string>& url,
                  const std::optional<std::string>& title);
  void Touch(const std::string& item_id, int64_t now_seconds);
  // Protect every visible pane and the focused window's per-space selections.
  // Returns newest-first HTTP(S) records and optionally all removed leaf IDs.
  std::vector<ArchivedTab> ArchiveStale(
      int64_t now_seconds, double older_than_hours,
      const std::set<std::string>& protected_ids,
      std::vector<std::string>* removed_tab_ids = nullptr);

 private:
  Space* MutableSpace(const std::string& space_id);
  std::vector<Item>* MutableSidebarList(const SidebarDestination& destination);
  void PruneSavedSelections();
  Item* MutableItem(const std::string& item_id);

  AppState state_;
  bool dirty_ = false;
};

}  // namespace birch::core

#endif  // BIRCH_CORE_STORE_H_
