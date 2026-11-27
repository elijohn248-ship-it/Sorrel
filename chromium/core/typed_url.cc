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
      return NormalizeUrl(text);
    }
  }
  static const std::regex kLocal(
      R"(^(localhost|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(:\d+)?(/.*)?$)",
      std::regex::icase);
  if (StartsWithNoCase(text, "localhost") || std::regex_match(text, kLocal)) {
    return NormalizeUrl("http://" + text);
  }
  static const std::regex kDomain(
      R"(^([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#].*)?$)");
  if (std::regex_match(ToLowerAscii(text), kDomain)) {
    return NormalizeUrl("https://" + text);
  }
  return std::nullopt;
}

std::string SearchUrl(const std::string& template_url,
                      const std::string& query) {
  std::string encoded = EncodeQuery(query, /*space_to_plus=*/true);
  std::string out = template_url;
  size_t pos = 0;
  while ((pos = out.find("%s", pos)) != std::string::npos) {
    out.replace(pos, 2, encoded);
    pos += encoded.size();
  }
  return NormalizeUrl(out);
}

std::string Destination(const std::string& text,
                        const std::string& search_template,
                        const Bangs* bangs) {
  if (bangs) {
    if (std::optional<BangMatch> m = bangs->Resolve(text)) {
      return m->url;
    }
  }
  if (std::optional<std::string> url = UrlFromTyped(text)) {
    return *url;
  }
  return SearchUrl(search_template, Trim(text));
}

}  // namespace birch::core
