#include "core/store.h"

#include <algorithm>
#include <set>

#include "core/codec.h"
#include "core/lifecycle.h"

namespace birch::core {

namespace {

const Item* FindIn(const std::vector<Item>& items, const std::string& id) {
  for (const Item& it : items) {
    if (it.id == id) {
      return &it;
    }
    if (const Item* c = FindIn(it.children, id)) {
      return c;
    }
  }
  return nullptr;
}

Item* FindInMutable(std::vector<Item>& items, const std::string& id) {
  for (Item& it : items) {
    if (it.id == id) {
      return &it;
    }
    if (Item* c = FindInMutable(it.children, id)) {
      return c;
    }
  }
  return nullptr;
}

// Removes or extracts an item at any depth. A split left with one pane
// dissolves into that tab.
bool RemoveFrom(std::vector<Item>& items, const std::string& id,
                Item* removed = nullptr) {
  for (size_t i = 0; i < items.size(); ++i) {
    if (items[i].id == id) {
      if (removed) {
        *removed = std::move(items[i]);
      }
      items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
      return true;
    }
    if (RemoveFrom(items[i].children, id, removed)) {
      if (items[i].IsSplit()) {
        if (items[i].children.empty()) {
          items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
        } else if (items[i].children.size() == 1) {
          Item only = std::move(items[i].children.front());
          items[i] = std::move(only);
        } else {
          items[i].split->fractions.clear();
        }
      }
      return true;
    }
  }
  return false;
}

const Item* SplitWithPane(const std::vector<Item>& items, const std::string& id) {
  for (const Item& item : items) {
    if (item.IsSplit() && FindIn(item.children, id)) {
      return &item;
    }
    if (item.is_folder) {
      if (const Item* split = SplitWithPane(item.children, id)) {
        return split;
      }
    }
  }
  return nullptr;
}

void UpdatePinnedAddresses(Item& item, bool pinned) {
  if (item.IsTab()) {
    if (!pinned) {
      item.pinned_url.reset();
    } else if (!item.pinned_url) {
      item.pinned_url = item.url;
    }
    return;
  }
  for (Item& child : item.children) {
    UpdatePinnedAddresses(child, pinned);
  }
}

bool ResetPinnedAddress(Item& item) {
  if (item.IsTab()) {
    if (item.pinned_url && item.url != item.pinned_url) {
      item.url = item.pinned_url;
      return true;
    }
    return false;
  }
  bool changed = false;
  for (Item& child : item.children) {
    changed = ResetPinnedAddress(child) || changed;
  }
  return changed;
}

void AddRows(const std::vector<Item>& items, SidebarRow::Kind kind, int depth,
             const std::string& section, const std::string& parent_id,
             std::vector<SidebarRow>* rows) {
  for (size_t index = 0; index < items.size(); ++index) {
    const Item& it = items[index];
    SidebarRow row;
    row.item_id = it.id;
    row.title = it.DisplayTitle();
    row.depth = depth;
    row.parent_id = parent_id;
    row.index = index;
    row.section = section;
    if (it.is_folder) {
      row.kind = SidebarRow::Kind::kFolder;
      row.expanded = it.expanded;
      rows->push_back(row);
      if (it.expanded) {
        AddRows(it.children, kind, depth + 1, section, it.id, rows);
      }
      continue;
    }
    if (it.IsSplit()) {
      row.kind = SidebarRow::Kind::kSplit;
      row.target_id = it.children.empty() ? std::string() : it.children[0].id;
    } else {
      row.kind = kind;
      row.target_id = it.id;
    }
    rows->push_back(row);
  }
}

}  // namespace

std::optional<std::string> WindowSession::SelectedIn(
    const std::string& space_id) const {
  for (const auto& p : selections) {
    if (p.first == space_id) {
      return p.second;
    }
  }
  return std::nullopt;
}

void WindowSession::SetSelected(const std::string& space_id,
                                const std::optional<std::string>& item_id) {
  for (size_t i = 0; i < selections.size(); ++i) {
    if (selections[i].first == space_id) {
      if (item_id) {
        selections[i].second = *item_id;
      } else {
        selections.erase(selections.begin() + static_cast<std::ptrdiff_t>(i));
      }
      return;
    }
  }
  if (item_id) {
    selections.emplace_back(space_id, *item_id);
  }
}

Store::Store(AppState state) : state_(std::move(state)) {}

std::vector<WindowSession> Store::RestoreWindows() const {
  std::vector<WindowSession> out;
  if (state_.windows && !state_.windows->empty()) {
    for (const BrowserWindowState& w : *state_.windows) {
      out.push_back({w.id, w.current_space_id, w.selections});
    }
  } else {
    WindowSession s;
    s.id = NewUuid();
    s.current_space_id = state_.current_space_id;
    for (const Space& sp : state_.spaces) {
      if (sp.selected_id) {
        s.selections.emplace_back(sp.id, *sp.selected_id);
      }
    }
    out.push_back(s);
  }
  std::set<std::string> shown;
  for (WindowSession& w : out) {
    if (!FindSpace(w.current_space_id) && !state_.spaces.empty()) {
      w.current_space_id = state_.spaces[0].id;
    }
    std::vector<std::pair<std::string, std::string>> kept;
    for (const auto& p : w.selections) {
      const Space* sp = FindSpace(p.first);
      bool ok = sp && (IsFavorite(p.second) ||
                       FindIn(sp->pinned, p.second) ||
                       FindIn(sp->today, p.second));
      if (ok) {
        kept.push_back(p);
      }
    }
    w.selections = kept;
    if (std::optional<std::string> sel = w.SelectedIn(w.current_space_id)) {
      if (shown.count(*sel)) {
        w.SetSelected(w.current_space_id, std::nullopt);
      } else {
        shown.insert(*sel);
      }
    }
  }
  return out;
}

void Store::SnapshotWindows(const std::vector<WindowSession>& open,
                            const WindowSession& focused) {
  std::vector<BrowserWindowState> windows;
  for (const WindowSession& w : open) {
    windows.push_back({w.id, w.current_space_id, w.selections});
  }
  state_.windows = windows;
  state_.current_space_id = focused.current_space_id;
  for (Space& sp : state_.spaces) {
    sp.selected_id = focused.SelectedIn(sp.id);
  }
  dirty_ = true;
}

const Space* Store::FindSpace(const std::string& space_id) const {
  for (const Space& sp : state_.spaces) {
    if (sp.id == space_id) {
      return &sp;
    }
  }
  return nullptr;
}

const Space& Store::CurrentSpace(const WindowSession& session) const {
  const Space* sp = FindSpace(session.current_space_id);
  return sp ? *sp : state_.spaces.front();
}

const Item* Store::FindItem(const std::string& item_id) const {
  if (const Item* f = FindIn(state_.favorites, item_id)) {
    return f;
  }
  for (const Space& sp : state_.spaces) {
    if (const Item* it = FindIn(sp.pinned, item_id)) {
      return it;
    }
    if (const Item* it = FindIn(sp.today, item_id)) {
      return it;
    }
  }
  return nullptr;
}

const Space* Store::SpaceOf(const std::string& item_id) const {
  for (const Space& sp : state_.spaces) {
    if (FindIn(sp.pinned, item_id) || FindIn(sp.today, item_id)) {
      return &sp;
    }
  }
  return nullptr;
}

bool Store::IsFavorite(const std::string& item_id) const {
  return FindIn(state_.favorites, item_id) != nullptr;
}

bool Store::IsPinned(const std::string& item_id) const {
  const Space* space = SpaceOf(item_id);
  return space && FindIn(space->pinned, item_id);
}

std::vector<SidebarRow> Store::SidebarRows(const std::string& space_id) const {
  std::vector<SidebarRow> rows;
  AddRows(state_.favorites, SidebarRow::Kind::kFavorite, 0, "favorites", {}, &rows);
  const Space* sp = FindSpace(space_id);
  if (!sp) {
    return rows;
  }
  AddRows(sp->pinned, SidebarRow::Kind::kPinned, 0, "pinned", {}, &rows);
  SidebarRow sep;
  sep.kind = SidebarRow::Kind::kSeparator;
  rows.push_back(sep);
  AddRows(sp->today, SidebarRow::Kind::kToday, 0, "today", {}, &rows);
  return rows;
}

std::string Store::AddSpace(const std::string& name, const std::string& icon,
                            const std::optional<Theme>& theme) {
  Space space;
  space.id = NewUuid();
  space.name = TrimSpaces(name).empty() ? "New Space" : name;
  space.icon = icon.empty() ? "✨" : icon;
  const auto& presets = Theme::Presets();
  space.theme = theme.value_or(presets[state_.spaces.size() % presets.size()]);
  state_.spaces.push_back(std::move(space));
  dirty_ = true;
  return state_.spaces.back().id;
}

bool Store::EditSpace(const std::string& space_id,
                      const std::optional<std::string>& name,
                      const std::optional<std::string>& icon,
                      const std::optional<Theme>& theme) {
  Space* space = MutableSpace(space_id);
  if (!space) {
    return false;
  }
  if (name && !TrimSpaces(*name).empty() && space->name != *name) {
    space->name = *name;
    dirty_ = true;
  }
  if (icon && !icon->empty() && space->icon != *icon) {
    space->icon = *icon;
    dirty_ = true;
  }
  if (theme) {
    space->theme = *theme;
    dirty_ = true;
  }
  return true;
}

bool Store::MoveSpace(const std::string& space_id, size_t index) {
  auto& spaces = state_.spaces;
  const auto source = std::find_if(spaces.begin(), spaces.end(),
      [&space_id](const Space& space) { return space.id == space_id; });
  if (source == spaces.end()) {
    return false;
  }
  const auto target = spaces.begin() +
      static_cast<std::ptrdiff_t>(std::min(index, spaces.size() - 1));
  if (source < target) {
    std::rotate(source, source + 1, target + 1);
  } else if (source > target) {
    std::rotate(target, source, source + 1);
  } else {
    return true;
  }
  dirty_ = true;
  return true;
}

bool Store::SetSeparateLogins(const std::string& space_id, bool separate) {
  Space* space = MutableSpace(space_id);
  if (!space) {
    return false;
  }
  if (separate != space->profile_id.has_value()) {
    space->profile_id = separate ? std::optional{NewUuid()} : std::nullopt;
    dirty_ = true;
  }
  return true;
}

std::string Store::AddFolder(const std::string& space_id,
                             const std::string& title,
                             const std::string& parent_folder_id) {
  Space* space = MutableSpace(space_id);
  if (!space) {
    return {};
  }
  std::vector<Item>* list = &space->pinned;
  if (!parent_folder_id.empty()) {
    Item* folder = FindInMutable(space->pinned, parent_folder_id);
    if (!folder || !folder->is_folder) {
      return {};
    }
    folder->expanded = true;
    list = &folder->children;
  }
  Item folder;
  folder.id = NewUuid();
  folder.is_folder = true;
  folder.title = title;
  folder.last_active = NowSeconds();
  list->push_back(std::move(folder));
  dirty_ = true;
  return list->back().id;
}

bool Store::SetFolderExpanded(const std::string& folder_id, bool expanded) {
  Item* folder = MutableItem(folder_id);
  if (!folder || !folder->is_folder) {
    return false;
  }
  if (folder->expanded != expanded) {
    folder->expanded = expanded;
    dirty_ = true;
  }
  return true;
}

bool Store::MoveItem(const std::string& item_id,
                     const SidebarDestination& destination,
                     std::optional<size_t> index) {
  const SidebarSection section = destination.section;
  std::vector<Item>* source = nullptr;
  if (IsFavorite(item_id)) {
    source = &state_.favorites;
  } else if (const Space* space = SpaceOf(item_id)) {
    Space* mutable_space = MutableSpace(space->id);
    source = FindIn(space->pinned, item_id) ? &mutable_space->pinned
                                           : &mutable_space->today;
  }
  if (!source || !MutableSidebarList(destination)) {
    return false;
  }

  Item* item = FindInMutable(*source, item_id);
  if (section != SidebarSection::kFavorites) {
    if (const Item* split = SplitWithPane(*source, item_id)) {
      item = FindInMutable(*source, split->id);
    }
  }
  if ((section == SidebarSection::kFavorites && !item->IsTab()) ||
      (section == SidebarSection::kToday && item->is_folder) ||
      (section == SidebarSection::kFolder &&
       (item->id == destination.folder_id ||
        FindIn(item->children, destination.folder_id)))) {
    return false;
  }

  Item moved;
  const std::string moving_id = item->id;
  RemoveFrom(*source, moving_id, &moved);
  // Erasing an item can shift the destination folder in its owning vector.
  auto& target = *MutableSidebarList(destination);
  UpdatePinnedAddresses(moved, section != SidebarSection::kToday);
  const size_t slot = std::min(index.value_or(target.size()), target.size());
  target.insert(target.begin() + static_cast<std::ptrdiff_t>(slot),
                std::move(moved));
  PruneSavedSelections();
  dirty_ = true;
  return true;
}

std::string Store::AddTab(const std::string& space_id, const std::string& url,
                          const std::string& title) {
  for (Space& sp : state_.spaces) {
    if (sp.id == space_id) {
      Item tab = Item::NewTab(bundled_page::Current(url), title);
      std::string id = tab.id;
      sp.today.insert(sp.today.begin(), std::move(tab));
      dirty_ = true;
      return id;
    }
  }
  return std::string();
}

Store::CloseResult Store::CloseTab(const std::string& item_id) {
  if (IsFavorite(item_id) || IsPinned(item_id)) {
    dirty_ = ResetPinnedAddress(*MutableItem(item_id)) || dirty_;
    return CloseResult::kKeptPinned;
  }
  // The supplied id may refer to an item erased by RemoveFrom.
  const std::string id = item_id;
  for (Space& sp : state_.spaces) {
    if (RemoveFrom(sp.today, id)) {
      PruneSavedSelections();
      dirty_ = true;
      return CloseResult::kRemoved;
    }
  }
  return CloseResult::kNotFound;
}

std::optional<std::string> Store::NeighbourAfterClose(
    const std::string& space_id, const std::string& item_id) const {
  const Space* sp = FindSpace(space_id);
  if (!sp) {
    return std::nullopt;
  }
  const std::vector<Item>& today = sp->today;
  for (size_t i = 0; i < today.size(); ++i) {
    bool here = today[i].id == item_id || FindIn(today[i].children, item_id);
    if (!here) {
      continue;
    }
    auto target = [](const Item& it) {
      return it.IsSplit() && !it.children.empty() ? it.children[0].id : it.id;
    };
    if (today[i].IsSplit() && today[i].children.size() > 1) {
      for (const Item& pane : today[i].children) {
        if (pane.id != item_id) {
          return pane.id;
        }
      }
    }
    if (i + 1 < today.size()) {
      return target(today[i + 1]);
    }
    if (i > 0) {
      return target(today[i - 1]);
    }
    return std::nullopt;
  }
  return std::nullopt;
}

void Store::UpdatePage(const std::string& item_id,
                       const std::optional<std::string>& url,
                       const std::optional<std::string>& title) {
  Item* it = MutableItem(item_id);
  if (!it) {
    return;
  }
  if (url && it->url != bundled_page::Saved(*url)) {
    it->url = bundled_page::Saved(*url);
    dirty_ = true;
  }
  if (title && it->title != *title) {
    it->title = *title;
    dirty_ = true;
  }
}

void Store::Touch(const std::string& item_id, int64_t now_seconds) {
  if (Item* it = MutableItem(item_id)) {
    it->last_active = now_seconds;
    dirty_ = true;
  }
}

std::vector<ArchivedTab> Store::ArchiveStale(
    int64_t now_seconds, double older_than_hours,
    const std::set<std::string>& protected_ids,
    std::vector<std::string>* removed_tab_ids) {
  std::vector<ArchivedTab> archived;
  if (removed_tab_ids) {
    removed_tab_ids->clear();
  }
  bool removed = false;
  for (Space& space : state_.spaces) {
    const auto can_archive = [&](const Item& tab) {
      return tab.IsTab() && !protected_ids.contains(tab.id) &&
             IsPastIdleLimit(tab.last_active, now_seconds, older_than_hours * 3600);
    };
    const auto archive_tab = [&](const Item& tab) {
      if (tab.url && IsWebAddress(*tab.url)) {
        archived.push_back({*tab.url, tab.DisplayTitle(), space.id, now_seconds});
      }
      if (removed_tab_ids) {
        removed_tab_ids->push_back(tab.id);
      }
    };
    std::erase_if(space.today, [&](const Item& entry) {
      if (entry.IsSplit()) {
        if (entry.children.empty() || protected_ids.contains(entry.id) ||
            !std::all_of(entry.children.begin(), entry.children.end(), can_archive)) {
          return false;
        }
        for (const Item& pane : entry.children) {
          archive_tab(pane);
        }
      } else {
        if (!can_archive(entry)) {
          return false;
        }
        archive_tab(entry);
      }
      removed = true;
      return true;
    });
  }
  if (removed) {
    PruneSavedSelections();
    dirty_ = true;
  }
  std::reverse(archived.begin(), archived.end());
  return archived;
}

Space* Store::MutableSpace(const std::string& space_id) {
  for (Space& space : state_.spaces) {
    if (space.id == space_id) {
      return &space;
    }
  }
  return nullptr;
}

std::vector<Item>* Store::MutableSidebarList(
    const SidebarDestination& destination) {
  if (destination.section == SidebarSection::kFavorites) {
    return &state_.favorites;
  }
  Space* space = MutableSpace(destination.space_id);
  if (!space) {
    return nullptr;
  }
  if (destination.section == SidebarSection::kPinned) {
    return &space->pinned;
  }
  if (destination.section == SidebarSection::kToday) {
    return &space->today;
  }
  Item* folder = FindInMutable(space->pinned, destination.folder_id);
  return folder && folder->is_folder ? &folder->children : nullptr;
}

void Store::PruneSavedSelections() {
  const auto valid = [&](const std::string& space_id, const std::string& item_id) {
    const Space* space = FindSpace(space_id);
    return space && (IsFavorite(item_id) || FindIn(space->pinned, item_id) ||
                     FindIn(space->today, item_id));
  };
  for (Space& space : state_.spaces) {
    if (space.selected_id && !valid(space.id, *space.selected_id)) {
      space.selected_id.reset();
    }
  }
  if (state_.windows) {
    for (BrowserWindowState& window : *state_.windows) {
      std::erase_if(window.selections, [&](const auto& selection) {
        return !valid(selection.first, selection.second);
      });
    }
  }
}

Item* Store::MutableItem(const std::string& item_id) {
  if (Item* f = FindInMutable(state_.favorites, item_id)) {
    return f;
  }
  for (Space& sp : state_.spaces) {
    if (Item* it = FindInMutable(sp.pinned, item_id)) {
      return it;
    }
    if (Item* it = FindInMutable(sp.today, item_id)) {
      return it;
    }
  }
  return nullptr;
}

}  // namespace birch::core

namespace birch::core {
void Store::SetSidebarCollapsed(bool collapsed) {
  if(state_.sidebar_collapsed!=collapsed) {state_.sidebar_collapsed=collapsed;dirty_=true;}
}
}
