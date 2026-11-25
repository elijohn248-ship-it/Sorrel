#include "core/site.h"

#include <cstdint>

#include "core/codec.h"
#include "core/model.h"

namespace birch::core {

namespace {

bool DecodeUtf8(const std::string& s, std::u32string* out) {
  out->clear();
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    char32_t cp = 0;
    size_t extra = 0;
    if (c < 0x80) {
      cp = c;
    } else if ((c & 0xE0) == 0xC0) {
      cp = c & 0x1F;
      extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
      cp = c & 0x0F;
      extra = 2;
    } else if ((c & 0xF8) == 0xF0) {
      cp = c & 0x07;
      extra = 3;
    } else {
      return false;
    }
    for (size_t k = 1; k <= extra; ++k) {
      if (i + k >= s.size()) {
        return false;
      }
      unsigned char cc = static_cast<unsigned char>(s[i + k]);
      if ((cc & 0xC0) != 0x80) {
        return false;
      }
      cp = (cp << 6) | (cc & 0x3F);
    }
    out->push_back(cp);
    i += extra + 1;
  }
  return true;
}

char PunyDigit(uint32_t d) {
  return static_cast<char>(d < 26 ? 'a' + d : '0' + (d - 26));
}

uint32_t Adapt(uint32_t delta, uint32_t points, bool first) {
  delta = first ? delta / 700 : delta / 2;
  delta += delta / points;
  uint32_t k = 0;
  while (delta > ((36 - 1) * 26) / 2) {
    delta /= 36 - 1;
    k += 36;
  }
  return k + (36 * delta) / (delta + 38);
}

// RFC 3492 encoding of one label (without the "xn--" prefix).
bool PunycodeEncode(const std::u32string& in, std::string* out) {
  std::string o;
  for (char32_t c : in) {
    if (c < 0x80) {
      o += static_cast<char>(c);
    }
  }
  const uint32_t b = static_cast<uint32_t>(o.size());
  uint32_t h = b;
  if (b > 0) {
    o += '-';
  }
  uint32_t n = 128, delta = 0, bias = 72;
  const uint32_t len = static_cast<uint32_t>(in.size());
  while (h < len) {
    uint32_t m = UINT32_MAX;
    for (char32_t c : in) {
      if (c >= n && c < m) {
        m = c;
      }
    }
    if (m - n > (UINT32_MAX - delta) / (h + 1)) {
      return false;  // overflow
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (char32_t c : in) {
      if (c < n) {
        ++delta;
      }
      if (c == n) {
        uint32_t q = delta;
        for (uint32_t k = 36;; k += 36) {
          uint32_t t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias);
          if (q < t) {
            break;
          }
          o += PunyDigit(t + (q - t) % (36 - t));
          q = (q - t) / (36 - t);
        }
        o += PunyDigit(q);
        bias = Adapt(delta, h + 1, h == b);
        delta = 0;
        ++h;
      }
    }
    ++delta;
    ++n;
  }
  *out = o;
  return true;
}

}  // namespace

std::string PunycodeHost(const std::string& host) {
  std::string out;
  for (const std::string& label : Split(host, '.')) {
    bool ascii = true;
    for (char c : label) {
      ascii = ascii && static_cast<unsigned char>(c) < 0x80;
    }
    std::string converted = label;
    if (!ascii) {
      std::u32string cps;
      std::string encoded;
      if (!DecodeUtf8(ToLowerAscii(label), &cps) ||
          !PunycodeEncode(cps, &encoded)) {
        return host;
      }
      converted = "xn--" + encoded;
    }
    out += converted;
    out += '.';
  }
  out.pop_back();  // Split always yields at least one label
  return out;
}

