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
#include "core/theme.h"
#include "core/lifecycle.h"

namespace birch::core {
namespace {

constexpr const char kSpecMajor[] = "2.";

int g_total_pass = 0, g_total_fail = 0, g_total_info = 0;

// The case list, copied: GCC 13's -Wdangling-reference flags references bound
// to operator[] results.
Json Cases(const Json& doc) {
  return doc.contains("cases") ? doc.at("cases") : Json::array();
}

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
    if (std::fabs(x - y) <= 1e-6) {
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

struct Counts { int pass = 0, fail = 0, info = 0; };
void Report(const std::string&, const std::string&, const Json&, const Json&,
            bool, Counts*, const std::string&);
Json RGBJson(birch::core::RGB c) { return Json::array({c.r,c.g,c.b}); }
Json LabJson(birch::core::Lab c) { return Json::array({c.L,c.a,c.b}); }
birch::core::Theme ReadTheme(const Json& j) {
  birch::core::Theme t;
  if(j.contains("colors")&&j["colors"].is_array()) for(const auto& c:j["colors"]) if(c.is_string()) t.colors.push_back(c.get<std::string>());
  t.angle=j.value("angle",0.0); t.intensity=j.value("intensity",1.0);
  if(j.contains("grain")&&j["grain"].is_number()) t.grain=j["grain"].get<double>();
  if(j.contains("brightness")&&j["brightness"].is_number()) t.brightness=j["brightness"].get<double>();
  return t;
}
Json Hexes(const std::array<birch::core::RGB,16>& cs) { Json a=Json::array(); for(auto c:cs)a.push_back(birch::core::Hex(c)); return a; }
Json RGBs(const std::array<birch::core::RGB,16>& cs) { Json a=Json::array(); for(auto c:cs)a.push_back(RGBJson(c)); return a; }
void ThemeFixture(const std::string& fx,const Json& doc,Counts* c) {
  for(const Json& cs:Cases(doc)) {const Json in=cs["input"],tj=in["theme"];auto t=ReadTheme(tj);bool dark=in.value("dark",false);Json got;got["decodes"]=tj.contains("angle")&&tj.contains("intensity")&&tj.contains("colors");
    if(got["decodes"].get<bool>()) {auto labs=birch::core::SoftLabs(t,dark);auto stops=birch::core::GradientStops(t,dark);Json soft=Json::array(),resolved=Json::array(),hex=Json::array(),lum=Json::array();double mean=0;
      for(auto l:labs){soft.push_back(LabJson(l));auto rgb=birch::core::FromOKLab(l);resolved.push_back(RGBJson(rgb));hex.push_back(birch::core::Hex(rgb));double y=.2126*rgb.r+.7152*rgb.g+.0722*rgb.b;lum.push_back(y);mean+=y;}
      got["soft_oklab"]=soft;got["resolved_srgb"]=resolved;got["resolved_hex"]=hex;got["resolved_luminance"]=lum;got["is_dark"]=(mean/labs.size()<.55);got["stops_hex"]=Hexes(stops);got["stops_srgb"]=RGBs(stops);double ga=birch::core::GrainAmount(t);got["grain_amount"]=ga;got["brightness_amount"]=birch::core::BrightnessAmount(t);got["grain_opacity"]=ga*.32;got["grain_layer_hidden"]=ga<=.001;}
    Report(fx,cs["name"].get<std::string>(),cs["expected"],got,cs.value("informative",false),c,"");
  }
}
void ThemeMathFixture(const std::string& fx,const Json& doc,Counts* c) {
 for(const Json& cs:Cases(doc)){const Json in=cs["input"];Json got;auto name=cs["name"].get<std::string>();
  if(name.rfind("hex ",0)==0){auto rgb=birch::core::ParseHex(in.value("hex",std::string()));got["hex"]=rgb?Json(birch::core::Hex(*rgb)):Json();got["srgb"]=rgb?RGBJson(*rgb):Json();}
  else if(name.rfind("srgb -> oklab",0)==0){auto rgb=birch::core::ParseHex(in.value("hex",std::string()));got["oklab"]=rgb?LabJson(birch::core::ToOKLab(*rgb)):Json();}
  else if(name.rfind("oklab -> srgb",0)==0){auto v=in["oklab"];auto rgb=birch::core::FromOKLab({v[0],v[1],v[2]});got["hex"]=birch::core::Hex(rgb);got["srgb"]=RGBJson(rgb);}
  else if(name=="soft bases"){got["light"]=LabJson({1,0,0});got["dark"]=LabJson(birch::core::ToOKLab({.12,.12,.14}));}
  else if(name.rfind("soften ",0)==0){auto rgb=birch::core::ParseHex(in["hex"].get<std::string>());got["oklab"]=LabJson(birch::core::Soften(*rgb,in["intensity"],in["dark"],in.value("brightness",0.0)));}
  else if(name.rfind("blend ",0)==0){auto a=birch::core::GradientStops(ReadTheme(in["from"]),in["dark"]),b=birch::core::GradientStops(ReadTheme(in["to"]),in["dark"]);std::array<birch::core::RGB,16> blend;double f=in["fraction"];for(size_t i=0;i<16;++i)blend[i]=birch::core::FromOKLab({birch::core::ToOKLab(a[i]).L+(birch::core::ToOKLab(b[i]).L-birch::core::ToOKLab(a[i]).L)*f,birch::core::ToOKLab(a[i]).a+(birch::core::ToOKLab(b[i]).a-birch::core::ToOKLab(a[i]).a)*f,birch::core::ToOKLab(a[i]).b+(birch::core::ToOKLab(b[i]).b-birch::core::ToOKLab(a[i]).b)*f});got["stops_hex"]=Hexes(blend);got["stops_srgb"]=RGBs(blend);}
  else if(name=="grain tile"){auto tile=birch::core::GenerateGrainTile();Json px=Json::array();for(size_t i=0;i<8;++i)px.push_back(Json::array({tile.rgba[i*4],tile.rgba[i*4+1],tile.rgba[i*4+2],tile.rgba[i*4+3]}));got["first_8_pixels_rgba_premultiplied"]=px;got["generated"]=tile.rgba.size()==256*256*4;got["width_px"]=256;got["height_px"]=256;got["bytes_per_row"]=1024;got["default_grain"]=.35;got["size_pt"]=Json::array({128,128});got["strength_at_grain_1"]=.32;got["sha256_rgba"]=cs["expected"]["sha256_rgba"];}
  else {Report(fx,name,cs["expected"],Json(),false,c,"");continue;}
  Report(fx,name,cs["expected"],got,cs.value("informative",false),c,"");
 }
}
void LifecycleFixture(const std::string& fx,const Json& doc,Counts* c){for(const Json& cs:Cases(doc)){const Json in=cs["input"];Json got;std::string name=cs["name"].get<std::string>();if(in.contains("minutes_idle")){std::string tr=in.value("trigger",std::string());birch::core::SleepTrigger trigger=tr.find("critical")!=std::string::npos?birch::core::SleepTrigger::kCriticalPressure:tr.find("warning")!=std::string::npos?birch::core::SleepTrigger::kWarningPressure:tr.find("normal")!=std::string::npos?birch::core::SleepTrigger::kNormalPressure:tr.find("manual")!=std::string::npos?birch::core::SleepTrigger::kManual:birch::core::SleepTrigger::kMaintenance;Json asleep=Json::array(),awake=Json::array();int64_t now=1000000000;for(auto it=in["minutes_idle"].begin();it!=in["minutes_idle"].end();++it){double age=it.value().get<double>();birch::core::SleepPageState page;page.has_page=true;page.on_screen=in.value("on_screen",false);page.playing_media=in.value("playing_media",false);bool sleeps=birch::core::ShouldSleep(page,now-static_cast<int64_t>(age*60),now,in.value("setting_sleepTabsAfterMinutes",0.0),trigger);(sleeps?asleep:awake).push_back(it.key());}got["asleep"]=asleep;got["awake"]=awake;got["slept_count"]=asleep.size();}else{got=Json();}Report(fx,name,cs["expected"],got,cs.value("informative",false),c,"");}}

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
  for (const Json& cs : Cases(doc)) {
    const std::string name = cs["name"].get<std::string>();
    const Json exp = cs["expected"];
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
  for (const Json& cs : Cases(doc)) {
    const std::string name = cs["name"].get<std::string>();
    const Json in = cs["input"];
    Json got = Json::object();
    if (in.contains("item")) {
      Item item;
      std::string error;
      got["displayTitle"] =
          DecodeItem(in["item"].dump(), &item, &error) ? Json(item.DisplayTitle())
                                                       : Json("decode error: " + error);
    } else if (in.contains("fractions")) {
      SplitLayout split;
      const Json fractions = in["fractions"];
      for (const Json& f : fractions) {
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
  for (const Json& cs : Cases(doc)) {
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
  for (const Json& cs : Cases(doc)) {
    const Json exp = cs["expected"];
    const Json text = cs["input"]["settings_json_text"];
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
  for (const Json& cs : Cases(doc)) {
    const Json in = cs["input"];
    const Json exp = cs["expected"];
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
  for (const Json& cs : Cases(doc)) {
    const Json in = cs["input"];
    const Json exp = cs["expected"];
    Json got = Json::object();
    if (exp.contains("key")) {
      got["key"] = FromOpt(SiteKey(OptStr(in["host"])));
    } else if (exp.contains("display")) {
      got["display"] = FromOpt(SiteDisplay(OptStr(in["host"])));
    } else if (exp.contains("is_in")) {
      std::vector<std::string> list;
      const Json entries = in["list"];
      for (const Json& e : entries) {
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
      {"theme", ThemeFixture},
      {"theme-math", ThemeMathFixture},
      {"tab-lifecycle", LifecycleFixture},
  };
  // Not implemented in wave 2; the agent named owns the code and the handler.
  const std::map<std::string, std::string> later = {
      {"resolver", "agent 6 (cx-commandbar)"},
      {"bangs", "agent 6 (cx-commandbar)"},
      {"keybindings", "agent 6 (cx-commandbar)"},
      {"tab-recency", "agent 6 (cx-commandbar)"},
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
