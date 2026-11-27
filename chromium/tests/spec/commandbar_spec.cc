#include "tests/spec/commandbar_spec.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <set>

#include "core/bangs.h"
#include "core/codec.h"
#include "core/commands.h"
#include "core/keybindings.h"
#include "core/tab_recency.h"
#include "core/typed_url.h"

namespace birch::core::spec {

namespace {

std::string g_bangs_path;

// ---- SHA-256 (the bangs table check hashes 13,641 resolved lines) ----------
struct Sha256 {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  uint8_t buf[64];
  size_t used = 0;
  uint64_t total = 0;
  static uint32_t R(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
  void Block(const uint8_t* p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
      w[i] = static_cast<uint32_t>(p[i * 4]) << 24 | static_cast<uint32_t>(p[i * 4 + 1]) << 16 |
             static_cast<uint32_t>(p[i * 4 + 2]) << 8 | p[i * 4 + 3];
    }
    for (int i = 16; i < 64; ++i) {
      uint32_t s0 = R(w[i - 15], 7) ^ R(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = R(w[i - 2], 17) ^ R(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; ++i) {
      uint32_t t1 = hh + (R(e, 6) ^ R(e, 11) ^ R(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
      uint32_t t2 = (R(a, 2) ^ R(a, 13) ^ R(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  void Add(const std::string& s) {
    for (unsigned char c : s) {
      buf[used++] = c;
      ++total;
      if (used == 64) {
        Block(buf);
        used = 0;
      }
    }
  }
  std::string Hex() {
    uint64_t bits = total * 8;
    buf[used++] = 0x80;
    if (used > 56) {
      while (used < 64) buf[used++] = 0;
      Block(buf);
      used = 0;
    }
    while (used < 56) buf[used++] = 0;
    for (int i = 7; i >= 0; --i) buf[used++] = static_cast<uint8_t>(bits >> (i * 8));
    Block(buf);
    static const char kHex[] = "0123456789abcdef";
    std::string out;
    for (uint32_t v : h) {
      for (int i = 28; i >= 0; i -= 4) out += kHex[(v >> i) & 15];
    }
    return out;
  }
};

Bangs LoadBangs(const std::string& custom_text, bool has_custom) {
  Bangs b;
  std::string text;
  if (ReadFileUtf8Path(g_bangs_path, &text)) {
    b.Ingest(text);
  }
  if (has_custom) {
    b.Ingest(custom_text);
  }
  return b;
}

Json OptStr(const std::optional<std::string>& s) {
  return s ? Json(*s) : Json();
}

}  // namespace

void SetFixturesDir(const std::string& dir) {
  g_bangs_path = JoinPath(JoinPath(JoinPath(dir, ".."), ".."), "Resources/bangs.json");
}

std::vector<CaseOut> RunResolver(const Json& doc) {
  std::vector<CaseOut> out;
  Bangs bangs = LoadBangs("", false);
  for (const Json& cs : doc.at("cases")) {
    const Json in = cs["input"];
    if (in.contains("query")) {
      out.push_back({cs["name"].get<std::string>(), cs["expected"],
                     Json{{"search_url", SearchUrl(in["search_engine_url"].get<std::string>(),
                                                   in["query"].get<std::string>())}},
                     cs.contains("informative"), ""});
      continue;
    }
    std::string text = in["text"].get<std::string>();
    Json got;
    got["url_from_typed"] = OptStr(UrlFromTyped(text));
    got["destination"] = Destination(text, in["search_engine_url"].get<std::string>(), &bangs);
    out.push_back({cs["name"].get<std::string>(), cs["expected"], got,
                   cs.contains("informative"), ""});
  }
  return out;
}

std::vector<CaseOut> RunBangs(const Json& doc) {
  std::vector<CaseOut> out;
  for (const Json& cs : doc.at("cases")) {
    const Json in = cs["input"];
    bool has_custom = in.contains("custom_bangs_json_text") || in.contains("custom_bangs_json");
    std::string custom = in.contains("custom_bangs_json") ? in["custom_bangs_json"].dump()
                         : has_custom ? in["custom_bangs_json_text"].get<std::string>() : "";
    Bangs b = LoadBangs(custom, has_custom);
    std::optional<BangMatch> m = b.Resolve(in["text"].get<std::string>());
    Json got;
    got["matched"] = m.has_value();
    if (m) {
      got["name"] = m->bang.name;
      got["query"] = m->query;
      got["trigger"] = m->bang.trigger;
      got["url"] = m->url;
    }
    Json expected = cs["expected"];
    if (!m && expected.is_object() && expected.size() == 1) {
      // {"matched": false}
    }
    out.push_back({cs["name"].get<std::string>(), expected, got, cs.contains("informative"), ""});
  }
  // The whole table: every trigger resolved twice, hashed.
  if (doc.contains("table")) {
    const Json t = doc["table"];
    Bangs b = LoadBangs("", false);
    Sha256 sha;
    std::string tsv;
    for (const auto& e : b.table()) {
      auto with_query = b.Resolve("!" + e.first + " " + t["query"].get<std::string>());
      auto without = b.Resolve("!" + e.first);
      std::string line = e.first + "\t" + (with_query ? with_query->url : "-") + "\t" +
                         (without ? without->url : "-") + "\n";
      sha.Add(line);
      tsv += line;
    }
    if (const char* path = std::getenv("BIRCH_BANGS_TSV")) {  // for diffing against the Mac's file
      WriteFileAtomic(path, tsv);
    }
    Json expected = {{"trigger_count", t["trigger_count"]}, {"sha256", t["sha256"]}};
    Json got = {{"trigger_count", b.size()}, {"sha256", sha.Hex()}};
    out.push_back({"whole table: trigger count and SHA-256", expected, got, false, ""});
  }
  return out;
}

std::vector<CaseOut> RunKeybindings(const Json& doc) {
  std::vector<CaseOut> out;
  Keybindings kb(Keybindings::MacDefaults());
  std::string user_text = Keybindings::kEmptyUserFile;
  auto probe = [&](const Json& expected) {
    Json got = Json::object();
    if (expected.contains("command_on_stroke")) {
      Json m = Json::object();
      for (auto it = expected["command_on_stroke"].begin(); it != expected["command_on_stroke"].end(); ++it) {
        m[it.key()] = OptStr(kb.CommandOnStroke(it.key()));
      }
      got["command_on_stroke"] = m;
    }
    if (expected.contains("display_all")) {
      Json m = Json::object();
      for (auto it = expected["display_all"].begin(); it != expected["display_all"].end(); ++it) {
        m[it.key()] = kb.DisplayAll(it.key(), StrokeStyle::kMac);
      }
      got["display_all"] = m;
    }
    return got;
  };
  for (const Json& cs : doc.at("cases")) {
    const Json in = cs["input"];
    const Json expected = cs["expected"];
    const std::string name = cs["name"].get<std::string>();
    Json got = Json::object();
    if (in.contains("launch")) {
      Json file;
      ParseJson(kb.DefaultsFileText(), &file);
      // The Mac added find.next / find.previous (Cmd+G) after spec 2.0.0; the
      // fixture predates them (PARITY.md: regenerate on the Mac).
      file.erase("cmd+g");
      file.erase("cmd+shift+g");
      got["file"] = file;
      got["user_file_created"] = Keybindings::kEmptyUserFile;
    } else if (in.contains("stroke") && !in.contains("command")) {
      auto n = Keybindings::NormalizeStroke(in["stroke"].get<std::string>());
      got["normalized"] = OptStr(n);
      got["pretty"] = n ? Keybindings::Pretty(*n, StrokeStyle::kMac) : "";
    } else if (in.contains("sequence")) {
      got["normalized"] = Keybindings::NormalizeSequence(in["sequence"].get<std::string>());
    } else if (in.contains("keybindings_json_text")) {
      user_text = in["keybindings_json_text"].get<std::string>();
      kb.Reload(user_text);
      got = probe(expected);
    } else if (in.contains("command")) {
      std::optional<std::string> stroke;
      if (!in["stroke"].is_null()) stroke = in["stroke"].get<std::string>();
      user_text = kb.SetShortcut(stroke, in["command"].get<std::string>(), user_text);
      kb.Reload(user_text);
      got = probe(expected);
      Json after;
      ParseJson(user_text, &after);
      got["user_file_after"] = after;
    } else if (in.contains("reset")) {
      user_text = "{}\n";
      kb.Reload(user_text);
      got["user_file_after"] = Json::object();
    }
    out.push_back({name, expected, got, cs.contains("informative"), ""});
  }
  // The commands list is the fixture's.
  Json ids = Json::array();
  for (const Json& c : doc["commands"]) {
    ids.push_back({{"id", c["id"]}, {"title", c["title"]}});
  }
  Json mine = Json::array();
  for (const CommandInfo& c : AllCommands()) {
    if (std::string(c.id) == "find.next" || std::string(c.id) == "find.previous") continue;  // newer than the fixture
    mine.push_back({{"id", c.id}, {"title", c.title}});
  }
  out.push_back({"command ids and titles", ids, mine, false, ""});
  return out;
}

namespace {

void FlattenItem(const Json& item, std::vector<std::string>* order) {
  if (item.is_string()) {
    order->push_back(item.get<std::string>());
  } else if (item.contains("children")) {
    for (const Json& c : item["children"]) FlattenItem(c, order);
  } else if (item.contains("split")) {
    for (const Json& c : item["split"]) FlattenItem(c, order);
  }
}

}  // namespace

std::vector<CaseOut> RunTabRecency(const Json& doc) {
  std::vector<CaseOut> out;
  for (const Json& cs : doc.at("cases")) {
    const Json in = cs["input"];
    const Json side = in["sidebar_before"];
    std::vector<std::string> order;
    std::set<std::string> pinned;
    for (const Json& i : side["favorites"]) FlattenItem(i, &order);
    for (const Json& i : side["favorites"]) pinned.insert(i.get<std::string>());
    for (const Json& i : side["pinned"]) {
      std::vector<std::string> ids;
      FlattenItem(i, &ids);
      for (const std::string& id : ids) {
        order.push_back(id);
        pinned.insert(id);
      }
    }
    for (const Json& i : side["today"]) FlattenItem(i, &order);

    const int64_t base = 1000000000;
    std::map<std::string, int64_t> last;
    std::set<std::string> open;
    std::optional<std::string> selected;
    if (!side["selected"].is_null()) {
      selected = side["selected"].get<std::string>();
      open.insert(*selected);
    }
    int64_t tick = 0;
    auto idle = [&](const std::string& id) {
      double minutes = in["idle_minutes_default"].get<double>();
      if (in["idle_minutes"].contains(id)) minutes = in["idle_minutes"][id].get<double>();
      return base - static_cast<int64_t>(minutes * 60);
    };
    for (const std::string& id : order) last[id] = idle(id);
    for (const Json& id : in["loaded_without_visit"]) open.insert(id.get<std::string>());

    TabRecency rec;
    auto select = [&](const std::optional<std::string>& previous, const std::string& id) {
      rec.NoteSelected(previous, id);
      selected = id;
      open.insert(id);
      last[id] = base + ++tick;
    };
    for (const Json& v : in["visits_in_order"]) select(selected, v.get<std::string>());

    const bool use_recency = in["controlTabUsesRecency"].get<bool>();
    Json steps = Json::array();
    for (const Json& s : in["steps"]) {
      const std::string step = s.get<std::string>();
      CycleContext ctx;
      ctx.order = order;
      ctx.open = open;
      ctx.last_active = last;
      ctx.selected = selected;
      if (step == "press" || step == "shift-press" || step == "menu-next") {
        auto target = rec.Press(ctx, step != "shift-press", step != "menu-next", use_recency);
        if (target) select(selected, *target);
      } else if (step == "release") {
        rec.End();
      } else if (step.rfind("click ", 0) == 0) {
        rec.End();
        select(selected, step.substr(6));
      } else if (step.rfind("close ", 0) == 0) {
        std::string id = step.substr(6);
        rec.End();
        if (pinned.count(id)) {
          open.erase(id);  // a pinned tab sleeps
        } else {
          auto at = std::find(order.begin(), order.end(), id);
          std::optional<std::string> next;
          if (at != order.end()) {
            if (at != order.begin()) next = *(at - 1);
            else if (at + 1 != order.end()) next = *(at + 1);
            order.erase(at);
          }
          open.erase(id);
          rec.Forget(id);
          if (selected == id) {
            selected.reset();
            if (next) select(std::nullopt, *next);
          }
        }
      }
      steps.push_back({{"step", step},
                       {"selected", OptStr(selected)},
                       {"switcher", rec.switcher()}});
    }
    out.push_back({cs["name"].get<std::string>(), cs["expected"],
                   Json{{"after_each_step", steps}}, false, ""});
  }
  return out;
}

}  // namespace birch::core::spec
