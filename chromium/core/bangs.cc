#include "core/bangs.h"

#include <cctype>
#include <cstddef>
#include <cstring>

#include "core/codec.h"
#include "core/json.h"

namespace birch::core {

namespace {

void ReplaceAll(std::string* s, const std::string& from, const std::string& to) {
  size_t pos = 0;
  while ((pos = s->find(from, pos)) != std::string::npos) {
    s->replace(pos, from.size(), to);
    pos += to.size();
  }
}

// The host of an http(s)-style address, "" when there is none.
std::string HostOf(const std::string& url, std::string* scheme) {
  size_t colon = url.find("://");
  if (colon == std::string::npos || colon == 0) {
    return "";
  }
  for (size_t i = 0; i < colon; ++i) {  // a scheme, not "://" inside a query
    unsigned char c = static_cast<unsigned char>(url[i]);
    if (!(std::isalpha(c) || (i > 0 && (std::isdigit(c) || c == '+' || c == '-' || c == '.')))) {
      return "";
    }
  }
  if (scheme) {
    *scheme = url.substr(0, colon);
  }
  size_t start = colon + 3;
  size_t end = url.find_first_of("/?#", start);
  std::string authority = url.substr(start, end == std::string::npos ? end : end - start);
  size_t at = authority.rfind('@');
  if (at != std::string::npos) {
    authority = authority.substr(at + 1);
  }
  size_t port = authority.rfind(':');
  if (port != std::string::npos && authority.find(']') == std::string::npos) {
    authority = authority.substr(0, port);
  }
  return authority;
}

bool Ascii09AZaz(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

bool Hex(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
}

bool AllowedPunct(unsigned char c) {
  return c != 0 && std::strchr("-._~:/?@!$&'()*+,;=", c) != nullptr;
}

// One URL component the way Apple's URL(string:) writes it (observed against
// Foundation on macOS 27 for every bundled bang; the whole-table check in the
// spec proves it): a component that holds a raw character a URL may not hold
// (a space, a quote, brackets, braces, any non-ASCII byte, a stray %) is
// percent-encoded as text, "%" included; a valid one is kept as it is.
std::string Component(const std::string& in) {
  bool valid = true;
  for (size_t i = 0; i < in.size() && valid; ++i) {
    unsigned char c = static_cast<unsigned char>(in[i]);
    if (c == '%') {
      valid = i + 2 < in.size() && Hex(static_cast<unsigned char>(in[i + 1])) &&
              Hex(static_cast<unsigned char>(in[i + 2]));
    } else if (!(c < 0x80 && (Ascii09AZaz(c) || AllowedPunct(c)))) {
      valid = false;
    }
  }
  if (valid) {
    return in;
  }
  static const char kHex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : in) {
    if (c < 0x80 && (Ascii09AZaz(c) || AllowedPunct(c))) {
      out += static_cast<char>(c);
    } else {
      out += '%';
      out += kHex[c >> 4];
      out += kHex[c & 15];
    }
  }
  return out;
}

}  // namespace

std::string NormalizeUrl(const std::string& url) {
  std::string rest = url, fragment, query;
  size_t hash = rest.find('#');
  if (hash != std::string::npos) {
    fragment = "#" + Component(rest.substr(hash + 1));
    rest = rest.substr(0, hash);
  }
  size_t q = rest.find('?');
  if (q != std::string::npos) {
    query = "?" + Component(rest.substr(q + 1));
    rest = rest.substr(0, q);
  }
  std::string prefix;
  size_t scheme_end = rest.find("://");
  if (scheme_end != std::string::npos && scheme_end > 0) {
    bool scheme_ok = std::isalpha(static_cast<unsigned char>(rest[0])) != 0;
    for (size_t i = 0; i < scheme_end && scheme_ok; ++i) {
      unsigned char c = static_cast<unsigned char>(rest[i]);
      scheme_ok = Ascii09AZaz(c) || c == '+' || c == '-' || c == '.';
    }
    if (scheme_ok) {
      size_t slash = rest.find('/', scheme_end + 3);
      prefix = rest.substr(0, slash == std::string::npos ? rest.size() : slash);
      rest = slash == std::string::npos ? "" : rest.substr(slash);
    }
  }
  return prefix + Component(rest) + query + fragment;
}

std::string EncodeQuery(const std::string& query, bool space_to_plus) {
  static const char kHex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : query) {
    bool keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
                c == '~';
    if (keep) {
      out += static_cast<char>(c);
    } else if (c == ' ' && space_to_plus) {
      out += '+';
    } else {
      out += '%';
      out += kHex[c >> 4];
      out += kHex[c & 0x0F];
    }
  }
  return out;
}

