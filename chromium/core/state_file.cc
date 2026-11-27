#include "core/state_file.h"

#include "core/codec.h"
#include "core/decoder.h"
#include "core/json.h"

namespace birch::core {

namespace {

// ---- decoding ----------------------------------------------------------------

bool ReqString(Decoder& d, const Json& o, const char* k, const std::string& p,
               std::string* out) {
  const Json* v = d.Field(o, k, p, true, "String");
  return v && d.String(*v, JoinKey(p, k), out);
}

bool ReqBool(Decoder& d, const Json& o, const char* k, const std::string& p,
             bool* out) {
  const Json* v = d.Field(o, k, p, true, "Bool");
  return v && d.Bool(*v, JoinKey(p, k), out);
}

bool ReqDouble(Decoder& d, const Json& o, const char* k, const std::string& p,
               double* out) {
  const Json* v = d.Field(o, k, p, true, "Double");
  return v && d.Double(*v, JoinKey(p, k), out);
}

bool ReqUuid(Decoder& d, const Json& o, const char* k, const std::string& p,
             std::string* out) {
  const Json* v = d.Field(o, k, p, true, "UUID");
  return v && d.Uuid(*v, JoinKey(p, k), out);
}

bool OptString(Decoder& d, const Json& o, const char* k, const std::string& p,
               std::optional<std::string>* out) {
  const Json* v = d.Field(o, k, p, false, "String");
  if (!v) {
    *out = std::nullopt;
    return d.ok();
  }
  std::string s;
  if (!d.String(*v, JoinKey(p, k), &s)) {
    return false;
  }
  *out = s;
  return true;
}

bool OptUuid(Decoder& d, const Json& o, const char* k, const std::string& p,
             std::optional<std::string>* out) {
  const Json* v = d.Field(o, k, p, false, "UUID");
  if (!v) {
    *out = std::nullopt;
    return d.ok();
  }
  std::string s;
  if (!d.Uuid(*v, JoinKey(p, k), &s)) {
    return false;
  }
  *out = s;
  return true;
}

bool OptDouble(Decoder& d, const Json& o, const char* k, const std::string& p,
               std::optional<double>* out) {
  const Json* v = d.Field(o, k, p, false, "Double");
  if (!v) {
    *out = std::nullopt;
    return d.ok();
  }
  double x = 0;
  if (!d.Double(*v, JoinKey(p, k), &x)) {
    return false;
  }
  *out = x;
  return true;
}

bool DecodeTheme(Decoder& d, const Json& v, const std::string& p, Theme* t) {
  if (!d.Object(v, p)) {
    return false;
  }
  const Json* colors = d.Field(v, "colors", p, true, "Array<String>");
  if (!colors || !d.Array(*colors, JoinKey(p, "colors"))) {
    return false;
  }
  t->colors.clear();
  for (size_t i = 0; i < colors->size(); ++i) {
    std::string c;
    if (!d.String((*colors)[i], JoinIndex(JoinKey(p, "colors"), i), &c)) {
      return false;
    }
    t->colors.push_back(c);
  }
  return ReqDouble(d, v, "angle", p, &t->angle) &&
         ReqDouble(d, v, "intensity", p, &t->intensity) &&
         OptDouble(d, v, "grain", p, &t->grain) &&
         OptDouble(d, v, "brightness", p, &t->brightness);
}

bool DecodeSplit(Decoder& d, const Json& v, const std::string& p,
                 SplitLayout* s) {
  if (!d.Object(v, p) || !ReqBool(d, v, "stacked", p, &s->stacked)) {
    return false;
  }
  const Json* f = d.Field(v, "fractions", p, true, "Array<Double>");
  if (!f || !d.Array(*f, JoinKey(p, "fractions"))) {
    return false;
  }
  s->fractions.clear();
  for (size_t i = 0; i < f->size(); ++i) {
    double x = 0;
    if (!d.Double((*f)[i], JoinIndex(JoinKey(p, "fractions"), i), &x)) {
      return false;
    }
    s->fractions.push_back(x);
  }
  return true;
}

bool DecodeItems(Decoder& d, const Json& obj, const char* key,
                 const std::string& p, std::vector<Item>* out);

bool DecodeItemAt(Decoder& d, const Json& v, const std::string& p, Item* it) {
  if (!d.Object(v, p)) {
    return false;
  }
  if (!ReqUuid(d, v, "id", p, &it->id) ||
      !ReqBool(d, v, "isFolder", p, &it->is_folder) ||
      !ReqString(d, v, "title", p, &it->title) ||
      !OptString(d, v, "customTitle", p, &it->custom_title) ||
      !OptString(d, v, "url", p, &it->url) ||
      !OptString(d, v, "pinnedURL", p, &it->pinned_url) ||
      !DecodeItems(d, v, "children", p, &it->children) ||
      !ReqBool(d, v, "expanded", p, &it->expanded)) {
    return false;
  }
  const Json* date = d.Field(v, "lastActive", p, true, "Date");
  if (!date || !d.Date(*date, JoinKey(p, "lastActive"), &it->last_active)) {
    return false;
  }
  const Json* split = d.Field(v, "split", p, false, "SplitLayout");
  it->split.reset();
  if (split) {
    SplitLayout s;
    if (!DecodeSplit(d, *split, JoinKey(p, "split"), &s)) {
      return false;
    }
    it->split = s;
  }
  return d.ok();
}

bool DecodeItems(Decoder& d, const Json& obj, const char* key,
                 const std::string& p, std::vector<Item>* out) {
  const Json* arr = d.Field(obj, key, p, true, "Array<Item>");
  std::string ap = JoinKey(p, key);
  if (!arr || !d.Array(*arr, ap)) {
    return false;
  }
  out->clear();
  for (size_t i = 0; i < arr->size(); ++i) {
    Item it;
    if (!DecodeItemAt(d, (*arr)[i], JoinIndex(ap, i), &it)) {
      return false;
    }
    out->push_back(std::move(it));
  }
  return true;
}

bool DecodeSpace(Decoder& d, const Json& v, const std::string& p, Space* s) {
  if (!d.Object(v, p)) {
    return false;
  }
  if (!ReqUuid(d, v, "id", p, &s->id) || !ReqString(d, v, "name", p, &s->name) ||
      !ReqString(d, v, "icon", p, &s->icon)) {
    return false;
  }
  const Json* theme = d.Field(v, "theme", p, true, "Theme");
  if (!theme || !DecodeTheme(d, *theme, JoinKey(p, "theme"), &s->theme)) {
    return false;
  }
  return DecodeItems(d, v, "pinned", p, &s->pinned) &&
         DecodeItems(d, v, "today", p, &s->today) &&
         OptUuid(d, v, "profileID", p, &s->profile_id) &&
         OptUuid(d, v, "selectedID", p, &s->selected_id);
}

bool DecodeWindow(Decoder& d, const Json& v, const std::string& p,
                  BrowserWindowState* w) {
  if (!d.Object(v, p) || !ReqUuid(d, v, "id", p, &w->id) ||
      !ReqUuid(d, v, "currentSpaceID", p, &w->current_space_id)) {
    return false;
  }
  const Json* sel = d.Field(v, "selections", p, true, "Dictionary<UUID, UUID>");
  std::string sp = JoinKey(p, "selections");
  // A dictionary whose keys aren't strings is a flat array of pairs.
  if (!sel || !d.Array(*sel, sp)) {
    return false;
  }
  if (sel->size() % 2 != 0) {
    d.Fail("dataCorrupted at " + sp);
    return false;
  }
  w->selections.clear();
  for (size_t i = 0; i < sel->size(); i += 2) {
    std::string k, val;
    if (!d.Uuid((*sel)[i], JoinIndex(sp, i), &k) ||
        !d.Uuid((*sel)[i + 1], JoinIndex(sp, i + 1), &val)) {
      return false;
    }
    w->selections.emplace_back(k, val);
  }
  return true;
}

bool DecodeState(Decoder& d, const Json& v, AppState* s) {
  const std::string p;
  if (!d.Object(v, p)) {
    return false;
  }
  const Json* version = d.Field(v, "version", p, true, "Int");
  if (!version || !d.Int(*version, "version", &s->version)) {
    return false;
  }
  const Json* spaces = d.Field(v, "spaces", p, true, "Array<Space>");
  if (!spaces || !d.Array(*spaces, "spaces")) {
    return false;
  }
  s->spaces.clear();
  for (size_t i = 0; i < spaces->size(); ++i) {
    Space sp;
    if (!DecodeSpace(d, (*spaces)[i], JoinIndex("spaces", i), &sp)) {
      return false;
    }
    s->spaces.push_back(std::move(sp));
  }
  if (!DecodeItems(d, v, "favorites", p, &s->favorites) ||
      !ReqUuid(d, v, "currentSpaceID", p, &s->current_space_id)) {
    return false;
  }
  const Json* windows = d.Field(v, "windows", p, false, "Array");
  s->windows.reset();
  if (windows) {
    if (!d.Array(*windows, "windows")) {
      return false;
    }
    std::vector<BrowserWindowState> list;
    for (size_t i = 0; i < windows->size(); ++i) {
      BrowserWindowState w;
      if (!DecodeWindow(d, (*windows)[i], JoinIndex("windows", i), &w)) {
        return false;
      }
      list.push_back(std::move(w));
    }
    s->windows = std::move(list);
  }
  return ReqBool(d, v, "sidebarCollapsed", p, &s->sidebar_collapsed) &&
         ReqDouble(d, v, "sidebarWidth", p, &s->sidebar_width);
}

// ---- encoding ----------------------------------------------------------------

Json EncodeTheme(const Theme& t) {
  Json o = Json::object();
  o["colors"] = t.colors;
  o["angle"] = t.angle;
  o["intensity"] = t.intensity;
  if (t.grain) {
    o["grain"] = *t.grain;
  }
  if (t.brightness) {
    o["brightness"] = *t.brightness;
  }
  return o;
}

Json EncodeItem(const Item& it) {
  Json o = Json::object();
  o["id"] = it.id;
  o["isFolder"] = it.is_folder;
  o["title"] = it.title;
  if (it.custom_title) {
    o["customTitle"] = *it.custom_title;
  }
  if (it.url) {
    o["url"] = *it.url;
  }
  if (it.pinned_url) {
    o["pinnedURL"] = *it.pinned_url;
  }
  Json children = Json::array();
  for (const Item& c : it.children) {
    children.push_back(EncodeItem(c));
  }
  o["children"] = children;
  o["expanded"] = it.expanded;
  o["lastActive"] = FormatIso8601(it.last_active);
  if (it.split) {
    o["split"] = {{"stacked", it.split->stacked},
                  {"fractions", it.split->fractions}};
  }
  return o;
}

Json EncodeItems(const std::vector<Item>& items) {
  Json a = Json::array();
  for (const Item& it : items) {
    a.push_back(EncodeItem(it));
  }
  return a;
}

}  // namespace

bool DecodeAppState(const std::string& text, AppState* out,
                    std::string* error) {
  Json v;
  if (!ParseJson(text, &v)) {
    *error = "dataCorrupted at ";
    return false;
  }
  Decoder d;
  AppState s;
  if (!DecodeState(d, v, &s) || !d.ok()) {
    *error = d.error();
    return false;
  }
  *out = std::move(s);
  error->clear();
  return true;
}

bool DecodeItem(const std::string& json_text, Item* out, std::string* error) {
  Json v;
  if (!ParseJson(json_text, &v)) {
    *error = "dataCorrupted at ";
    return false;
  }
  Decoder d;
  Item it;
  if (!DecodeItemAt(d, v, "", &it) || !d.ok()) {
    *error = d.error();
    return false;
  }
  *out = std::move(it);
  return true;
}

std::string EncodeAppState(const AppState& s) {
  Json o = Json::object();
  o["version"] = s.version;
  Json spaces = Json::array();
  for (const Space& sp : s.spaces) {
    Json j = Json::object();
    j["id"] = sp.id;
    j["name"] = sp.name;
    j["icon"] = sp.icon;
    j["theme"] = EncodeTheme(sp.theme);
    j["pinned"] = EncodeItems(sp.pinned);
    j["today"] = EncodeItems(sp.today);
    if (sp.profile_id) {
      j["profileID"] = *sp.profile_id;
    }
    if (sp.selected_id) {
      j["selectedID"] = *sp.selected_id;
    }
    spaces.push_back(j);
  }
  o["spaces"] = spaces;
  o["favorites"] = EncodeItems(s.favorites);
  o["currentSpaceID"] = s.current_space_id;
  if (s.windows) {
    Json ws = Json::array();
    for (const BrowserWindowState& w : *s.windows) {
      Json sel = Json::array();
      for (const auto& pair : w.selections) {
        sel.push_back(pair.first);
        sel.push_back(pair.second);
      }
      ws.push_back({{"id", w.id},
                    {"currentSpaceID", w.current_space_id},
                    {"selections", sel}});
    }
    o["windows"] = ws;
  }
  o["sidebarCollapsed"] = s.sidebar_collapsed;
  o["sidebarWidth"] = s.sidebar_width;
  return DumpJson(o);
}

AppState SeedState() {
  Space home;
  home.id = NewUuid();
  home.name = "Home";
  home.icon = "\xF0\x9F\x8F\xA0";  // 🏠
  home.theme = Theme::Presets()[0];
  Item welcome = Item::NewTab("birch://welcome", "Welcome to Birch");
  home.selected_id = welcome.id;
  home.today.push_back(welcome);
  AppState s;
  s.current_space_id = home.id;
  s.spaces.push_back(std::move(home));
  return s;
}

LaunchState LoadStateOnLaunch(const std::string& profile_dir) {
  LaunchState out;
  std::string path = JoinPath(profile_dir, kStateFileName);
  std::string text;
  out.file_existed = FileExists(path);
  if (out.file_existed && ReadFileUtf8Path(path, &text)) {
    AppState s;
    std::string error;
    if (DecodeAppState(text, &s, &error) && !s.spaces.empty()) {
      out.state = std::move(s);
      out.used_file = true;
      return out;
    }
    out.decode_error = error.empty() ? "no spaces" : error;
  }
  if (out.file_existed) {
    // Never silently discard a state file we could not read.
    std::string backup = JoinPath(
        profile_dir,
        "state.unreadable-" + std::to_string(NowSeconds()) + ".json");
    if (CopyFileUtf8Path(path, backup)) {
      out.backup_path = backup;
    }
  }
  out.state = SeedState();
  return out;
}

bool SaveState(const std::string& profile_dir, const AppState& state) {
  return MakeDirectories(profile_dir) &&
         WriteFileAtomic(JoinPath(profile_dir, kStateFileName),
                         EncodeAppState(state));
}

}  // namespace birch::core
