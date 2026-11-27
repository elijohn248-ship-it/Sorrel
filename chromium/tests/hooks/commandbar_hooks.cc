// App-level checks for the command bar, bangs, shortcuts and Control+Tab
// (wave 3, agent 6): BIRCH_TEST=commandbar. Typing is done through the bar
// page's own handlers (DevTools evaluates fixed expressions); only the local
// fixture server is used (a custom bang points at it, so no search engine is
// contacted). Real keyboard routing and typing feel are owner checks.
#include "tests/hooks/hooks.h"

#include <algorithm>
#include <cstdlib>
#include <set>

#include "core/codec.h"
#include "core/json.h"
#include "engine/ui_page.h"
#include "platform/platform.h"
#include "ui/main_window.h"

namespace birch::tests {

namespace {

struct Ids {
  std::string t1, t2, t3, t4, bg, extra;
  std::string order_join;
};

ui::MainWindow* M() { return Main(); }

engine::UiPage* BarPage() { return M() ? M()->command_bar_page() : nullptr; }

void Check(const std::string& what, bool ok) {
  Expect("commandbar", what, "yes", YesNo(ok));
}

void BarEval(const std::string& name, const std::string& key, const std::string& expression,
             int timeout = 15000) {
  UiEvalStep(name, BarPage, key, expression, timeout);
}

// Polls |condition| (JS) in the bar page for up to 6 s, then yields |result|.
std::string WaitFor(const std::string& condition, const std::string& result) {
  return "new Promise(function(done){var n=0;(function go(){if(!(" + condition +
         ")&&n++<60){setTimeout(go,100);return}done(" + result + ")})()})";
}

std::string Type(const std::string& text) {
  return "(function(){var i=document.getElementById('text');i.focus();i.value=" +
         core::ui_channel::JsonQuote(text) +
         ";i.dispatchEvent(new Event('input',{bubbles:true}));return 'typed'})()";
}

std::string Key(const std::string& key, int times = 1) {
  return "(function(){var i=document.getElementById('text');for(var k=0;k<" + std::to_string(times) +
         ";k++)i.dispatchEvent(new KeyboardEvent('keydown',{key:" + core::ui_channel::JsonQuote(key) +
         ",bubbles:true}));return 'sent'})()";
}

const char kTileIds[] =
    "[].map.call(document.querySelectorAll('#tiles .tile'),function(e){return e.dataset.id}).join('|')";

bool SelectedAndSettled(const std::string& id) {
  return M()->selected_id() == id && Settled(SelectedPage(M()));
}

}  // namespace

BIRCH_TEST_SCENARIO(commandbar) {
  const auto ids = std::make_shared<Ids>();
  const std::string a = Site("a") + "/page1.html";

  // ---- files and registry --------------------------------------------------------------
  Then("a custom bang aimed at the fixture server; reload the config", [] {
    core::WriteFileAtomic(
        core::JoinPath(platform::ProfileDir(), "bangs.json"),
        "[{\"t\":\"tt\",\"s\":\"Test Search\",\"u\":\"" + Site("a") + "/page1.html?q=%s\"}]");
    M()->RunCommand("config.reload");
  });
  Then("keybinding files in the profile", [] {
    std::string defaults, user;
    core::ReadFileUtf8Path(core::JoinPath(platform::ProfileDir(), "keybindings.default.json"), &defaults);
    core::ReadFileUtf8Path(core::JoinPath(platform::ProfileDir(), "keybindings.json"), &user);
    core::Json parsed;
    bool ok = core::ParseJson(defaults, &parsed) && parsed.is_object();
    Check("keybindings.default.json lists the defaults",
          ok && parsed.value("ctrl+tab", "") == "tab.cycleNext" && parsed.value("ctrl+t", "") == "tab.new");
    Expect("commandbar", "keybindings.json starts empty and is kept", "{\n}\n", user);
    std::set<std::string> strokes = M()->accelerator_strokes();
    Check("Ctrl+T, Ctrl+L, Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+1 and Alt+1 are registered",
          strokes.count("ctrl+t") && strokes.count("ctrl+l") && strokes.count("ctrl+tab") &&
              strokes.count("ctrl+shift+tab") && strokes.count("ctrl+1") && strokes.count("alt+1"));
    bool super_key = false;
    for (const std::string& s : strokes) super_key |= s.find("cmd") != std::string::npos;
    Check("no accelerator uses the Super key", !super_key);
  });

  // ---- four loaded tabs and a background one ---------------------------------------------
  LoadStep("tab 1", Main, a, [a](const std::string& url) { return url == a; });
  Then("remember tab 1", [ids] { ids->t1 = M()->selected_id().value_or(""); });
  Do("tab 2", [ids] { ids->t2 = M()->NewTab(Site("b") + "/page1.html", true); },
     [ids] { return SelectedAndSettled(ids->t2); });
  Do("tab 3", [ids] { ids->t3 = M()->NewTab(Site("c") + "/page1.html", true); },
     [ids] { return SelectedAndSettled(ids->t3); });
  Do("tab 4", [ids] { ids->t4 = M()->NewTab(Site("d") + "/page1.html", true); },
     [ids] { return SelectedAndSettled(ids->t4); });
  Then("a background tab that is never opened", [ids] {
    ids->bg = M()->NewTab(Site("e") + "/page1.html", false);
    ids->order_join = ids->t4 + "|" + ids->t3 + "|" + ids->t2 + "|" + ids->t1;
  });

  // ---- Control+Tab (spec/tab-recency.md) --------------------------------------------------
  Then("menu Next in Control+Tab order toggles the last two tabs", [ids] {
    M()->RunCommand("tab.cycleNext");
    Expect("commandbar", "first press goes to the previous tab", ids->t3, M()->selected_id().value_or("-"));
    Check("a menu press shows no switcher", M()->command_bar_mode() != "switcher");
    M()->RunCommand("tab.cycleNext");
    Expect("commandbar", "second press toggles back", ids->t4, M()->selected_id().value_or("-"));
  });
  Then("hold Control: three presses walk the order", [] {
    M()->RunCommand("tab.cycleNext", true);
    M()->RunCommand("tab.cycleNext", true);
    M()->RunCommand("tab.cycleNext", true);
  });
  BarEval("switcher tiles", "tiles", WaitFor("document.querySelectorAll('#tiles .tile').length>=4", kTileIds));
  Then("the switcher shows the order; the never-opened tab is left out", [ids] {
    Expect("commandbar", "switcher mode", "switcher", M()->command_bar_mode());
    Expect("commandbar", "tiles in recently used order, background tab left out", ids->order_join,
           Value("tiles"));
    Expect("commandbar", "the model's order is the same", ids->order_join,
           [] {
             std::string out;
             for (const std::string& id : M()->switcher_order()) out += (out.empty() ? "" : "|") + id;
             return out;
           }());
    Expect("commandbar", "three presses land on the oldest", ids->t1, M()->selected_id().value_or("-"));
    Check("the switcher overlay sits inside the window and is not wider than it",
          M()->BarBounds().width > 100 && M()->BarBounds().x >= 0 &&
              M()->BarBounds().x + M()->BarBounds().width <= M()->cef_window()->GetBounds().width);
  });
  Then("marker for the switcher screenshot", [] { platform::Log("commandbar: switcher screenshot"); });
  Sleep(3500);
  BarEval("release Control", "release",
          "(function(){document.dispatchEvent(new KeyboardEvent('keyup',{key:'Control',bubbles:true}));return 'sent'})()");
  Do("switcher goes away on release", [] {}, [] { return M()->command_bar_mode() == "hidden"; }, 5000);
  Then("release keeps the selection", [ids] {
    Expect("commandbar", "selection after release", ids->t1, M()->selected_id().value_or("-"));
  });
  Then("Control+Shift+Tab walks back", [ids] {
    M()->RunCommand("tab.cyclePrevious", true);
    Expect("commandbar", "shift press goes to the newest of the others", ids->t4,
           M()->selected_id().value_or("-"));
    M()->RunCommand("tab.cycleNext", true);
    Check("a held cycle shows the switcher", M()->command_bar_mode() == "switcher");
    M()->SelectTab(ids->t2);  // a click on a tab ends the held cycle
    Check("a click ends the held cycle and hides the switcher",
          M()->command_bar_mode() == "hidden" && M()->switcher_order().empty());
  });
  Then("press again then Escape", [] { M()->RunCommand("tab.cycleNext", true); });
  BarEval("Escape", "escape", WaitFor("!document.getElementById('switcher').hidden",
          "(function(){document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return 'sent'})()"));
  Do("switcher hides on Escape", [] {}, [] { return M()->command_bar_mode() == "hidden"; }, 5000);
  Then("Escape kept whatever the press selected", [ids] {
    Check("a tab of the cycle is selected", M()->selected_id().has_value() && *M()->selected_id() != ids->bg);
    M()->SelectTab(ids->t4);
  });

  // ---- the centred bar (Ctrl+T) ------------------------------------------------------------------
  Then("tab.new opens the command bar", [] { M()->RunCommand("tab.new"); });
  BarEval("empty bar lists recent tabs", "recent",
          WaitFor("document.querySelectorAll('#results .row').length>=4", "document.querySelectorAll('#results .row').length"));
  Then("check the bar", [ids] {
    Expect("commandbar", "mode", "new", M()->command_bar_mode());
    Expect("commandbar", "empty bar offers the other four tabs", "4", Value("recent"));
    CefRect b = M()->BarBounds();
    CefRect w = M()->cef_window()->GetBounds();
    int reserved = std::clamp(static_cast<int>(M()->store().state().sidebar_width), 180, 480);
    int left = b.x - reserved, right = (w.width - reserved) - (left + b.width);
    Check("bar is centred over the page area", std::abs(left - right) <= 2 && b.y > 0 &&
          b.y + b.height < w.height);
    (void)ids;
  });
  BarEval("type a custom bang", "bangtyped", Type("!tt hello world"));
  BarEval("bang row", "bangrow", WaitFor("document.querySelector('#results .row .title')&&"
          "document.querySelector('#results .row .title').textContent.indexOf('hello world')>=0",
          "document.querySelector('#results .row .title').textContent"));
  Then("the bang row", [] {
    Expect("commandbar", "first row is the bang", "Search Test Search for \xE2\x80\x9C" "hello world\xE2\x80\x9D",
           Value("bangrow"));
  });
  Then("marker for the bar screenshot", [] { platform::Log("commandbar: bar screenshot"); });
  Sleep(3500);
  auto tabs_before = std::make_shared<size_t>();
  Then("count tabs", [tabs_before] { *tabs_before = M()->sidebar_titles().size(); });
  BarEval("Return with no row chosen", "enter", Key("Enter"));
  const std::string bang_url = Site("a") + "/page1.html?q=hello+world";
  Do("the bang opens a new tab with the query", [] {}, [bang_url] {
       return Settled(SelectedPage(M())) && SelectedPage(M())->committed_url() == bang_url;
     }, 20000);
  Then("bang opened", [tabs_before, bang_url, ids] {
    Expect("commandbar", "Return opens the bang's address", bang_url, SelectedPage(M())->committed_url());
    Expect("commandbar", "in a new tab", std::to_string(*tabs_before + 1), std::to_string(M()->sidebar_titles().size()));
    Expect("commandbar", "the bar closed", "hidden", M()->command_bar_mode());
    ids->extra = M()->selected_id().value_or("");
  });

  // Arrow to a tab row and pick it.
  Then("open the bar again", [] { M()->RunCommand("tab.new"); });
  BarEval("type a host that an open tab has", "hosttyped", Type("b.birch.test"));
  BarEval("rows for a host", "hostrows",
          WaitFor("[].some.call(document.querySelectorAll('#results .row .hint'),function(e){return e.textContent==='Switch to Tab'})",
                  "[].findIndex.call(document.querySelectorAll('#results .row'),function(r){return r.querySelector('.hint').textContent==='Switch to Tab'})"));
  BarEval("arrow and Return", "pickkeys", "(function(){var rows=[].map.call(document.querySelectorAll('#results .row'),"
          "function(r){return r.querySelector('.hint').textContent});var at=rows.indexOf('Switch to Tab');"
          "var i=document.getElementById('text');for(var k=0;k<=at;k++)i.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));"
          "i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));return at})()");
  Do("the picked tab is selected", [] {}, [ids] { return M()->selected_id() == ids->t2; }, 8000);
  Then("picked", [ids] {
    Expect("commandbar", "arrow + Return on a tab row switches to it", ids->t2, M()->selected_id().value_or("-"));
    Expect("commandbar", "bar closed after the pick", "hidden", M()->command_bar_mode());
  });

  // A command row with its shortcut.
  Then("open the bar for a command", [] { M()->RunCommand("tab.new"); });
  BarEval("type a command", "cmdtyped", Type("reload page"));
  BarEval("command row", "cmdrow", WaitFor("[].some.call(document.querySelectorAll('#results .row .subtitle'),function(e){return e.textContent==='Command'})",
          "[].filter.call(document.querySelectorAll('#results .row'),function(r){return r.querySelector('.subtitle').textContent==='Command'})"
          ".map(function(r){return r.querySelector('.title').textContent+'|'+r.querySelector('.hint').textContent})[0]"));
  Then("the command row", [] {
    Expect("commandbar", "a command is listed with its Ctrl shortcut", "Reload Page|Ctrl+R", Value("cmdrow"));
  });
  BarEval("pick the command", "cmdpick", "(function(){var rows=[].map.call(document.querySelectorAll('#results .row'),"
          "function(r){return r.querySelector('.subtitle').textContent});var at=rows.indexOf('Command');"
          "var i=document.getElementById('text');for(var k=0;k<=at;k++)i.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));"
          "i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));return at})()");
  Do("the command ran", [] {}, [] { return M()->last_command() == "tab.reload"; }, 6000);
  Then("command ran", [] {
    Expect("commandbar", "choosing a command row runs it", "tab.reload", M()->last_command());
    Expect("commandbar", "and puts the bar away", "hidden", M()->command_bar_mode());
  });

  // Escape and forged picks.
  Then("open and forge", [] { M()->RunCommand("tab.new"); });
  BarEval("a pick for a row the app never sent", "forged",
          WaitFor("!document.getElementById('bar').hidden", "(Birch.send('commandbar.pick',{key:'tab:deadbeef'}),'sent')"));
  Sleep(300);
  Then("forged pick ignored", [] {
    Expect("commandbar", "a pick for an unknown key does nothing", "new", M()->command_bar_mode());
  });
  BarEval("Escape closes the bar", "esc", Key("Escape"));
  Do("bar closes", [] {}, [] { return M()->command_bar_mode() == "hidden"; }, 5000);

  // ---- in-place editing (Ctrl+L) -----------------------------------------------------------------
  Then("tab.editURL", [] { M()->RunCommand("tab.editURL"); });
  BarEval("edit field", "edit", WaitFor("document.getElementById('text').value.length>0",
          "document.getElementById('text').value+'|'+document.getElementById('text').selectionStart+'|'+document.getElementById('text').selectionEnd"));
  const std::string c2 = Site("c") + "/page2.html";
  auto tab_count = std::make_shared<size_t>();
  Then("check edit mode", [tab_count] {
    Expect("commandbar", "mode", "edit", M()->command_bar_mode());
    std::string current = SelectedPage(M())->committed_url();
    Expect("commandbar", "the field holds the full address, all selected",
           current + "|0|" + std::to_string(current.size()), Value("edit"));
    Expect("commandbar", "anchored at the left, under the address pill", "8", std::to_string(M()->BarBounds().x));
    *tab_count = M()->sidebar_titles().size();
  });
  BarEval("type a new address and Return", "editgo",
          Type(c2) + ";" + Key("Enter"));
  Do("the same tab loads it", [] {}, [c2] { return Settled(SelectedPage(M())) && SelectedPage(M())->committed_url() == c2; }, 20000);
  Then("edited", [tab_count] {
    Expect("commandbar", "no extra tab", std::to_string(*tab_count), std::to_string(M()->sidebar_titles().size()));
    Expect("commandbar", "bar closed", "hidden", M()->command_bar_mode());
  });

  // ---- keybindings.json -----------------------------------------------------------------------------
  Then("a user keybindings file", [] {
    core::WriteFileAtomic(core::JoinPath(platform::ProfileDir(), "keybindings.json"),
                          "{\"ctrl+t\": null, \"ctrl+alt+j\": \"tab.new\"}");
    M()->RunCommand("config.reload");
    Check("ctrl+alt+j is registered as an accelerator", M()->accelerator_strokes().count("ctrl+alt+j") == 1);
    Check("the default Ctrl+T is switched off", !M()->HandleStroke("ctrl+t"));
    Check("the person's stroke runs the command", M()->HandleStroke("ctrl+alt+j") &&
                                                  M()->command_bar_mode() == "new");
    M()->CloseCommandBar(false);
    core::WriteFileAtomic(core::JoinPath(platform::ProfileDir(), "keybindings.json"), "{\n}\n");
    M()->RunCommand("config.reload");
    Check("Ctrl+T works again after the file is emptied", M()->HandleStroke("ctrl+t") &&
                                                           M()->command_bar_mode() == "new");
    M()->CloseCommandBar(false);
    Check("a stroke nobody uses is left to the page", !M()->HandleStroke("ctrl+alt+q"));
  });
  Then("hold for the owner", [] { platform::Log("commandbar: hold"); });
}

}  // namespace birch::tests
