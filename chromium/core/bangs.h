// Bangs ("!w cats"), per spec/address-and-search.md ▸ Bangs. The bundled list
// is Resources/bangs.json (the Mac app's file, copied beside the executable
// at build time); the person's own bangs.json overrides it. Pure data and
// string work: nothing here reads the network.
//
// Owner: wave-3 agent 6 (cx-commandbar).
#ifndef BIRCH_CORE_BANGS_H_
#define BIRCH_CORE_BANGS_H_

#include <map>
#include <optional>
#include <string>

namespace birch::core {

struct Bang {
  std::string trigger;  // lowercase
  std::string name;
  std::string domain;
  std::string tmpl;  // "{{{s}}}" marks the query
  std::optional<bool> space_to_plus;
};

struct BangMatch {
  Bang bang;
  std::string query;
  std::string url;
};

class Bangs {
 public:
  // Adds the entries of one bangs.json text (a JSON array). Later entries
  // replace earlier ones with the same trigger. Unreadable text adds nothing.
  void Ingest(const std::string& json_text);
  void Clear() { table_.clear(); }
  size_t size() const { return table_.size(); }
  const std::map<std::string, Bang>& table() const { return table_; }

  // The first "!trigger" word and the rest as the query, or nullopt.
  std::optional<BangMatch> Resolve(const std::string& text) const;

 private:
  std::map<std::string, Bang> table_;  // keyed by trigger, byte order
};

// Percent-encodes everything except A-Z a-z 0-9 - . _ ~ (UTF-8 bytes of
// other characters too, which is what the final URL holds on the Mac).
// |space_to_plus| then turns "%20" into "+".
std::string EncodeQuery(const std::string& query, bool space_to_plus);

// The address string as Apple's URL(string:) writes it (see bangs.cc). Used
// for every address the resolver produces, so editions load the same page.
std::string NormalizeUrl(const std::string& url);

// The one table the app uses (bundled list, then the person's file).
Bangs& SharedBangs();

}  // namespace birch::core

#endif  // BIRCH_CORE_BANGS_H_
