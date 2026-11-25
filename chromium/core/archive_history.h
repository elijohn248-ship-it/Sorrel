// archive.json and history.json file formats (spec/saved-data.md; fixture
// archive-history-decode). Only the formats live here; behaviour (what gets
// recorded, ranking, trimming) belongs to wave-3 agent 8, who also owns this
// file.
#ifndef BIRCH_CORE_ARCHIVE_HISTORY_H_
#define BIRCH_CORE_ARCHIVE_HISTORY_H_

#include <cstdint>
#include <string>
#include <vector>

namespace birch::core {

struct ArchivedTab {
  std::string url;
  std::string title;
  std::string space_id;
  int64_t date = 0;  // when archived
};

struct HistoryEntry {
  std::string url;
  std::string title;
  int64_t visits = 0;
  int64_t last = 0;
};

bool DecodeArchive(const std::string& text, std::vector<ArchivedTab>* out,
                   std::string* error);
std::string EncodeArchive(const std::vector<ArchivedTab>& list);
bool DecodeHistory(const std::string& text, std::vector<HistoryEntry>* out,
                   std::string* error);
std::string EncodeHistory(const std::vector<HistoryEntry>& list);

}  // namespace birch::core

#endif  // BIRCH_CORE_ARCHIVE_HISTORY_H_
