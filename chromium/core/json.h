// The one place core/ includes nlohmann/json (pinned in chromium/deps.json,
// fetched by tools/fetch_deps.py; never committed). Only core/ .cc files and
// tests include this header: public core headers use plain structs, so engine/
// and ui/ never depend on the JSON library.
//
// Core is written without exceptions (CEF builds with them off): parse with
// allow_exceptions=false and check every type before reading a value.
#ifndef BIRCH_CORE_JSON_H_
#define BIRCH_CORE_JSON_H_

#ifndef JSON_NOEXCEPTION
#define JSON_NOEXCEPTION
#endif
#include <nlohmann/json.hpp>

#include <string>

namespace birch::core {

using Json = nlohmann::json;

// Parses |text|; returns false (and leaves |out| untouched) on invalid JSON.
inline bool ParseJson(const std::string& text, Json* out) {
  Json v = Json::parse(text, nullptr, /*allow_exceptions=*/false,
                       /*ignore_comments=*/false);
  if (v.is_discarded()) {
    return false;
  }
  *out = std::move(v);
  return true;
}

// Pretty-printed (2 spaces), keys sorted (nlohmann objects are ordered maps),
// "/" not escaped, invalid UTF-8 replaced rather than aborting.
inline std::string DumpJson(const Json& v) {
  return v.dump(2, ' ', false, Json::error_handler_t::replace) + "\n";
}

}  // namespace birch::core

#endif  // BIRCH_CORE_JSON_H_
