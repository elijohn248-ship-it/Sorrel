#include "core/store.h"

#include <set>

#include "core/codec.h"

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

// Removes the tab |id| from |items| (at any depth). A split left with one
// pane dissolves into that tab.
bool RemoveFrom(std::vector<Item>& items, const std::string& id) {
  for (size_t i = 0; i < items.size(); ++i) {
    if (items[i].id == id) {
      items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
      return true;
    }
    if (RemoveFrom(items[i].children, id)) {
      if (items[i].IsSplit() && items[i].children.size() == 1) {
        Item only = items[i].children[0];
        items[i] = only;
      }
      return true;
    }
  }
  return false;
}

void AddRows(const std::vector<Item>& items, SidebarRow::Kind kind, int depth,
             std::vector<SidebarRow>* rows) {
  for (const Item& it : items) {
    SidebarRow row;
    row.item_id = it.id;
    row.title = it.DisplayTitle();
    row.depth = depth;
    if (it.is_folder) {
      row.kind = SidebarRow::Kind::kFolder;
      rows->push_back(row);
      if (it.expanded) {
        AddRows(it.children, kind, depth + 1, rows);
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

std::vector<SidebarRow> Store::SidebarRows(const std::string& space_id) const {
  std::vector<SidebarRow> rows;
  AddRows(state_.favorites, SidebarRow::Kind::kFavorite, 0, &rows);
  const Space* sp = FindSpace(space_id);
  if (!sp) {
    return rows;
  }
  AddRows(sp->pinned, SidebarRow::Kind::kPinned, 0, &rows);
  SidebarRow sep;
  sep.kind = SidebarRow::Kind::kSeparator;
  rows.push_back(sep);
  AddRows(sp->today, SidebarRow::Kind::kToday, 0, &rows);
  return rows;
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
  if (IsFavorite(item_id)) {
    return CloseResult::kKeptPinned;
  }
  for (Space& sp : state_.spaces) {
    if (FindIn(sp.pinned, item_id)) {
      return CloseResult::kKeptPinned;
    }
    if (RemoveFrom(sp.today, item_id)) {
      if (sp.selected_id == item_id) {
        sp.selected_id.reset();
      }
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