std::optional<std::string> UrlHost(const std::string& url) {
  // scheme ":" "//" authority
  size_t colon = url.find(':');
  if (colon == std::string::npos || colon == 0) {
    return std::nullopt;
  }
  for (size_t i = 0; i < colon; ++i) {
    char c = url[i];
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (i > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' ||
                         c == '.'));
    if (!ok) {
      return std::nullopt;
    }
  }
  if (url.compare(colon + 1, 2, "//") != 0) {
    return std::nullopt;
  }
  size_t start = colon + 3;
  size_t end = url.find_first_of("/?#", start);
  std::string authority =
      url.substr(start, end == std::string::npos ? std::string::npos
                                                 : end - start);
  for (char c : authority) {
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      return std::nullopt;  // URL(string:) refuses unencoded spaces
    }
  }
  size_t at = authority.rfind('@');
  if (at != std::string::npos) {
    authority = authority.substr(at + 1);
  }
  std::string host;
  if (!authority.empty() && authority[0] == '[') {
    size_t close = authority.find(']');
    if (close == std::string::npos) {
      return std::nullopt;
    }
    host = authority.substr(1, close - 1);
  } else {
    size_t port = authority.rfind(':');
    host = port == std::string::npos ? authority : authority.substr(0, port);
  }
  if (host.empty()) {
    return std::nullopt;
  }
  return PunycodeHost(host);
}

std::optional<std::string> SiteKey(const std::optional<std::string>& host) {
  if (!host || host->empty()) {
    return std::nullopt;
  }
  std::string h = ToLowerAscii(*host);
  std::vector<std::string> labels;
  for (const std::string& l : Split(h, '.')) {
    if (!l.empty()) {
      labels.push_back(l);  // Swift's split drops empty pieces
    }
  }
  if (labels.size() <= 2) {
    return h;
  }
  static const char* const kSecondLevel[] = {"co",  "com", "org", "net",
                                             "ac",  "gov", "edu"};
  const std::string& last = labels.back();
  const std::string& second = labels[labels.size() - 2];
  bool second_level = false;
  for (const char* s : kSecondLevel) {
    second_level = second_level || second == s;
  }
  // Swift counts Characters; for these ASCII-ish labels bytes match unless
  // the label is non-ASCII, which keys use in punycode form anyway.
  size_t take = (last.size() == 2 && second_level) ? 3 : 2;
  std::string out;
  for (size_t i = labels.size() - take; i < labels.size(); ++i) {
    out += (out.empty() ? "" : ".") + labels[i];
  }
  return out;
}

bool SiteHostIsIn(const std::optional<std::string>& host,
                  const std::vector<std::string>& list) {
  if (!host || host->empty()) {
    return false;
  }
  std::string h = ToLowerAscii(*host);
  std::optional<std::string> key = SiteKey(h);
  std::string brand = key ? Split(*key, '.')[0] : std::string();
  for (const std::string& raw : list) {
    std::string entry = TrimSpaces(ToLowerAscii(raw));
    if (entry.empty()) {
      continue;
    }
    if (entry.find('.') != std::string::npos) {
      if (h == entry || EndsWith(h, "." + entry)) {
        return true;
      }
    } else if (key && brand == entry) {
      return true;
    }
  }
  return false;
}

std::optional<std::string> SiteDisplay(const std::optional<std::string>& host) {
  if (!host) {
    return std::nullopt;
  }
  if (StartsWithNoCase(*host, "www.")) {
    return host->substr(4);
  }
  return host;
}

bool SiteSame(const std::optional<std::string>& a,
              const std::optional<std::string>& b) {
  std::optional<std::string> ka = SiteKey(a), kb = SiteKey(b);
  return ka && kb && *ka == *kb;
}

AddressBox AddressBoxFor(const std::optional<std::string>& url) {
  AddressBox box;
  if (url) {
    box.host = UrlHost(*url);
  }
  if (url && bundled_page::IsBundled(*url)) {
    box.text = "Birch";
    box.is_bundled = true;
    return box;
  }
  std::optional<std::string> shown = SiteDisplay(box.host);
  box.text = shown ? shown : url;
  box.can_copy = url && StartsWith(*url, "http");
  box.not_secure_lock =
      box.host.has_value() && url && StartsWith(ToLowerAscii(*url), "http://");
  return box;
}

}  // namespace birch::core
