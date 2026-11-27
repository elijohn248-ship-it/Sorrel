#include "core/suggest.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>

#include "core/codec.h"
#include "core/typed_url.h"

namespace birch::core {

namespace {

std::string HostOfUrl(const std::string& url) {
  size_t s = url.find("://");
  if (s == std::string::npos) {
    return "";
  }
  size_t start = s + 3;
  size_t end = url.find_first_of("/?#", start);
  std::string host = url.substr(start, end == std::string::npos ? end : end - start);
  size_t at = host.rfind('@');
  if (at != std::string::npos) host = host.substr(at + 1);
  size_t colon = host.rfind(':');
  if (colon != std::string::npos) host = host.substr(0, colon);
  return host;
}

std::string HostNoWww(const std::string& url) {
  std::string host = ToLowerAscii(HostOfUrl(url));
  size_t pos;
  while ((pos = host.find("www.")) != std::string::npos) {  // Swift replaces all
    host.erase(pos, 4);
  }
  return host;
}

std::vector<std::string> Words(const std::string& lower) {
  std::vector<std::string> out;
  for (const std::string& w : Split(lower, ' ')) {
    if (!w.empty()) out.push_back(w);
  }
  return out;
}

bool Contains(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

}  // namespace

std::vector<HistoryEntry> SearchHistory(const std::vector<HistoryEntry>& all,
                                        const std::string& query, size_t limit,
                                        int64_t now) {
  std::vector<std::string> words = Words(ToLowerAscii(query));
  if (words.empty()) return {};
  std::vector<std::pair<double, const HistoryEntry*>> scored;
  for (const HistoryEntry& e : all) {
    std::string u = ToLowerAscii(e.url), t = ToLowerAscii(e.title);
    bool ok = true;
    for (const std::string& w : words) {
      if (!Contains(u, w) && !Contains(t, w)) ok = false;
    }
    if (!ok) continue;
    double days = static_cast<double>(now - e.last) / 86400.0;
    double score = std::log(static_cast<double>(e.visits) + 1) * 2 + std::max(0.0, 5 - days / 7);
    std::string host = HostNoWww(e.url);
    if (host.rfind(words[0], 0) == 0) {
      score += 6;
      std::string rest;
      size_t s = e.url.find("://");
      size_t slash = s == std::string::npos ? s : e.url.find('/', s + 3);
      rest = slash == std::string::npos ? "/" : e.url.substr(slash);
      size_t cut = rest.find_first_of("?#");
      if (cut != std::string::npos) rest = rest.substr(0, cut);
      if (rest.size() <= 1) score += 4;
    }
    scored.emplace_back(score, &e);
  }
  std::stable_sort(scored.begin(), scored.end(),
                   [](const auto& a, const auto& b) { return a.first > b.first; });
  std::vector<HistoryEntry> out;
  for (size_t i = 0; i < scored.size() && i < limit; ++i) out.push_back(*scored[i].second);
  return out;
}

std::vector<SuggestResult> Suggest(const SuggestInput& in) {
  std::vector<SuggestResult> out;
  auto find_tab = [&](const std::string& id) -> const SuggestTab* {
    for (const SuggestTab& t : in.tabs) if (t.id == id) return &t;
    return nullptr;
  };
  auto tab_row = [&](const SuggestTab& t, const std::string& subtitle) {
    SuggestResult r;
    r.key = "tab:" + t.id;
    r.kind = "tab";
    r.title = t.title.empty() ? t.url : t.title;
    r.subtitle = subtitle;
    r.hint = "Switch to Tab";
    r.action = SuggestResult::Action::kTab;
    r.target = t.id;
    return r;
  };
  std::string q = TrimSpaces(in.text);
  if (q.empty()) {
    size_t n = 0;
    for (const std::string& id : in.recent) {
      const SuggestTab* t = find_tab(id);
      if (!t || t->id == in.selected_id) continue;
      out.push_back(tab_row(*t, HostOfUrl(t->url)));
      if (++n == 6) break;
    }
    return out;
  }
  SuggestResult search;
  search.key = "search";
  search.kind = "search";
  search.title = q;
  search.subtitle = "Search " + in.search_engine_name;
  search.action = SuggestResult::Action::kGo;
  search.target = SearchUrl(in.search_template, q);
  std::set<std::string> seen;
  std::optional<BangMatch> bang;
  if (in.bangs) bang = in.bangs->Resolve(q);
  std::optional<std::string> typed = UrlFromTyped(q);
  if (bang) {
    SuggestResult r;
    r.key = "bang";
    r.kind = "bang";
    r.title = bang->query.empty() ? "Open " + bang->bang.name
                                  : "Search " + bang->bang.name + " for \xE2\x80\x9C" + bang->query + "\xE2\x80\x9D";
    r.subtitle = HostOfUrl(bang->url);
    r.hint = "!" + bang->bang.trigger;
    r.target = bang->url;
    out.push_back(r);
  } else if (typed) {
    SuggestResult r;
    r.key = "address";
    r.kind = "address";
    r.title = q;
    r.subtitle = "Open address";
    r.target = *typed;
    out.push_back(r);
    seen.insert(*typed);
    out.push_back(search);
  } else {
    // The best-visited page whose host starts with the text.
    std::string lower = ToLowerAscii(q);
    if (lower.size() >= 2 && lower.find(' ') == std::string::npos) {
      for (const HistoryEntry& e : SearchHistory(in.history, lower, 5, in.now)) {
        if (HostNoWww(e.url).rfind(lower, 0) == 0) {
          SuggestResult r;
          r.key = "url:" + e.url;
          r.kind = "url";
          r.title = e.title.empty() ? e.url : e.title;
          r.subtitle = HostOfUrl(e.url);
          r.target = e.url;
          out.push_back(r);
          seen.insert(e.url);
          break;
        }
      }
    }
    out.push_back(search);
  }
  std::vector<std::string> words = Words(ToLowerAscii(q));
  auto matches = [&](const std::vector<std::string>& strings) {
    std::string hay;
    for (const std::string& s : strings) hay += (hay.empty() ? "" : " ") + s;
    hay = ToLowerAscii(hay);
    for (const std::string& w : words) if (!Contains(hay, w)) return false;
    return true;
  };
  size_t shown = 0;
  for (const SuggestTab& t : in.tabs) {
    if (shown == 4) break;
    if (!matches({t.title, t.url}) || t.id == in.selected_id) continue;
    out.push_back(tab_row(t, t.place));
    seen.insert(t.url);
    ++shown;
  }
  for (const HistoryEntry& e : SearchHistory(in.history, q, 6, in.now)) {
    if (seen.count(e.url)) continue;
    SuggestResult r;
    r.key = "url:" + e.url;
    r.kind = "url";
    r.title = e.title.empty() ? e.url : e.title;
    r.subtitle = HostOfUrl(e.url);
    r.target = e.url;
    out.push_back(r);
    if (out.size() >= 9) break;
  }
  shown = 0;
  for (const SuggestCommand& c : in.commands) {
    if (shown == 4) break;
    if (!matches({c.title})) continue;
    SuggestResult r;
    r.key = "cmd:" + c.id;
    r.kind = "command";
    r.title = c.title;
    r.subtitle = "Command";
    r.hint = c.hint;
    r.action = SuggestResult::Action::kCommand;
    r.target = c.id;
    out.push_back(r);
    ++shown;
  }
  std::set<std::string> used;  // row keys: unique, stable per target, opaque
  for (SuggestResult& r : out) {
    uint32_t h = 2166136261u;  // FNV-1a of the key: the page never sees addresses or ids
    for (unsigned char c : r.key) h = (h ^ c) * 16777619u;
    char hex[9];
    std::snprintf(hex, sizeof hex, "%08x", h);
    r.key = r.kind + ":" + hex;
    std::string k = r.key;
    int n = 1;
    while (used.count(k)) k = r.key + "#" + std::to_string(++n);
    used.insert(k);
    r.key = k;
  }
  if (out.size() > kMaxSuggestions) out.resize(kMaxSuggestions);
  return out;
}

}  // namespace birch::core
