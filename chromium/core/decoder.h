// Internal to core/: a strict JSON reader that behaves like Swift's
// JSONDecoder for the types Birch saves (spec/saved-data.md ▸ Common encoding
// rules), with the Mac's error wording for logs. Not a public header.
#ifndef BIRCH_CORE_DECODER_H_
#define BIRCH_CORE_DECODER_H_

#include <cstdint>
#include <string>

#include "core/json.h"

namespace birch::core {

std::string JoinKey(const std::string& path, const std::string& key);
std::string JoinIndex(const std::string& path, size_t index);

class Decoder {
 public:
  bool ok() const { return error_.empty(); }
  const std::string& error() const { return error_; }
  void Fail(const std::string& message) {
    if (error_.empty()) {
      error_ = message;
    }
  }

  // |obj| must be an object (checked by the caller with Object()). Required:
  // missing -> keyNotFound, null -> valueNotFound; returns nullptr on either.
  // Optional: missing or null -> nullptr without an error.
  const Json* Field(const Json& obj, const char* key, const std::string& path,
                    bool required, const char* type_name);

  bool Object(const Json& v, const std::string& path);
  bool Array(const Json& v, const std::string& path);
  bool String(const Json& v, const std::string& path, std::string* out);
  bool Bool(const Json& v, const std::string& path, bool* out);
  bool Double(const Json& v, const std::string& path, double* out);
  bool Int(const Json& v, const std::string& path, int64_t* out);
  bool Uuid(const Json& v, const std::string& path, std::string* out);
  bool Date(const Json& v, const std::string& path, int64_t* out);

 private:
  std::string error_;
};

}  // namespace birch::core

#endif  // BIRCH_CORE_DECODER_H_
