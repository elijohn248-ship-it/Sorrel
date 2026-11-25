// settings.json, per spec/saved-data.md ▸ settings.json (fixtures:
// settings-fields, settings-decode). Every field the Mac has is here, so wave-3
// agents read settings without touching this file. To add a setting: one line
// in BIRCH_SETTINGS_FIELDS (name, type, default), with a privacy-safe
// default; old files without it then read the default.
#ifndef BIRCH_CORE_SETTINGS_H_
#define BIRCH_CORE_SETTINGS_H_

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace birch::core {

using StringList = std::vector<std::string>;
using BoolMap = std::map<std::string, bool>;
using StringListMap = std::map<std::string, StringList>;

// X(type, jsonName, default). Types: String, Bool, Double, Int, StringList,
// BoolMap, StringListMap. Edition-specific fields (fallbackBrowser,
// extension*) are kept so the file round-trips.
#define BIRCH_SETTINGS_FIELDS(X)                                               \
  X(String, searchEngineName, "DuckDuckGo")                                    \
  X(String, searchEngineURL, "https://duckduckgo.com/?q=%s")                   \
  X(Bool, stripTrackingParameters, true)                                       \
  X(Bool, httpsFirst, true)                                                    \
  X(Bool, blockAds, true)                                                      \
  X(Bool, blockCookieNotices, false)                                           \
  X(StringList, blockingDisabledSites, {})                                     \
  X(Double, sleepTabsAfterMinutes, 120)                                        \
  X(Bool, searchSuggestions, false)                                            \
  X(Bool, autoUpdateBlocker, true)                                             \
  X(Bool, checkForUpdates, true)                                               \
  X(Bool, installUpdatesAutomatically, false)                                  \
  X(BoolMap, extensionStates, {})                                              \
  X(StringListMap, extensionGrants, {})                                        \
  X(StringListMap, extensionApproved, {})                                      \
  X(Double, archiveAfterHours, 24)                                             \
  X(Bool, controlTabUsesRecency, true)                                         \
  X(Double, removeHistoryAfterDays, 0)                                         \
  X(Bool, emptyCacheOnQuit, false)                                             \
  X(String, fallbackBrowser, "Helium")                                         \
  X(Bool, externalLinksOpenInMiniWindow, true)                                 \
  X(Bool, peekLinksFromAllTabs, true)                                          \
  X(Bool, peekLinksFromPinnedTabs, true)                                       \
  X(StringList, peekExcludedSites,                                             \
    (StringList{"google", "bing", "yahoo", "yandex", "baidu",                 \
                "duckduckgo.com", "search.brave.com", "kagi.com",              \
                "startpage.com", "ecosia.org", "qwant.com", "perplexity.ai",   \
                "mojeek.com", "search.marginalia.nu"}))                        \
  X(Double, sidebarHoverEdgeWidth, 14)                                         \
  X(Double, sidebarOvershootReach, 90)                                         \
  X(Int, settingsVersion, 2)                                                   \
  X(Double, sidebarHideDelay, 0.12)                                            \
  X(Double, sidebarExitTolerance, 14)                                          \
  X(Double, sidebarAnimationDuration, 0.2)                                     \
  X(Bool, sidebarHoverWhenInactive, true)

namespace settings_types {
using String = std::string;
using Bool = bool;
using Double = double;
using Int = int64_t;
using StringList = birch::core::StringList;
using BoolMap = birch::core::BoolMap;
using StringListMap = birch::core::StringListMap;
}  // namespace settings_types

struct Settings {
#define BIRCH_SETTINGS_MEMBER(type, name, def) settings_types::type name = def;
  BIRCH_SETTINGS_FIELDS(BIRCH_SETTINGS_MEMBER)
#undef BIRCH_SETTINGS_MEMBER
};

inline constexpr const char kSettingsFileName[] = "settings.json";

// Decodes settings.json text: a missing or null key takes its default
// (settingsVersion reads as 1 when missing); a wrong type anywhere or invalid
// JSON fails the whole file.
bool DecodeSettings(const std::string& text, Settings* out, std::string* error);
// Pretty-printed, sorted keys, all fields.
std::string EncodeSettings(const Settings& s);

struct SettingsLoad {
  Settings loaded;                  // what Birch runs with
  std::optional<Settings> decoded;  // before migration; nullopt on failure
  std::string decode_error;
  bool file_existed = false;
  bool file_rewritten = false;
  std::string backup_path;  // an unreadable file is kept aside before reset
};
// Settings.load: missing file -> defaults, written; unreadable -> defaults,
// written (the old file is copied to settings.unreadable-<unix>.json first, a
// Chromium-edition safeguard the Mac lacks); settingsVersion < 2 -> the 8 pt
// reveal strip becomes 14, version 2, written.
SettingsLoad LoadSettings(const std::string& profile_dir);
bool SaveSettings(const std::string& profile_dir, const Settings& s);

// For tests: every field's JSON name and Swift type name, in table order.
struct SettingsFieldInfo {
  const char* name;
  const char* swift_type;
};
std::vector<SettingsFieldInfo> SettingsFields();

}  // namespace birch::core

#endif  // BIRCH_CORE_SETTINGS_H_
