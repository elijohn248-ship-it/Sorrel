#include "core/tab_recency.h"

#include <algorithm>

namespace birch::core {

void TabRecency::NoteSelected(const std::optional<std::string>& previous,
                              const std::string& now) {
  auto drop = [this](const std::string& id) {
    recent_.erase(std::remove(recent_.begin(), recent_.end(), id), recent_.end());
  };
  std::vector<std::string> front = {now};
  drop(now);
  if (previous && !previous->empty() && *previous != now) {
    drop(*previous);
    front.push_back(*previous);
  }
  recent_.insert(recent_.begin(), front.begin(), front.end());
}

void TabRecency::Forget(const std::string& id) {
  recent_.erase(std::remove(recent_.begin(), recent_.end(), id), recent_.end());
}

void TabRecency::End() {
  active_ = false;
  cycle_.clear();
  switcher_.clear();
  index_ = 0;
}

std::optional<std::string> TabRecency::Press(const CycleContext& c, bool forward,
                                             bool holding, bool use_recency) {
  if (active_ && !holding) {
    End();
  }
  if (!active_) {
    std::vector<std::string> list;
    auto add = [&](const std::string& id) {
      if (c.open.count(id) &&
          std::find(list.begin(), list.end(), id) == list.end()) {
        list.push_back(id);
      }
    };
    if (use_recency) {
      if (c.selected) {
        add(*c.selected);
      }
      for (const std::string& id : recent_) {
        add(id);
      }
      std::vector<std::string> rest;
      for (const std::string& id : c.order) {
        if (c.open.count(id) &&
            std::find(list.begin(), list.end(), id) == list.end()) {
          rest.push_back(id);
        }
      }
      std::stable_sort(rest.begin(), rest.end(),
                       [&c](const std::string& a, const std::string& b) {
                         auto la = c.last_active.find(a), lb = c.last_active.find(b);
                         int64_t va = la == c.last_active.end() ? 0 : la->second;
                         int64_t vb = lb == c.last_active.end() ? 0 : lb->second;
                         return va > vb;
                       });
      for (const std::string& id : rest) {
        add(id);
      }
    } else {
      for (const std::string& id : c.order) {
        add(id);
      }
    }
    if (list.empty()) {
      return std::nullopt;
    }
    size_t start = 0;
    bool found = false;
    if (c.selected) {
      for (size_t i = 0; i < list.size(); ++i) {
        if (list[i] == *c.selected) {
          start = i;
          found = true;
        }
      }
    }
    cycle_ = list;
    index_ = start;
    active_ = true;
    // No selection among the open tabs: the first press lands on the first.
    if (!found) {
      if (forward) {
        index_ = list.size() - 1;
      } else {
        index_ = 0;
      }
    }
  }
  const size_t n = cycle_.size();
  std::optional<std::string> target;
  for (size_t step = 0; step < n; ++step) {
    index_ = forward ? (index_ + 1) % n : (index_ + n - 1) % n;
    const std::string& id = cycle_[index_];
    if (c.open.count(id)) {  // tabs that disappeared mid-cycle are skipped
      target = id;
      break;
    }
  }
  if (!target) {
    End();
    return std::nullopt;
  }
  if (holding) {
    switcher_ = cycle_;
  } else {
    End();
  }
  return target;
}

}  // namespace birch::core
