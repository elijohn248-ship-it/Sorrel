#include "core/decoder.h"

#include <cmath>

#include "core/codec.h"

namespace birch::core {

std::string JoinKey(const std::string& path, const std::string& key) {
  return path.empty() ? key : path + "." + key;
}

std::string JoinIndex(const std::string& path, size_t index) {
  return path + "[" + std::to_string(index) + "]";
}

const Json* Decoder::Field(const Json& obj, const char* key,
                           const std::string& path, bool required,
                           const char* type_name) {
  auto it = obj.find(key);
  if (it == obj.end()) {
    if (required) {
      Fail(std::string("keyNotFound ") + key + " at " + path);
    }
    return nullptr;
  }
  if (it->is_null()) {
    if (required) {
      Fail(std::string("valueNotFound ") + type_name + " at " +
           JoinKey(path, key));
    }
    return nullptr;
  }
  return &*it;
}

bool Decoder::Object(const Json& v, const std::string& path) {
  if (!v.is_object()) {
    Fail("typeMismatch Dictionary<String, Any> at " + path);
    return false;
  }
  return true;
}

bool Decoder::Array(const Json& v, const std::string& path) {
  if (!v.is_array()) {
    Fail("typeMismatch Array<Any> at " + path);
    return false;
  }
  return true;
}

bool Decoder::String(const Json& v, const std::string& path,
                     std::string* out) {
  if (!v.is_string()) {
    Fail("typeMismatch String at " + path);
    return false;
  }
  *out = v.get_ref<const std::string&>();
  return true;
}

bool Decoder::Bool(const Json& v, const std::string& path, bool* out) {
  if (!v.is_boolean()) {
    Fail("typeMismatch Bool at " + path);
    return false;
  }
  *out = v.get<bool>();
  return true;
}

bool Decoder::Double(const Json& v, const std::string& path, double* out) {
  if (!v.is_number()) {
    Fail("typeMismatch Double at " + path);
    return false;
  }
  *out = v.get<double>();
  return true;
}

bool Decoder::Int(const Json& v, const std::string& path, int64_t* out) {
  if (v.is_number_integer()) {
    if (v.is_number_unsigned() &&
        v.get<uint64_t>() > static_cast<uint64_t>(INT64_MAX)) {
      Fail("dataCorrupted at " + path);
      return false;
    }
    *out = v.get<int64_t>();
    return true;
  }
  if (v.is_number_float()) {
    // A number with a fraction does not fit in an Int (the Mac reports
    // dataCorrupted); an integral float such as 2.0 does.
    double d = v.get<double>();
    if (std::isfinite(d) && std::floor(d) == d && d >= -9.2e18 && d <= 9.2e18) {
      *out = static_cast<int64_t>(d);
      return true;
    }
    Fail("dataCorrupted at " + path);
    return false;
  }
  Fail("typeMismatch Int at " + path);
  return false;
}

bool Decoder::Uuid(const Json& v, const std::string& path, std::string* out) {
  std::string s;
  if (!String(v, path, &s)) {
    return false;
  }
  if (!ParseUuid(s, out)) {
    Fail("dataCorrupted at " + path);
    return false;
  }
  return true;
}

bool Decoder::Date(const Json& v, const std::string& path, int64_t* out) {
  std::string s;
  if (!String(v, path, &s)) {
    return false;
  }
  if (!ParseIso8601(s, out)) {
    Fail("dataCorrupted at " + path);
    return false;
  }
  return true;
}

}  // namespace birch::core
