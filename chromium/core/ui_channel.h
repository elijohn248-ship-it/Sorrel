// The UI-only channel's message list (owner-approved exception to AGENTS.md
// rule 4, 2026-11-25; limits in CLAUDE.md ▸ Chromium edition ▸ UI host).
// Engine-free: engine/ checks WHO sent a message (only a UI browser's main
// frame on its own birch-ui:// page); this file checks WHAT was sent. Every
// message from a UI page is a fixed name plus one JSON object whose keys and
// types are listed here; anything else is refused. No message runs script,
// touches files or returns page content.
//
// App -> UI data is built here too, as JSON (never as JavaScript source).
//
// Owner: shared. Wave-3 agents add their own names (one line in kSchemas in
// ui_channel.cc, a Kind and a field if needed) and say so in their handoff.
#ifndef BIRCH_CORE_UI_CHANNEL_H_
#define BIRCH_CORE_UI_CHANNEL_H_

#include <optional>
#include <string>
#include <vector>

#include "core/site.h"
#include "core/store.h"

namespace birch::core::ui_channel {

// Hard limits, checked before parsing.
constexpr size_t kMaxNameBytes = 40;
constexpr size_t kMaxArgsBytes = 16 * 1024;
constexpr size_t kMaxTextBytes = 4096;

// UI -> app.
enum class Kind {
  kUpdateCheck, kUpdateInstall, kUpdateAutomatic,
  kSidebarAction,   // sidebar.action: typed sidebar operation
  kUiReady,         // ui.ready        {}
  kTabSelect,       // tab.select      {id: uuid}
  kTabClose,        // tab.close       {id: uuid}
  kTabNew,          // tab.new         {}            (the "+ New Tab" row)
  kNavBack,         // nav.back        {}
  kNavForward,      // nav.forward     {}
  kNavReload,       // nav.reload      {}
  kAddressSubmit,   // address.submit  {text: string}
  kAddressCancel,   // address.cancel  {}            (Escape: back to the page)
  kAddressBlur,     // address.blur    {}            (focus left the field)
};

struct Message {
  Kind kind = Kind::kUiReady;
  std::string name;
  std::string id;    // tab.select / tab.close: an item id, uppercase UUID
  std::string text;  // address.submit
  std::string action, target, extra;
  size_t index = 0;
  double value = 0;
  bool enabled = false;
};

struct ParseResult {
  std::optional<Message> message;
  std::string error;  // why it was refused (for the log; no argument values)
};

// Validates one message from a UI page. |args_json| must be a JSON object
// with exactly the keys the name allows, each of the right type and size.
ParseResult Parse(const std::string& name, const std::string& args_json);

// Every accepted name, in order (tests, docs).
std::vector<std::string> Names();

// ---- app -> UI ---------------------------------------------------------------------------

// What the sidebar shows. Only what is on screen: titles, ids, the address
// box text (real origin) and the selected tab's full address for editing.
struct SidebarState {
  std::string space_title;
  std::vector<Space> spaces;
  std::string current_space, sidebar_mode = "pinned";
  Theme theme;
  bool native_hover = false;
  double reveal_width = 14, overshoot = 90, hide_delay = .12, slide_speed = .2;
  bool is_private = false;
  std::vector<std::string> colors;  // the space's "#RRGGBB" colours
  std::string background;           // "#RRGGBB": the page card's surround
  std::vector<SidebarRow> rows;
  std::string selected_id;
  AddressBox address;
  std::string full_url;  // the selected tab's address, for editing
  bool can_go_back = false;
  bool can_go_forward = false;
  bool can_reload = false;
  bool loading = false;
};
// {"space":{…},"rows":[…],"selected":…,"address":{…},"nav":{…}}
std::string SidebarStateJson(const SidebarState& state);
// {"newTab":bool,"full":"…"}: put the keyboard in the address field.
std::string FocusAddressJson(bool new_tab, const std::string& full_url);

// The window colour around the page card for |colors| (a light tint of the
// space's last colour; private windows are dark). Shared by the sidebar's
// gradient (its right edge) and the native panel behind the page.
std::string SurroundColor(const std::vector<std::string>& colors,
                          bool is_private);

// A JSON string literal for |text| (tests build fixed DevTools expressions
// with it; app code never builds script).
std::string JsonQuote(const std::string& text);

}  // namespace birch::core::ui_channel

#endif  // BIRCH_CORE_UI_CHANNEL_H_
