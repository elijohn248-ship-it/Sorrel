#include "core/archive_history.h"

#include "core/codec.h"
#include "core/decoder.h"
#include "core/json.h"

namespace birch::core {

namespace {

bool Str(Decoder& d, const Json& o, const char* k, const std::string& p,
         std::string* out) {
  const Json* v = d.Field(o, k, p, true, "String");
  return v && d.String(*v, JoinKey(p, k), out);
}

bool Dt(Decoder& d, const Json& o, const char* k, const std::string& p,
        int64_t* out) {
  const Json* v = d.Field(o, k, p, true, "Date");
  return v && d.Date(*v, JoinKey(p, k), out);
}

}  // namespace

bool DecodeArchive(const std::string& text, std::vector<ArchivedTab>* out,
                   std::string* error) {
  Json v;
  Decoder d;
  if (!ParseJson(text, &v)) {
    *error = "dataCorrupted at ";
    return false;
  }
  std::vector<ArchivedTab> list;
  if (d.Array(v, "")) {
    for (size_t i = 0; i < v.size() && d.ok(); ++i) {
      std::string p = JoinIndex("", i);
      ArchivedTab t;
      if (d.Object(v[i], p) && Str(d, v[i], "url", p, &t.url) &&
          Str(d, v[i], "title", p, &t.title)) {
        const Json* id = d.Field(v[i], "spaceID", p, true, "UUID");
        if (id && d.Uuid(*id, JoinKey(p, "spaceID"), &t.space_id) &&
            Dt(d, v[i], "date", p, &t.date)) {
          list.push_back(t);
        }
      }
    }
  }
  if (!d.ok()) {
    *error = d.error();
    return false;
  }
  *out = list;
  return true;
}

std::string EncodeArchive(const std::vector<ArchivedTab>& list) {
  Json a = Json::array();
  for (const ArchivedTab& t : list) {
    a.push_back({{"url", t.url},
                 {"title", t.title},
                 {"spaceID", t.space_id},
                 {"date", FormatIso8601(t.date)}});
  }
  return DumpJson(a);
}

bool DecodeHistory(const std::string& text, std::vector<HistoryEntry>* out,
                   std::string* error) {
  Json v;
  Decoder d;
  if (!ParseJson(text, &v)) {
    *error = "dataCorrupted at ";
    return false;
  }
  std::vector<HistoryEntry> list;
  if (d.Array(v, "")) {
    for (size_t i = 0; i < v.size() && d.ok(); ++i) {
      std::string p = JoinIndex("", i);
      HistoryEntry e;
      if (d.Object(v[i], p) && Str(d, v[i], "url", p, &e.url) &&
          Str(d, v[i], "title", p, &e.title)) {
        const Json* n = d.Field(v[i], "visits", p, true, "Int");
        if (n && d.Int(*n, JoinKey(p, "visits"), &e.visits) &&
            Dt(d, v[i], "last", p, &e.last)) {
          list.push_back(e);
        }
      }
    }
  }
  if (!d.ok()) {
    *error = d.error();
    return false;
  }
  *out = list;
  return true;
}

std::string EncodeHistory(const std::vector<HistoryEntry>& list) {
  Json a = Json::array();
  for (const HistoryEntry& e : list) {
    a.push_back({{"url", e.url},
                 {"title", e.title},
                 {"visits", e.visits},
                 {"last", FormatIso8601(e.last)}});
  }
  return DumpJson(a);
}

}  // namespace birch::core
