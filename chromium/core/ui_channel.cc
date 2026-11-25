#include "core/ui_channel.h"

#include <cstdio>

#include "core/codec.h"
#include "core/json.h"

namespace birch::core::ui_channel {

namespace {

enum class Type { kUuid, kText };

struct Field {
  const char* key;
  Type type;
};

struct Schema {
  const char* name;
  Kind kind;
  std::vector<Field> fields;  // all required; no other key is allowed
};

// The fixed list. Adding a name: one line here, a Kind in the header.
const std::vector<Schema>& Schemas() {
  static const std::vector<Schema> schemas = {
      {"ui.ready", Kind::kUiReady, {}},
      {"tab.select", Kind::kTabSelect, {{"id", Type::kUuid}}},
      {"tab.close", Kind::kTabClose, {{"id", Type::kUuid}}},
      {"tab.new", Kind::kTabNew, {}},
      {"nav.back", Kind::kNavBack, {}},
      {"nav.forward", Kind::kNavForward, {}},
      {"nav.reload", Kind::kNavReload, {}},
      {"address.submit", Kind::kAddressSubmit, {{"text", Type::kText}}},
      {"address.cancel", Kind::kAddressCancel, {}},
      {"address.blur", Kind::kAddressBlur, {}},
  };
  return schemas;
}

bool NameCharsOk(const std::string& name) {
  if (name.empty() || name.size() > kMaxNameBytes) {
    return false;
  }
  for (char c : name) {
    if (!((c >= 'a' && c <= 'z') || c == '.')) {
      return false;
    }
  }
  return true;
}

// Printable text only: no control characters (U+0000–U+001F, U+007F). The
// JSON parser has already rejected invalid UTF-8.
bool TextOk(const std::string& s) {
  if (s.size() > kMaxTextBytes) {
    return false;
  }
  for (unsigned char c : s) {
    if (c < 0x20 || c == 0x7F) {
      return false;
    }
  }
  return true;
}

ParseResult Refuse(const std::string& why) {
  ParseResult r;
  r.error = why;
  return r;
}

const char* KindName(SidebarRow::Kind k) {
  switch (k) {
    case SidebarRow::Kind::kFavorite:
      return "favorite";
    case SidebarRow::Kind::kPinned:
      return "pinned";
    case SidebarRow::Kind::kFolder:
      return "folder";
    case SidebarRow::Kind::kSplit:
      return "split";
    case SidebarRow::Kind::kSeparator:
      return "separator";
    case SidebarRow::Kind::kToday:
      return "today";
  }
  return "today";
}

bool ParseHex(const std::string& s, int rgb[3]) {
  if (s.size() != 7 || s[0] != '#') {
    return false;
  }
  for (int i = 0; i < 3; ++i) {
    int v = 0;
    for (int j = 0; j < 2; ++j) {
      char c = s[1 + i * 2 + j];
      int d = (c >= '0' && c <= '9')   ? c - '0'
              : (c >= 'a' && c <= 'f') ? c - 'a' + 10
              : (c >= 'A' && c <= 'F') ? c - 'A' + 10
                                       : -1;
      if (d < 0) {
        return false;
      }
      v = v * 16 + d;
    }
    rgb[i] = v;
  }
  return true;
}

}  // namespace

ParseResult Parse(const std::string& name, const std::string& args_json) {
  if (!NameCharsOk(name)) {
    return Refuse("bad name");
  }
  const Schema* schema = nullptr;
  for (const Schema& s : Schemas()) {
    if (name == s.name) {
      schema = &s;
    }
  }
  if (!schema) {
    return Refuse("unknown name");
  }
  if (args_json.size() > kMaxArgsBytes) {
    return Refuse("arguments too large");
  }
  Json args;
  if (!ParseJson(args_json, &args) || !args.is_object()) {
    return Refuse("arguments are not a JSON object");
  }
  if (args.size() != schema->fields.size()) {
    return Refuse("wrong number of arguments");
  }
  Message m;
  m.kind = schema->kind;
  m.name = schema->name;
  for (const Field& f : schema->fields) {
    auto it = args.find(f.key);
    if (it == args.end() || !it->is_string()) {
      return Refuse(std::string("missing or non-string '") + f.key + "'");
    }
    const std::string& v = it->get_ref<const std::string&>();
    switch (f.type) {
      case Type::kUuid: {
        std::string upper;
        if (v.size() != 36 || !ParseUuid(v, &upper)) {
          return Refuse(std::string("'") + f.key + "' is not an id");
        }
        m.id = upper;
        break;
      }
      case Type::kText:
        if (!TextOk(v)) {
          return Refuse(std::string("'") + f.key + "' too long or has control characters");
        }
        m.text = v;
        break;
    }
  }
  ParseResult r;
  r.message = std::move(m);
  return r;
}

std::vector<std::string> Names() {
  std::vector<std::string> out;
  for (const Schema& s : Schemas()) {
    out.push_back(s.name);
  }
  return out;
}

std::string SidebarStateJson(const SidebarState& s) {
  Json rows = Json::array();
  for (const SidebarRow& r : s.rows) {
    rows.push_back({{"kind", KindName(r.kind)},
                    {"id", r.item_id},
                    {"target", r.target_id},
                    {"title", r.title},
                    {"depth", r.depth}});
  }
  Json colors = Json::array();
  for (const std::string& c : s.colors) {
    int rgb[3];
    if (ParseHex(c, rgb)) {
      colors.push_back(c);
    }
  }
  Json address = {{"text", s.address.text ? Json(*s.address.text) : Json(nullptr)},
                  {"full", s.full_url},
                  {"notSecure", s.address.not_secure_lock},
                  {"bundled", s.address.is_bundled}};
  Json out = {{"space",
               {{"title", s.space_title},
                {"private", s.is_private},
                {"colors", colors},
                {"background", s.background}}},
              {"rows", rows},
              {"selected", s.selected_id},
              {"address", address},
              {"nav",
               {{"back", s.can_go_back},
                {"forward", s.can_go_forward},
                {"reload", s.can_reload},
                {"loading", s.loading}}}};
  return out.dump(-1, ' ', false, Json::error_handler_t::replace);
}

std::string FocusAddressJson(bool new_tab, const std::string& full_url) {
  Json out = {{"newTab", new_tab}, {"full", full_url}};
  return out.dump(-1, ' ', false, Json::error_handler_t::replace);
}

std::string SurroundColor(const std::vector<std::string>& colors,
                          bool is_private) {
  if (is_private) {
    return "#26232E";
  }
  int rgb[3] = {0xB9, 0xB2, 0xE8};  // lavender when a space has no colour
  if (!colors.empty()) {
    int parsed[3];
    if (ParseHex(colors.back(), parsed)) {
      rgb[0] = parsed[0];
      rgb[1] = parsed[1];
      rgb[2] = parsed[2];
    }
  }
  // 30 % of the colour over a near-white base (#F7F5FA).
  const int base[3] = {0xF7, 0xF5, 0xFA};
  char buf[8];
  int mixed[3];
  for (int i = 0; i < 3; ++i) {
    mixed[i] = (rgb[i] * 30 + base[i] * 70 + 50) / 100;
  }
  std::snprintf(buf, sizeof buf, "#%02X%02X%02X", mixed[0], mixed[1], mixed[2]);
  return buf;
}

std::string JsonQuote(const std::string& text) {
  return Json(text).dump(-1, ' ', false, Json::error_handler_t::replace);
}

}  // namespace birch::core::ui_channel
