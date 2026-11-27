#include "core/typed_url.h"

#include <regex>

#include "core/codec.h"

namespace birch::core {

namespace {

std::string Trim(const std::string& s) {
  size_t b = 0, e = s.size();
  auto ws = [](char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
  };
  while (b < e && ws(s[b])) {
    ++b;
  }
  while (e > b && ws(s[e - 1])) {
    --e;
  }
  return s.substr(b, e - b);
}

}  // namespace

std::optional<std::string> UrlFromTyped(const std::string& typed) {
  std::string text = Trim(typed);
  if (text.empty() || text.find(' ') != std::string::npos) {
    return std::nullopt;
  }
  for (const char* prefix : {"http://", "https://", "file://", "birch://",
                             "sorrel://", "about:"}) {
    if (StartsWithNoCase(text, prefix)) {
      return text;
    }
  }
  static const std::regex kLocal(
      R"(^(localhost|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(:\d+)?(/.*)?$)",
      std::regex::icase);
  if (StartsWithNoCase(text, "localhost") || std::regex_match(text, kLocal)) {
    return "http://" + text;
  }
  static const std::regex kDomain(
      R"(^([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#].*)?$)");
  if (std::regex_match(ToLowerAscii(text), kDomain)) {
    return "https://" + text;
  }
  return std::nullopt;
}

std::string SearchUrl(const std::string& template_url,
                      const std::string& query) {
  static const char kHex[] = "0123456789ABCDEF";
  std::string encoded;
  for (unsigned char c : query) {
    bool keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
                c == '~';
    if (keep) {
      encoded += static_cast<char>(c);
    } else if (c == ' ') {
      encoded += '+';
    } else {
      encoded += '%';
      encoded += kHex[c >> 4];
      encoded += kHex[c & 0x0F];
    }
  }
  std::string out = template_url;
  size_t pos = out.find("%s");
  if (pos == std::string::npos) {
    return out;
  }
  return out.replace(pos, 2, encoded);
}

std::string Destination(const std::string& text,
                        const std::string& search_template) {
  if (std::optional<std::string> url = UrlFromTyped(text)) {
    return *url;
  }
  return SearchUrl(search_template, Trim(text));
}

}  // namespace birch::core