void Bangs::Ingest(const std::string& json_text) {
  Json list;
  if (!ParseJson(json_text, &list) || !list.is_array()) {
    return;
  }
  for (const Json& e : list) {
    if (!e.is_object() || !e.contains("t") || !e["t"].is_string() ||
        !e.contains("u") || !e["u"].is_string()) {
      continue;
    }
    std::string t = e["t"].get<std::string>();
    std::string u = e["u"].get<std::string>();
    ReplaceAll(&u, "%s", "{{{s}}}");
    std::optional<bool> plus;
    if (e.contains("fmt") && e["fmt"].is_array()) {
      bool all_strings = true, has = false;
      for (const Json& f : e["fmt"]) {
        if (!f.is_string()) {
          all_strings = false;
        } else if (f.get<std::string>() == "url_encode_space_to_plus") {
          has = true;
        }
      }
      if (all_strings) {
        plus = has;
      }
    }
    std::string stripped = u;
    ReplaceAll(&stripped, "{{{s}}}", "");
    std::string domain = e.contains("d") && e["d"].is_string()
                             ? e["d"].get<std::string>()
                             : HostOf(stripped, nullptr);
    std::string name = e.contains("s") && e["s"].is_string()
                           ? e["s"].get<std::string>()
                           : t;
    std::vector<std::string> triggers = {t};
    if (e.contains("ts") && e["ts"].is_array()) {
      for (const Json& x : e["ts"]) {
        if (x.is_string()) {
          triggers.push_back(x.get<std::string>());
        }
      }
    }
    for (const std::string& trig : triggers) {
      Bang b;
      b.trigger = ToLowerAscii(trig);
      b.name = name;
      b.domain = domain;
      b.tmpl = u;
      b.space_to_plus = plus;
      table_[b.trigger] = std::move(b);
    }
  }
}

std::optional<BangMatch> Bangs::Resolve(const std::string& text) const {
  std::vector<std::string> words;
  for (const std::string& w : Split(text, ' ')) {
    if (!w.empty()) {
      words.push_back(w);
    }
  }
  size_t index = words.size();
  const Bang* found = nullptr;
  for (size_t i = 0; i < words.size(); ++i) {
    if (words[i].size() > 1 && words[i][0] == '!') {
      auto it = table_.find(ToLowerAscii(words[i].substr(1)));
      if (it != table_.end()) {
        index = i;
        found = &it->second;
        break;
      }
    }
  }
  if (!found) {
    return std::nullopt;
  }
  words.erase(words.begin() + static_cast<std::ptrdiff_t>(index));
  std::string query;
  for (size_t i = 0; i < words.size(); ++i) {
    query += (i ? " " : "") + words[i];
  }
  BangMatch match;
  match.bang = *found;
  match.query = query;
  if (query.empty()) {
    std::string stripped = found->tmpl;
    ReplaceAll(&stripped, "{{{s}}}", "");
    std::string scheme = "https";
    std::string host = HostOf(stripped, &scheme);
    if (host.empty()) {
      host = found->domain;
    }
    if (host.empty()) {
      return std::nullopt;
    }
    match.url = scheme + "://" + host;
    return match;
  }
  bool in_query_string = true;
  size_t marker = found->tmpl.find("{{{s}}}");
  if (marker != std::string::npos) {
    in_query_string = found->tmpl.substr(0, marker).find('?') != std::string::npos;
  }
  bool plus = found->space_to_plus.value_or(in_query_string);
  std::string url = found->tmpl;
  ReplaceAll(&url, "{{{s}}}", EncodeQuery(query, plus));
  match.url = NormalizeUrl(url);
  return match;
}

Bangs& SharedBangs() {
  static Bangs bangs;
  return bangs;
}

}  // namespace birch::core
