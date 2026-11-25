#include "core/settings.h"

#include <cmath>

#include "core/codec.h"
#include "core/decoder.h"
#include "core/json.h"

namespace birch::core {

namespace {

// Integral doubles are written as integers, as the Mac's encoder does.
Json Number(double d) {
  if (std::isfinite(d) && std::floor(d) == d && std::fabs(d) < 1e15) {
    return static_cast<int64_t>(d);
  }
  return d;
}

bool Read(Decoder& d, const Json& v, const std::string& p, std::string* out) {
  return d.String(v, p, out);
}
bool Read(Decoder& d, const Json& v, const std::string& p, bool* out) {
  return d.Bool(v, p, out);
}
bool Read(Decoder& d, const Json& v, const std::string& p, double* out) {
  return d.Double(v, p, out);
}
bool Read(Decoder& d, const Json& v, const std::string& p, int64_t* out) {
  return d.Int(v, p, out);
}
bool Read(Decoder& d, const Json& v, const std::string& p, StringList* out) {
  if (!d.Array(v, p)) {
    return false;
  }
  StringList list;
  for (size_t i = 0; i < v.size(); ++i) {
    std::string s;
    if (!d.String(v[i], JoinIndex(p, i), &s)) {
      return false;
    }
    list.push_back(s);
  }
  *out = list;
  return true;
}
bool Read(Decoder& d, const Json& v, const std::string& p, BoolMap* out) {
  if (!d.Object(v, p)) {
    return false;
  }
  BoolMap map;
  for (auto it = v.begin(); it != v.end(); ++it) {
    bool b = false;
    if (!d.Bool(it.value(), JoinKey(p, it.key()), &b)) {
      return false;
    }
    map[it.key()] = b;
  }
  *out = map;
  return true;
}
bool Read(Decoder& d, const Json& v, const std::string& p, StringListMap* out) {
  if (!d.Object(v, p)) {
    return false;
  }
  StringListMap map;
  for (auto it = v.begin(); it != v.end(); ++it) {
    StringList list;
    if (!Read(d, it.value(), JoinKey(p, it.key()), &list)) {
      return false;
    }
    map[it.key()] = list;
  }
  *out = map;
  return true;
}

Json Write(const std::string& v) { return v; }
Json Write(bool v) { return v; }
Json Write(double v) { return Number(v); }
Json Write(int64_t v) { return v; }
Json Write(const StringList& v) { return v; }
Json Write(const BoolMap& v) {
  Json o = Json::object();
  for (const auto& kv : v) {
    o[kv.first] = kv.second;
  }
  return o;
}
Json Write(const StringListMap& v) {
  Json o = Json::object();
  for (const auto& kv : v) {
    o[kv.first] = kv.second;
  }
  return o;
}

const char* SwiftType(const std::string*) { return "String"; }
const char* SwiftType(const bool*) { return "Bool"; }
const char* SwiftType(const double*) { return "Double"; }
const char* SwiftType(const int64_t*) { return "Int"; }
const char* SwiftType(const StringList*) { return "Array<String>"; }
const char* SwiftType(const BoolMap*) { return "Dictionary<String, Bool>"; }
const char* SwiftType(const StringListMap*) {
  return "Dictionary<String, Array<String>>";
}

}  // namespace

bool DecodeSettings(const std::string& text, Settings* out,
                    std::string* error) {
  Json v;
  if (!ParseJson(text, &v)) {
    *error = "dataCorrupted at ";
    return false;
  }
  Decoder d;
  if (!d.Object(v, "")) {
    *error = d.error();
    return false;
  }
  Settings s;
  s.settingsVersion = 1;  // a file without the key predates versioning
#define BIRCH_SETTINGS_READ(type, name, def)                         \
  if (d.ok()) {                                                      \
    const Json* f = d.Field(v, #name, "", false, #type);             \
    if (f) {                                                         \
      Read(d, *f, #name, &s.name);                                   \
    }                                                                \
  }
  BIRCH_SETTINGS_FIELDS(BIRCH_SETTINGS_READ)
#undef BIRCH_SETTINGS_READ
  if (!d.ok()) {
    *error = d.error();
    return false;
  }
  *out = s;
  error->clear();
  return true;
}

std::string EncodeSettings(const Settings& s) {
  Json o = Json::object();
#define BIRCH_SETTINGS_WRITE(type, name, def) o[#name] = Write(s.name);
  BIRCH_SETTINGS_FIELDS(BIRCH_SETTINGS_WRITE)
#undef BIRCH_SETTINGS_WRITE
  return DumpJson(o);
}

SettingsLoad LoadSettings(const std::string& profile_dir) {
  SettingsLoad out;
  std::string path = JoinPath(profile_dir, kSettingsFileName);
  std::string text;
  out.file_existed = FileExists(path);
  if (out.file_existed && ReadFileUtf8Path(path, &text)) {
    Settings s;
    std::string error;
    if (DecodeSettings(text, &s, &error)) {
      out.decoded = s;
      if (s.settingsVersion < 2) {
        // The first build's 8 pt reveal strip was too thin; widen it unless
        // it was customised.
        if (s.sidebarHoverEdgeWidth == 8) {
          s.sidebarHoverEdgeWidth = 14;
        }
        s.settingsVersion = 2;
        out.file_rewritten = SaveSettings(profile_dir, s);
      }
      out.loaded = s;
      return out;
    }
    out.decode_error = error;
    std::string backup = JoinPath(
        profile_dir,
        "settings.unreadable-" + std::to_string(NowSeconds()) + ".json");
    if (CopyFileUtf8Path(path, backup)) {
      out.backup_path = backup;
    }
  }
  out.loaded = Settings();
  out.file_rewritten = SaveSettings(profile_dir, out.loaded);
  return out;
}

bool SaveSettings(const std::string& profile_dir, const Settings& s) {
  return MakeDirectories(profile_dir) &&
         WriteFileAtomic(JoinPath(profile_dir, kSettingsFileName),
                         EncodeSettings(s));
}

std::vector<SettingsFieldInfo> SettingsFields() {
  std::vector<SettingsFieldInfo> out;
  Settings s;
#define BIRCH_SETTINGS_INFO(type, name, def) \
  out.push_back({#name, SwiftType(&s.name)});
  BIRCH_SETTINGS_FIELDS(BIRCH_SETTINGS_INFO)
#undef BIRCH_SETTINGS_INFO
  return out;
}

}  // namespace birch::core
