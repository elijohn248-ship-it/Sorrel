// What the address box shows, and the rough "same website" key. Spec:
// spec/address-and-search.md ▸ "What the address box shows (site)"; fixtures:
// spec/fixtures/site.json. Security invariant: the address box shows the
// committed URL's real host, non-ASCII labels as punycode, only a leading
// "www." dropped.
#ifndef BIRCH_CORE_SITE_H_
#define BIRCH_CORE_SITE_H_

#include <optional>
#include <string>
#include <vector>

namespace birch::core {

// The host of a stored address, as the Mac's URL(string:)?.host gives it:
// no scheme authority or an empty host -> nullopt; user info and port
// dropped; IPv6 brackets removed; any non-ASCII label converted to punycode
// (ASCII case is kept, as Foundation keeps it). In the running browser the
// committed URL comes from Chromium already canonicalised (lowercase,
// punycode), so this only matters for saved addresses.
std::optional<std::string> UrlHost(const std::string& url);

// Converts each non-ASCII label of |host| to "xn--…" (RFC 3492). ASCII letters
// in such labels are lowercased first. Invalid UTF-8 is returned unchanged.
std::string PunycodeHost(const std::string& host);

// Site.key: lowercase host; <= 2 labels -> the host; else the last 3 labels
// when the last is 2 characters and the second-last is co/com/org/net/ac/
// gov/edu, otherwise the last 2. Empty or missing host -> nullopt.
std::optional<std::string> SiteKey(const std::optional<std::string>& host);
// Site.host(_:isIn:) (Peek exclusions).
bool SiteHostIsIn(const std::optional<std::string>& host,
                  const std::vector<std::string>& list);
// Site.display: only a leading "www." (any case) is removed.
std::optional<std::string> SiteDisplay(const std::optional<std::string>& host);
bool SiteSame(const std::optional<std::string>& a,
              const std::optional<std::string>& b);

// The address box for a tab whose address is |url| (nullopt = no page).
struct AddressBox {
  // nullopt = show the placeholder "Search or enter address".
  std::optional<std::string> text;
  std::optional<std::string> host;
  bool not_secure_lock = false;  // orange open lock: http:// with a host
  bool can_copy = false;         // copy button for http(s) addresses
  bool is_bundled = false;       // Birch's own page: text is "Birch"
};
AddressBox AddressBoxFor(const std::optional<std::string>& url);

}  // namespace birch::core

#endif  // BIRCH_CORE_SITE_H_
