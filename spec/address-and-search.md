# Address box, search, bangs, URL cleaning, HTTPS-first

Spec 1.0.0. Fixtures: `resolver`, `bangs`, `url-cleaner`, `site`, `https-first`. Sources: `Data.swift` (Resolver, Bangs, URLCleaner), `Peek.swift` (Site), `Web.swift` (Engine.canUpgrade, navigation policy), `Sidebar.swift` (address pill).

URL strings in fixtures are the final address Birch loads (`absoluteString`). Where an edition's URL library formats differently (e.g. adds a trailing `/` to `https://example.com`), normalize the same way in the test runner and say so; the loaded page must be the same.

## Typed text → destination (`resolver`)

Order: **bang, then address, then search** (`Resolver.destination`).

1. **Bang**: see below. Applies anywhere in the text.
2. **Address** (`url(fromTyped:)`), after trimming whitespace and newlines; any space inside → not an address:
   - starts (case-insensitively) with `http://`, `https://`, `file://`, `birch://`, `sorrel://` or `about:` → used as typed (`drift://` is not on this list and searches);
   - starts with `localhost`, or is a dotted quad `d{1,3}.d{1,3}.d{1,3}.d{1,3}` with optional `:port` and `/path` → `http://` + text (no range check: `999.1.1.1` counts);
   - matches `^([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#].*)?$` on the lowercased text → `https://` + text as typed. ASCII only: `bücher.de` searches; `node.js` and `readme.md` open as sites; `example.com.` searches.
3. **Search**: the default engine template (`searchEngineURL`, `%s` replaced). The query is percent-encoded keeping only `A–Z a–z 0–9 - . _ ~` and Unicode letters/digits as Swift's `alphanumerics` set does, then `%20` → `+`; the final URL string percent-encodes any remaining non-ASCII as UTF-8 (fixture outputs are the exact strings). An empty query gives `…?q=`.

The command bar additionally shows open tabs, history matches (`History.topHostMatch`: text of 2+ characters with no space, the best-scoring page whose host without `www.` starts with it) and, only when `searchSuggestions` is on, the engine's suggestions. Pressing Return with no row chosen uses `destination`.

## Bangs (`bangs`)

- The bundled list is `Resources/bangs.json` (Kagi's list, slimmed; vendor/kagi-bangs, MIT). Editions bundle the **same file**. Loading: every entry with `t` and `u`; triggers = `t` plus `ts`, **lowercased**; a later entry with the same trigger replaces an earlier one; then custom bangs (saved-data.md) override. `%s` in a template is treated as `{{{s}}}`.
- Name = `s`, else the trigger. Domain = `d`, else the template's host.
- Resolution: split the text on spaces (runs of spaces collapse); the **first word** that is `!` + a known trigger (case-insensitive, at least one character after `!`) is the bang; the remaining words joined by single spaces are the query. Unknown `!words` stay in the query.
- Empty query → `scheme://host` of the template (no path, no trailing slash); scheme defaults to https, host to the domain.
- Otherwise: percent-encode the query (same allowed set as search), then turn `%20` into `+` if the entry's `fmt` contains `url_encode_space_to_plus`, or, when there is no `fmt` at all, if the template has a `?` before the placeholder. An entry with `fmt` but without that flag keeps `%20`. Substitute and parse.
- Whole-table check: `bangs.json ▸ table` gives the trigger count (13,641) and the SHA-256 of every trigger resolved twice (format in the fixture). Generate the same lines from your table and compare the hash; on a mismatch, regenerate `bangs-all.tsv` with the Mac hook and diff.

## Tracking parameters (`url-cleaner`)

Only for `http`/`https` URLs with a query. A parameter is dropped when its name, lowercased and still percent-encoded, is one of `fbclid gclid gclsrc dclid gbraid wbraid msclkid yclid twclid ttclid igshid mc_eid mc_cid _hsenc _hsmi __hssc __hstc __hsfp hsctatracking mkt_tok oly_enc_id oly_anon_id vero_id vero_conv s_cid _openstat li_fat_id rb_clickid srsltid ml_subscriber ml_subscriber_hash`, starts with `utm_`, `pk_`, `piwik_` or `mtm_`, or is `si` on a host ending in `youtube.com`, `youtu.be` or `spotify.com` (a plain suffix match: `notyoutube.com` counts). Everything else (order, encoding, empty `&&` pairs, the fragment) stays byte for byte. No parameter left → no `?`. Nothing removed → `null` (load unchanged).

Applied when `stripTrackingParameters` is on, to main-frame GET navigations from a link click or "other" (typed, redirects, bookmarks), after the HTTPS-first step: Birch cancels and reloads the cleaned URL.

## What the address box shows (`site`)

- Bundled pages (`birch://`, `sorrel://`, `drift://`) show **Birch**, with no copy button.
- Otherwise the tab's host, with only a **leading** `www.` removed (case-insensitive; `www2.`, `pwww.` and inner `www.` stay; `www.www.x` → `www.x`). No host → the full saved address. Nothing → placeholder "Search or enter address".
- Hosts are shown in their ASCII (punycode) form whenever the URL holds them that way. On the Mac, a saved Unicode host is converted by the URL parser (`https://bücher.example/` → `xn--bcher-kva.example`); WebKit itself reports committed URLs in punycode. Editions must show the **committed** URL's real host in punycode for any non-ASCII label (security-invariants.md); Chromium's own IDN display policy is not sufficient on its own.
- Long hosts are cut at the **front** (`…secure-login.evil.example`), so the registrable end always shows. Layout rule, no fixture.
- An orange open lock appears when the page address starts with `http://` and has a host. A copy button appears on hover for http(s) addresses.

`Site.key` (the rough "same website" key used by Peek, Forget This Site and history removal): lowercase host; ≤ 2 labels → the host; else the last 3 labels when the last is 2 letters and the second-last is one of `co com org net ac gov edu`, otherwise the last 2. Known quirk, reproduce it: IPv4 addresses key by their last two octets (`192.168.1.1` → `1.1`).

`Site.host(_:isIn:)` (Peek exclusions): entries are lowercased and trimmed; empty entries are skipped; an entry with a dot matches that host and its subdomains; an entry without a dot ("google") matches when the first label of the host's key equals it (google.com, google.co.uk, scholar.google.com; not googleblog.com).

## HTTPS-first (`https-first`)

When `httpsFirst` is on, a **main-frame GET** navigation to `http://` whose host can be upgraded and isn't allowed for this session is cancelled and retried as `https://` (same URL, explicit port 80 removed). If the https load fails, or redirects straight back to `http://` on the same host, Birch shows its own "doesn't offer a secure connection" page under the http address, with Go Back and "Continue to <host>". Continue allows that host over http until the app quits (security-invariants.md: it works only from that warning, while it is showing).

`canUpgrade` (exact):
- the host must contain a dot;
- an explicit port other than 80 → never (even 443);
- hosts ending in `.local .localhost .test .internal .lan .home .arpa .example .invalid` → never;
- IPv6 literals and all-digits-and-dots hosts (IPv4) → never;
- everything else (including uppercase hosts, punycode, trailing-dot hosts, `1.2.3.4.nip.io`) → upgrade.

Also on regardless of the setting: WebKit's own known-HSTS upgrade (`upgradeKnownHostsToHTTPS`). Chromium has its own HSTS preload list; keep it on.
