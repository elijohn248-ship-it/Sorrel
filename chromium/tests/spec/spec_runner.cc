// Loads spec/fixtures/*.json and checks core/ against every case it covers
// (spec/README.md ▸ How an edition proves it matches). Engine-free: builds and
// runs without CEF, on Windows, Linux and (for local checks) macOS.
//
//   birch_spec_tests <path to spec/fixtures>
//
// One line per case: "spec: <fixture> <name> expected=… got=… -> PASS|FAIL|
// INFO", a summary per fixture, and exit code 1 on any non-informative
// failure. Fixtures for areas that later agents implement are listed as not
// covered, with their owner; add a handler here when you implement one.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <map>
#include <random>
#include <string>
#include <vector>

#include "core/archive_history.h"
#include "core/codec.h"
#include "core/json.h"
#include "core/model.h"
#include "core/settings.h"
#include "core/site.h"
#include "core/state_file.h"

namespace birch::core {
namespace {

constexpr const char kSpecMajor[] = "2.";

int g_total_pass = 0, g_total_fail = 0, g_total_info = 0;

std::string Short(const Json& v, size_t limit = 160) {
  std::string s = v.dump(-1, ' ', false, Json::error_handler_t::replace);
  if (s.size() > limit) {
    s = s.substr(0, limit) + "...";
  }
  return s;
}

// Numbers compare with a tiny tolerance (the spec's 1e-6 is for theme floats;
// everything core covers is exact, so 1e-9 relative is ample).
bool Equal(const Json& a, const Json& b, std::string* where,
           const std::string& path = "") {
  if (a.is_number() && b.is_number()) {
    double x = a.get<double>(), y = b.get<double>();
    if (std::fabs(x - y) <= 1e-9 * std::max(1.0, std::fabs(x))) {
      return true;
    }
    *where = path;
    return false;
  }
  if (a.type() != b.type()) {
    *where = path;
    return false;
  }
  if (a.is_object()) {
    if (a.size() != b.size()) {
      *where = path + " (keys differ)";
      return false;
    }
    for (auto it = a.begin(); it != a.end(); ++it) {
      auto other = b.find(it.key());
      if (other == b.end()) {
        *where = path + "." + it.key() + " (missing)";
        return false;
      }
      if (!Equal(it.value(), *other, where, path + "." + it.key())) {
        return false;
      }
    }
    return true;
  }
  if (a.is_array()) {
    if (a.size() != b.size()) {
      *where = path + " (length)";
      return false;
    }
    for (size_t i = 0; i < a.size(); ++i) {
      if (!Equal(a[i], b[i], where, path + "[" + std::to_string(i) + "]")) {
        return false;
      }
    }
    return true;
  }
  if (a != b) {
    *where = path;
    return false;
  }
  return true;
}

struct Counts {
  int pass = 0, fail = 0, info = 0;
};

void Report(const std::string& fixture, const std::string& name,
            const Json& expected, const Json& got, bool informative,
            Counts* c, const std::string& note = "") {
  std::string where;
  bool ok = Equal(expected, got, &where);
  const char* verdict = ok ? "PASS" : (informative ? "INFO" : "FAIL");
  size_t limit = ok ? 160 : 4000;
  std::printf("spec: %s %s expected=%s got=%s -> %s%s%s\n", fixture.c_str(),
              name.c_str(), Short(expected, limit).c_str(),
              Short(got, limit).c_str(), verdict,
              ok ? "" : (" (first difference at " + where + ")").c_str(),
              note.empty() ? "" : ("  [" + note + "]").c_str());
  if (ok) {
    c->pass++;
  } else if (informative) {
    c->info++;
  } else {
    c->fail++;
  }
}

// ---- scratch folders -----------------------------------------------------------

std::string ScratchDir() {
  std::random_device rd;
  std::filesystem::path p = std::filesystem::temp_directory_path() /
                            ("birch-spec-" + std::to_string(rd()) +
                             std::to_string(rd()));
  std::error_code ec;
  std::filesystem::create_directories(p, ec);
  return p.string();
}

void RemoveDir(const std::string& dir) {
  std::error_code ec;
  std::filesystem::remove_all(dir, ec);
}

std::vector<std::string> FilesStartingWith(const std::string& dir,
                                           const std::string& prefix) {
  std::vector<std::string> out;
  std::error_code ec;
  for (const auto& e : std::filesystem::directory_iterator(dir, ec)) {
    std::string n = e.path().filename().string();
    if (StartsWith(n, prefix)) {
      out.push_back(e.path().string());
    }
  }
  return out;
}

Json ParseOrNull(const std::string& text) {
  Json v;
  return ParseJson(text, &v) ? v : Json();
}

std::string InputText(const Json& input, const char* object_key,
                      const char* text_key) {
  if (input.contains(text_key)) {
    return input[text_key].is_string() ? input[text_key].get<std::string>()
                                       : std::string();
  }
  return input[object_key].dump();
}

// ---- handlers --------------------------------------------------------------------

const char kSeedWords[] =
    "seed fresh profile; copy file to state.unreadable-<unix time>.json";

void StateDecode(const std::string& fx, const Json& doc, Counts* c) {
  for (const Json& cs : doc["cases"]) {
    const std::string name = cs["name"].get<std::string>();
    const Json& exp = cs["expected"];
    std::string text = InputText(cs["input"], "state_json", "state_json_text");
    AppState s;
    std::string error;
    bool decodes = DecodeAppState(text, &s, &error);
    Json got = Json::object();
    got["decodes"] = decodes;
    got["reencoded"] = decodes ? ParseOrNull(EncodeAppState(s)) : Json();
    // Launch rule, on a real scratch profile folder.
    std::string dir = ScratchDir();
    WriteFileAtomic(JoinPath(dir, kStateFileName), text);
    LaunchState launch = LoadStateOnLaunch(dir);
    std::string backup_ok = "no backup";
    if (!launch.used_file) {
      std::vector<std::string> backups =
          FilesStartingWith(dir, "state.unreadable-");
      std::string copy;
      if (backups.size() == 1 && ReadFileUtf8Path(backups[0], &copy) &&
          copy == text) {
        backup_ok = "backup identical";
      }
    }
    got["store_on_launch"] =
        launch.used_file ? "use"
                         : (backup_ok == "backup identical" ? kSeedWords
                                                            : "seed without backup");
    RemoveDir(dir);
    Json expected = Json::object();
    expected["decodes"] = exp["decodes"];
    expected["reencoded"] = exp["reencoded"];
    expected["store_on_launch"] = exp["store_on_launch"];
    std::string note = "error expected=" + Short(exp["error"]) +
                       " got=" + (decodes ? "null" : "\"" + error + "\"");
    Report(fx, name, expected, got, cs.value("informative", false), c, note);
  }
  // The complete file Birch writes decodes and re-encodes to itself.
  AppState s;
  std::string error;
  bool ok = DecodeAppState(doc["written_by_birch"].dump(), &s, &error);
  Report(fx, "written_by_birch round trip", doc["written_by_birch"],
         ok ? ParseOrNull(EncodeAppState(s)) : Json(error), false, c);
}

void StateDerived(const std::string& fx, const Json& doc, Counts* c) {
  for (const Json& cs : doc["cases"]) {
    const std::string name = cs["name"].get<std::string>();
    const Json& in = cs["input"];
    Json got = Json::object();
    if (in.contains("item")) {
      Item item;
      std::string error;
      got["displayTitle"] =
          DecodeItem(in["item"].dump(), &item, &error) ? Json(item.DisplayTitle())
                                                       : Json("decode error: " + error);
    } else if (in.contains("fractions")) {
      SplitLayout split;
      for (const Json& f : in["fractions"]) {
        split.fractions.push_back(f.get<double>());
      }
      got["normalized"] =
          split.Normalized(static_cast<size_t>(in["count"].get<int64_t>()));
    } else if (in.contains("address")) {
      std::string a = in["address"].get<std::string>();
      got["current"] = bundled_page::Current(a);
      got["isBundled"] = bundled_page::IsBundled(a);
    } else if (in.contains("name")) {
      got["plain_name_allowed"] =
          bundled_page::PlainNameAllowed(in["name"].get<std::string>());
    } else if (in.contains("profile")) {
      std::string dir = ScratchDir();
      LaunchState launch = LoadStateOnLaunch(dir);
      RemoveDir(dir);
      const AppState& st = launch.state;
      const Space& sp = st.spaces.front();
      got["current_space_is_home"] = st.current_space_id == sp.id;
      got["favorites_count"] = st.favorites.size();
      got["icon"] = sp.icon;
      got["name"] = sp.name;
      got["pinned_count"] = sp.pinned.size();
      got["profileID"] = sp.profile_id ? Json(*sp.profile_id) : Json();
      got["selected_is_first_today_tab"] =
          !sp.today.empty() && sp.selected_id == sp.today[0].id;
      got["space_count"] = st.spaces.size();
      Json theme = ParseOrNull(EncodeAppState(st))["spaces"][0]["theme"];
      got["theme"] = theme;
      Json today = Json::array();
      for (const Item& it : sp.today) {
        today.push_back({{"title", it.title}, {"url", it.url ? *it.url : ""}});
      }
      got["today"] = today;
    } else {
      got["unhandled input"] = in;
    }
    Report(fx, name, cs["expected"], got, cs.value("informative", false), c);
  }
}

Json SettingsJson(const Settings& s) { return ParseOrNull(EncodeSettings(s)); }

void SettingsFieldsFixture(const std::string& fx, const Json& doc, Counts* c) {
  Json defaults = SettingsJson(Settings());
  Settings missing;
  std::string error;
  DecodeSettings("{}", &missing, &error);
  Json decoded = SettingsJson(missing);
  std::map<std::string, std::string> types;
  for (const SettingsFieldInfo& f : SettingsFields()) {
    types[f.name] = f.swift_type;
  }
  std::vector<std::string> fixture_fields;
  for (const Json& cs : doc["cases"]) {
    const std::string field = cs["input"]["field"].get<std::string>();
    fixture_fields.push_back(field);
    Json got = Json::object();
    got["default"] = defaults.contains(field) ? defaults[field] : Json("absent");
    got["decoded_when_missing"] =
        decoded.contains(field) ? decoded[field] : Json("absent");
    got["swift_type"] = types.count(field) ? types[field] : "absent";
    Report(fx, cs["name"].get<std::string>(), cs["expected"], got,
           cs.value("informative", false), c);
  }
  Json want = Json(fixture_fields.size());
  Report(fx, "field count (no extra fields)", want, Json(types.size()), false,
         c);
}

void SettingsDecodeFixture(const std::string& fx, const Json& doc, Counts* c) {
  for (const Json& cs : doc["cases"]) {
    const Json& exp = cs["expected"];
    const Json& text = cs["input"]["settings_json_text"];
    std::string dir = ScratchDir();
    std::string path = JoinPath(dir, kSettingsFileName);
    if (text.is_string()) {
      WriteFileAtomic(path, text.get<std::string>());
    }
    SettingsLoad load = LoadSettings(dir);
    std::string after;
    ReadFileUtf8Path(path, &after);
    RemoveDir(dir);
    Json got = Json::object();
    Json expected = Json::object();
    for (auto it = exp.begin(); it != exp.end(); ++it) {
      const std::string& k = it.key();
      if (k == "decode_error") {
        // The wording is informative; only "none" vs "an error" must match.
        expected[k] = !it.value().is_null();
        got[k] = !load.decode_error.empty();
      } else if (k == "decoded") {
        expected[k] = it.value();
        got[k] = load.decoded ? SettingsJson(*load.decoded) : Json();
      } else if (k == "loaded") {
        expected[k] = it.value();
        got[k] = SettingsJson(load.loaded);
      } else if (k == "file_after_load") {
        expected[k] = it.value();
        got[k] = ParseOrNull(after);
      } else if (k == "file_rewritten") {
        expected[k] = it.value();
        got[k] = load.file_rewritten;
      }
    }
    std::string note = "error expected=" + Short(exp.value("decode_error", Json())) +
                       " got=\"" + load.decode_error + "\"";
    Report(fx, cs["name"].get<std::string>(), expected, got,
           cs.value("informative", false), c, note);
  }
}

void ArchiveHistoryFixture(const std::string& fx, const Json& doc, Counts* c) {
  for (const Json& cs : doc["cases"]) {
    const Json& in = cs["input"];
    const Json& exp = cs["expected"];
    std::string error;
    Json got = Json::object();
    bool ok = false;
    if (in.contains("archive_json")) {
      std::vector<ArchivedTab> list;
      ok = DecodeArchive(in["archive_json"].dump(), &list, &error);
      got["reencoded"] = ok ? ParseOrNull(EncodeArchive(list)) : Json();
    } else {
      std::vector<HistoryEntry> list;
      ok = DecodeHistory(in["history_json"].dump(), &list, &error);
      got["reencoded"] = ok ? ParseOrNull(EncodeHistory(list)) : Json();
    }
    got["decodes"] = ok;
    Json expected = {{"decodes", exp["decodes"]}, {"reencoded", exp["reencoded"]}};
    Report(fx, cs["name"].get<std::string>(), expected, got,
           cs.value("informative", false), c,
           "error expected=" + Short(exp["error"]) + " got=\"" + error + "\"");
  }
}

std::optional<std::string> OptStr(const Json& v) {
  if (v.is_string()) {
    return v.get<std::string>();
  }
  return std::nullopt;
}

Json FromOpt(const std::optional<std::string>& s) { return s ? Json(*s) : Json(); }

void SiteFixture(const std::string& fx, const Json& doc, Counts* c) {
  for (const Json& cs : doc["cases"]) {
    const Json& in = cs["input"];
    const Json& exp = cs["expected"];
    Json got = Json::object();
    if (exp.contains("key")) {
      got["key"] = FromOpt(SiteKey(OptStr(in["host"])));
    } else if (exp.contains("display")) {
      got["display"] = FromOpt(SiteDisplay(OptStr(in["host"])));
    } else if (exp.contains("is_in")) {
      std::vector<std::string> list;
      for (const Json& e : in["list"]) {
        list.push_back(e.get<std::string>());
      }
      got["is_in"] = SiteHostIsIn(OptStr(in["host"]), list);
    } else if (exp.contains("same")) {
      got["same"] = SiteSame(OptStr(in["a"]), OptStr(in["b"]));
    } else if (exp.contains("text")) {
      AddressBox box = AddressBoxFor(OptStr(in["url"]));
      got["text"] = FromOpt(box.text);
      got["host"] = FromOpt(box.host);
      got["not_secure_lock"] = box.not_secure_lock;
      got["can_copy"] = box.can_copy;
    }
    Report(fx, cs["name"].get<std::string>(), exp, got,
           cs.value("informative", false), c);
  }
}

using Handler = std::function<void(const std::string&, const Json&, Counts*)>;

int Run(const std::string& dir) {
  const std::map<std::string, Handler> covered = {
      {"state-decode", StateDecode},
      {"state-derived", StateDerived},
      {"settings-fields", SettingsFieldsFixture},
      {"settings-decode", SettingsDecodeFixture},
      {"archive-history-decode", ArchiveHistoryFixture},
      {"site", SiteFixture},
  };
  // Not implemented in wave 2; the agent named owns the code and the handler.
  const std::map<std::string, std::string> later = {
      {"resolver", "agent 6 (cx-commandbar)"},
      {"bangs", "agent 6 (cx-commandbar)"},
      {"keybindings", "agent 6 (cx-commandbar)"},
      {"tab-recency", "agent 6 (cx-commandbar)"},
      {"theme", "agent 5 (cx-spaces-sidebar)"},
      {"theme-math", "agent 5 (cx-spaces-sidebar)"},
      {"tab-lifecycle", "agent 5 (cx-spaces-sidebar)"},
      {"https-first", "agent 7 (cx-privacy-extensions)"},
      {"url-cleaner", "agent 7 (cx-privacy-extensions)"},
      {"peek", "agent 8 (cx-peek-split-library)"},
      {"split-view", "agent 8 (cx-peek-split-library)"},
      {"history-behaviour", "agent 8 (cx-peek-split-library)"},
  };
  std::vector<std::string> files;
  std::error_code ec;
  for (const auto& e : std::filesystem::directory_iterator(dir, ec)) {
    if (e.path().extension() == ".json") {
      files.push_back(e.path().string());
    }
  }
  std::sort(files.begin(), files.end());
  if (files.empty()) {
    std::printf("spec: no fixtures found in %s -> FAIL\n", dir.c_str());
    return 1;
  }
  int not_covered = 0, unknown = 0;
  for (const std::string& path : files) {
    std::string text;
    Json doc;
    if (!ReadFileUtf8Path(path, &text) || !ParseJson(text, &doc)) {
      std::printf("spec: %s unreadable -> FAIL\n", path.c_str());
      g_total_fail++;
      continue;
    }
    std::string fx = doc.value("fixture", std::string());
    std::string version = doc.value("spec_version", std::string());
    if (!StartsWith(version, kSpecMajor)) {
      std::printf("spec: %s spec_version expected=%s* got=%s -> FAIL\n",
                  fx.c_str(), kSpecMajor, version.c_str());
      g_total_fail++;
      continue;
    }
    auto handler = covered.find(fx);
    if (handler == covered.end()) {
      auto owner = later.find(fx);
      if (owner != later.end()) {
        std::printf("spec: %s not covered yet (%zu cases; owner %s)\n",
                    fx.c_str(), doc["cases"].size(), owner->second.c_str());
        not_covered++;
      } else {
        std::printf("spec: %s unknown fixture -> FAIL\n", fx.c_str());
        unknown++;
        g_total_fail++;
      }
      continue;
    }
    Counts c;
    handler->second(fx, doc, &c);
    std::printf("spec: %s passed=%d failed=%d informative=%d\n", fx.c_str(),
                c.pass, c.fail, c.info);
    g_total_pass += c.pass;
    g_total_fail += c.fail;
    g_total_info += c.info;
  }
  std::printf(
      "spec: total passed=%d failed=%d informative=%d fixtures-covered=%zu "
      "fixtures-for-later=%d\n",
      g_total_pass, g_total_fail, g_total_info, covered.size(), not_covered);
  return g_total_fail == 0 && unknown == 0 ? 0 : 1;
}

}  // namespace
}  // namespace birch::core

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: birch_spec_tests <spec/fixtures folder>\n");
    return 2;
  }
  return birch::core::Run(argv[1]);
}
