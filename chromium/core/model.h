// Birch's saved model: spaces, items (tabs, folders, splits), favorites and
// window selections, exactly as spec/saved-data.md describes state.json.
// Engine-free and UI-free: live pages are kept by the app, keyed by item id.
//
// Owners (CLAUDE.md ▸ Chromium edition ▸ module map): spaces, favorites,
// folders and theme fields belong to wave-3 agent 5 (cx-spaces-sidebar);
// split helpers to agent 8. Add fields only together with state_file.cc's
// decoder and encoder, and keep old files readable.
#ifndef BIRCH_CORE_MODEL_H_
#define BIRCH_CORE_MODEL_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace birch::core {

struct Theme {
  std::vector<std::string> colors;  // one to three "#RRGGBB"
  double angle = 315;               // gradient direction, degrees
  double intensity = 0.8;           // 0 = barely tinted, 1 = full colour
  std::optional<double> grain;      // nil = default grain (space-colours.md)
  std::optional<double> brightness; // nil = 0

  // Arc's palette as the Mac has it (Support.swift Theme.presets).
  static const std::vector<Theme>& Presets();
};

struct SplitLayout {
  bool stacked = false;           // false = side by side
  std::vector<double> fractions;  // each pane's share; see Normalized
  static constexpr size_t kMaxPanes = 4;

  // Shares used for |count| panes: |fractions| normalised to sum 1 when there
  // is one per pane and all are > 0, otherwise equal shares.
  std::vector<double> Normalized(size_t count) const;
};

struct Item {
  std::string id;  // uppercase UUID
  bool is_folder = false;
  std::string title;
  std::optional<std::string> custom_title;
  std::optional<std::string> url;
  std::optional<std::string> pinned_url;  // where a pinned tab returns
  std::vector<Item> children;             // folder contents or split panes
  bool expanded = true;
  int64_t last_active = 0;                // seconds since 1970, UTC
  std::optional<SplitLayout> split;

  bool IsSplit() const { return split.has_value(); }
  bool IsTab() const { return !is_folder && !split.has_value(); }
  // spec/saved-data.md ▸ displayTitle.
  std::string DisplayTitle() const;
  // The URL's host as the Mac's Item.host gives it (core/site.h UrlHost).
  std::optional<std::string> Host() const;

  static Item NewTab(const std::string& url, const std::string& title);
};

struct Space {
  std::string id;
  std::string name = "Space";
  std::string icon = "\xE2\x97\x8F";  // "●"
  Theme theme = Theme::Presets()[0];
  std::vector<Item> pinned;
  std::vector<Item> today;  // unpinned tabs, newest first
  std::optional<std::string> profile_id;   // separate logins when set
  std::optional<std::string> selected_id;
};

struct BrowserWindowState {
  std::string id;
  std::string current_space_id;
  // Saved as a flat [spaceID, tabID, spaceID, tabID, …] array.
  std::vector<std::pair<std::string, std::string>> selections;
};

struct AppState {
  int64_t version = 1;
  std::vector<Space> spaces;
  std::vector<Item> favorites;
  std::string current_space_id;
  std::optional<std::vector<BrowserWindowState>> windows;
  bool sidebar_collapsed = false;
  double sidebar_width = 250;
};

// Bundled pages (spec/saved-data.md, spec/security-invariants.md): saved as
// birch://<name>; old sorrel:// and drift:// addresses load the same page.
namespace bundled_page {
inline constexpr const char kPrefix[] = "birch://";
bool IsBundled(const std::string& address);
// An old-named bundled address under its current name; anything else
// unchanged.
std::string Current(const std::string& address);
// The form Birch saves: Current(), and "birch://name/" (as Chromium reports
// a committed bundled page) back to "birch://name".
std::string Saved(const std::string& address);
// Bundled page names are [a-z0-9-]+ (Engine.load's check on the Mac).
bool PlainNameAllowed(const std::string& name);
}  // namespace bundled_page

}  // namespace birch::core

#endif  // BIRCH_CORE_MODEL_H_
