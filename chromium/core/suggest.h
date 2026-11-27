// What the command bar lists for typed text (CommandBar.swift ▸ compute),
// engine-free: open tabs, bangs, addresses, history, commands. Search
// suggestions from the search engine's own servers are NOT built (the setting
// exists; the Chromium edition makes no such request yet, so the setting has
// no effect and no new network destination exists).
//
// Owner: wave-3 agent 6 (cx-commandbar).
#ifndef BIRCH_CORE_SUGGEST_H_
#define BIRCH_CORE_SUGGEST_H_

#include <cstdint>
#include <string>
#include <vector>

#include "core/archive_history.h"
#include "core/bangs.h"

namespace birch::core {

struct SuggestTab {
  std::string id;
  std::string title;
  std::string url;
  std::string place;  // "● Space name" or "Favorites"
  int64_t last_active = 0;
};

struct SuggestCommand {
  std::string id, title, hint;  // hint = its shortcut, readable
};

struct SuggestInput {
  std::string text;
  std::string search_engine_name = "DuckDuckGo";
  std::string search_template = "https://duckduckgo.com/?q=%s";
  const Bangs* bangs = nullptr;
  std::string selected_id;  // the tab on screen (left out of the lists)
  std::vector<SuggestTab> tabs;      // every tab in every space
  std::vector<std::string> recent;   // tab ids the empty bar offers, in order
  std::vector<HistoryEntry> history;
  std::vector<SuggestCommand> commands;  // the commands this window can run
  int64_t now = 0;
};

struct SuggestResult {
  enum class Action { kGo, kTab, kCommand };
  std::string key;
  std::string kind;  // tab bang address search url command
  std::string title, subtitle, hint;
  Action action = Action::kGo;
  std::string target;  // URL, tab id or command id
};

constexpr size_t kMaxSuggestions = 11;
std::vector<SuggestResult> Suggest(const SuggestInput& input);

// History.search / topHostMatch of the Mac (Data.swift), for the bar only.
std::vector<HistoryEntry> SearchHistory(const std::vector<HistoryEntry>& all,
                                        const std::string& query, size_t limit,
                                        int64_t now);

}  // namespace birch::core

#endif  // BIRCH_CORE_SUGGEST_H_
