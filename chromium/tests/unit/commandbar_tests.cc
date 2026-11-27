// The command bar's engine-free parts: the Windows/Linux shortcut table,
// chords, suggestions and the JSON the page receives (no CEF).
//   birch_commandbar_tests   -> "commandbar: <what> expected=… got=… -> PASS|FAIL"
#include <cstdio>
#include <set>
#include <string>

#include "core/bangs.h"
#include "core/commands.h"
#include "core/keybindings.h"
#include "core/suggest.h"
#include "core/ui_channel.h"

namespace {

int g_checks = 0, g_failed = 0;

void Check(const std::string& what, const std::string& expected, const std::string& got) {
  ++g_checks;
  bool ok = expected == got;
  g_failed += ok ? 0 : 1;
  std::printf("commandbar: %s expected=%s got=%s -> %s\n", what.c_str(), expected.c_str(),
              got.c_str(), ok ? "PASS" : "FAIL");
}

std::string N(size_t n) { return std::to_string(n); }

}  // namespace

int main() {
  using namespace birch::core;

  // ---- the Windows/Linux defaults -------------------------------------------------
  {
    std::set<std::string> ids;
    for (const CommandInfo& c : AllCommands()) ids.insert(c.id);
    size_t unnormalized = 0, unknown = 0, clashes = 0;
    std::set<std::string> seen;
    for (const auto& d : Keybindings::PcDefaults()) {
      auto seq = Keybindings::NormalizeSequence(d.first);
      std::string joined;
      for (const auto& s : seq) joined += s + " ";
      if (seq.size() != 1 || seq[0] != d.first) ++unnormalized;
      if (!ids.count(d.second)) ++unknown;
      if (!seen.insert(d.first).second) ++clashes;
    }
    Check("PC defaults are normalized strokes", "0", N(unnormalized));
    Check("PC defaults name known commands", "0", N(unknown));
    Check("PC defaults never reuse a stroke", "0", N(clashes));
    Keybindings kb(Keybindings::PcDefaults());
    Check("Ctrl+T is tab.new", "tab.new", kb.CommandOnStroke("ctrl+t").value_or("-"));
    Check("Ctrl+L is tab.editURL", "tab.editURL", kb.CommandOnStroke("ctrl+l").value_or("-"));
    Check("Ctrl+Tab is tab.cycleNext", "tab.cycleNext", kb.CommandOnStroke("ctrl+tab").value_or("-"));
    Check("Ctrl+Shift+Tab is tab.cyclePrevious", "tab.cyclePrevious",
          kb.CommandOnStroke("ctrl+shift+tab").value_or("-"));
    Check("Ctrl+1 is the first favorite or pinned tab", "tab.select.1", kb.CommandOnStroke("ctrl+1").value_or("-"));
    Check("Alt+1 is the first space", "space.1", kb.CommandOnStroke("alt+1").value_or("-"));
    Check("Windows/Super is never used by a default", "0", N([&] {
            size_t n = 0;
            for (const auto& d : Keybindings::PcDefaults()) n += d.first.find("cmd") != std::string::npos;
            return n;
          }()));
    Check("PC display", "Ctrl+Shift+T", Keybindings::Pretty("ctrl+shift+t", StrokeStyle::kPc));
    Check("PC display of Ctrl+Tab", "Ctrl+Tab", kb.DisplayAll("tab.cycleNext", StrokeStyle::kPc));
    kb.Reload("{\"ctrl+t\": null, \"ctrl+alt+j\": \"tab.new\"}");
    Check("keybindings.json can move a command", "tab.new", kb.CommandOnStroke("ctrl+alt+j").value_or("-"));
    Check("keybindings.json can switch a default off", "-", kb.CommandOnStroke("ctrl+t").value_or("-"));
  }

  // ---- chords (the Mac table has two) ---------------------------------------------
  {
    Keybindings kb(Keybindings::MacDefaults());
    std::string cmd;
    auto r1 = kb.OnStroke("cmd+k", 1000, &cmd);
    Check("first stroke of a chord is pending", "pending", r1 == Keybindings::Dispatch::kPending ? "pending" : "other");
    auto r2 = kb.OnStroke("cmd+t", 1500, &cmd);
    Check("second stroke runs the chord", "theme.edit", r2 == Keybindings::Dispatch::kRun ? cmd : "other");
    kb.OnStroke("cmd+k", 5000, &cmd);
    auto r3 = kb.OnStroke("cmd+t", 7000, &cmd);  // 2 s later: too late, runs tab.new alone
    Check("a late second stroke is its own shortcut", "tab.new", r3 == Keybindings::Dispatch::kRun ? cmd : "other");
    kb.OnStroke("cmd+k", 9000, &cmd);
    auto r4 = kb.OnStroke("cmd+d", 9100, &cmd);
    Check("a stroke that does not continue the chord is tried alone", "tab.togglePin",
          r4 == Keybindings::Dispatch::kRun ? cmd : "other");
    auto r5 = kb.OnStroke("cmd+q", 9200, &cmd);
    Check("an unbound stroke is not ours", "none", r5 == Keybindings::Dispatch::kNone ? "none" : "other");
  }

  // ---- suggestions ----------------------------------------------------------------
  {
    Bangs bangs;
    bangs.Ingest("[{\"t\":\"w\",\"s\":\"Wikipedia\",\"u\":\"https://wikipedia.org/w/index.php?search={{{s}}}\"}]");
    SuggestInput in;
    in.bangs = &bangs;
    in.now = 2000000000;
    in.selected_id = "A";
    in.tabs = {{"A", "Current", "https://current.example/", "Home", 5},
               {"B", "Cat pictures", "https://cats.example/", "Home", 9},
               {"C", "Dog news", "https://dogs.example/", "Lab", 8}};
    in.recent = {"A", "B", "C"};
    HistoryEntry h;
    h.url = "https://catalog.example/";
    h.title = "Catalog";
    h.visits = 4;
    h.last = in.now - 3600;
    in.history = {h};
    in.commands = {{"tab.new", "New Tab", "Ctrl+T"}, {"nav.back", "Back", "Alt+Left"}};

    in.text = "";
    auto r = Suggest(in);
    Check("empty bar lists recent tabs without the current one", "tab:B|tab:C",
          r.size() == 2 ? r[0].key + "|" + r[1].key : N(r.size()));
    in.text = "!w cats";
    r = Suggest(in);
    Check("a bang comes first", "bang", r.empty() ? "-" : r[0].kind);
    Check("the bang's address is held by the app, not the page", "https://wikipedia.org/w/index.php?search=cats",
          r.empty() ? "-" : r[0].target);
    in.text = "example.com/x";
    r = Suggest(in);
    Check("an address then a search", "address|search", r.size() >= 2 ? r[0].kind + "|" + r[1].kind : "-");
    Check("the address row opens https", "https://example.com/x", r.empty() ? "-" : r[0].target);
    in.text = "cat";
    r = Suggest(in);
    std::string kinds;
    for (const auto& x : r) kinds += x.kind + ",";
    Check("a word: top host match, search, matching tab", "url,search,tab,", kinds);
    in.text = "back";
    r = Suggest(in);
    Check("commands match by title", "command", r.empty() ? "-" : r.back().kind);
    Check("a command row carries its shortcut", "Alt+Left", r.empty() ? "-" : r.back().hint);
    in.text = "cat";
    std::string json = birch::core::ui_channel::CommandBarResultsJson("cat", Suggest(in));
    Check("the page's JSON holds no address or id", "no", json.find("https://") == std::string::npos &&
                                                               json.find("target") == std::string::npos
                                                           ? "no" : "yes");
    std::set<std::string> keys;
    in.text = "a";
    for (const auto& x : Suggest(in)) keys.insert(x.key);
    Check("row keys are unique", N(Suggest(in).size()), N(keys.size()));
  }

  std::printf("commandbar: summary checks=%d failed=%d\n", g_checks, g_failed);
  return g_failed == 0 ? 0 : 1;
}
