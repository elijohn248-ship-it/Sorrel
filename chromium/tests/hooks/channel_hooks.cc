// BIRCH_TEST=channel: the UI host and its UI-only channel (CLAUDE.md ▸
// Chromium edition ▸ UI host). Web pages, cross-origin frames, pop-ups and a
// forged (compromised-renderer) sender must all fail to reach the app; UI
// pages can't be navigated away; unknown or malformed messages are refused;
// app data reaches the sidebar as text; UI and web content never share a
// renderer process.
#include <memory>
#include <set>

#include "app/shell.h"
#include "engine/engine.h"
#include "engine/ui_page.h"
#include "platform/platform.h"
#include "tests/hooks/hooks.h"
#include "ui/main_window.h"

namespace birch::tests {

namespace {

ui::MainWindow* M() {
  return Main();
}

std::string Committed(ui::MainWindow* w) {
  engine::Page* p = SelectedPage(w);
  return p ? p->committed_url() : std::string();
}

std::string SidebarUrl() {
  engine::UiPage* ui = M()->sidebar_page();
  return ui ? ui->CommittedUrlForTest() : std::string();
}

using WindowRef = std::shared_ptr<CefRefPtr<ui::MainWindow>>;

const engine::UiPageStats& S() {
  return engine::UiStats();
}

// Waits until window.probe.frame has an answer from the cross-origin frame.
const char kFrameProbe[] =
    "new Promise(function(done){var n=0;(function go(){"
    "if(window.probe&&window.probe.frame!=='waiting'||n++>50){"
    "done(window.probe?window.probe.frame:'no-probe');return}"
    "setTimeout(go,100)})()})";

}  // namespace

BIRCH_TEST_SCENARIO(channel) {
  std::string pa = Site("a");
  auto base = std::make_shared<engine::UiPageStats>();
  auto rows = std::make_shared<size_t>(0);
  auto ui_key = std::make_shared<std::string>();
  auto web_keys = std::make_shared<std::set<std::string>>();

  // ---- the UI page has the channel (positive control) ---------------------------------
  SidebarEvalStep("sidebar has birchUI", M, "uihas",
                  "typeof window.birchUI+'/'+typeof window.birchUI.send");
  SidebarEvalStep("birchUI can't be replaced", M, "uifixed",
                  "(function(){var o=window.birchUI;try{window.birchUI=1}"
                  "catch(e){}return window.birchUI===o?'kept':'replaced'})()");
  Then("ui control", [] {
    Expect("channel", "UI page main frame has birchUI", "object/function",
           Value("uihas"));
    Expect("channel", "birchUI can't be replaced by page script", "kept",
           Value("uifixed"));
    Expect("channel", "sidebar page is birch-ui://sidebar/", "yes",
           YesNo(StartsWith(SidebarUrl(), "birch-ui://sidebar/")));
  });

  // ---- a web page and a cross-origin iframe ---------------------------------------------
  LoadStep("web page", M, pa + "/channel.html",
           [](const std::string& u) { return EndsWith(u, "/channel.html"); });
  EvalStep("web page looks for the channel", M, "webhas", "window.probe.own");
  EvalStep("cross-origin frame looks for the channel", M, "framehas",
           kFrameProbe);
  Then("web results", [] {
    Expect("channel", "web page: birchUI/cefQuery", "undefined/undefined",
           Value("webhas"));
    Expect("channel", "cross-origin iframe: birchUI/cefQuery",
           "undefined/undefined", Value("framehas"));
  });

  // ---- a pop-up (user gesture: becomes a tab) --------------------------------------------
  Then("count rows", [rows] { *rows = M()->sidebar_titles().size(); });
  EvalStep("open a pop-up with a click", M, "popup",
           "(function(){window.open(location.protocol+'//q.birch.test:'+"
           "location.port+'/channel.html');return 'asked'})()",
           /*gesture=*/true);
  Do("pop-up tab", [] {},
     [] {
       return Settled(SelectedPage(M())) && Committed(M()).find("q.birch.test") !=
                                                std::string::npos;
     },
     20000);
  EvalStep("pop-up looks for the channel", M, "pophas", "window.probe.own");
  Then("pop-up results", [rows] {
    Expect("channel", "pop-up opened as a tab", std::to_string(*rows + 1),
           std::to_string(M()->sidebar_titles().size()));
    Expect("channel", "pop-up: birchUI/cefQuery", "undefined/undefined",
           Value("pophas"));
  });

  // ---- extension pages ----------------------------------------------------------------------
  Then("extension pages", [] {
    // No extension support exists in the Chromium edition yet (wave-3 agent
    // 7). Their pages will be web-content browsers, which never get the
    // object (only UI browsers do) and whose messages the browser process
    // refuses (the forged-sender check below). Agent 7 adds a real probe.
    platform::Log("channel: extension page probe: not applicable yet "
                  "(no extension support until agent 7)");
  });

  // ---- a compromised web renderer sends channel messages ---------------------------------
  Then("before forging", [base, rows] {
    *base = S();
    *rows = M()->sidebar_titles().size();
  });
  LoadStep("forging page", M, pa + "/forge.html",
           [](const std::string& u) { return EndsWith(u, "/forge.html"); });
  Sleep(2000);
  Then("forged messages refused", [base, rows] {
    Expect("channel", "forged messages from a web renderer refused (>=3)",
           "yes", YesNo(S().refused_sender - base->refused_sender >= 3));
    Expect("channel", "forged messages accepted", "0",
           std::to_string(S().accepted - base->accepted));
    Expect("channel", "no tab opened by forged tab.new",
           std::to_string(*rows), std::to_string(M()->sidebar_titles().size()));
    Expect("channel", "forged address.submit not loaded", "yes",
           YesNo(EndsWith(Committed(M()), "/forge.html")));
  });

  // ---- web pages can't open or fetch birch-ui:// --------------------------------------------
  EvalStep("web page navigates to birch-ui://", M, "webnav",
           "(function(){try{location.href='birch-ui://sidebar/index.html';"
           "return 'tried'}catch(e){return 'threw'}})()");
  Sleep(1500);
  EvalStep("web page fetches birch-ui://", M, "webfetch",
           "fetch('birch-ui://sidebar/index.html').then(function(){return "
           "'fetched'},function(){return 'refused'})");
  Then("web vs birch-ui", [] {
    Expect("channel", "web page cannot open birch-ui://", "blocked",
           StartsWith(Committed(M()), "birch-ui:") ? "opened" : "blocked");
    Expect("channel", "web page cannot fetch birch-ui://", "refused",
           Value("webfetch"));
  });

  // ---- the UI page can't be navigated, open pop-ups or reach the network --------------
  Then("before ui nav", [base, rows] {
    *base = S();
    *rows = M()->sidebar_titles().size();
  });
  SidebarEvalStep("sidebar navigates to a web address", M, "uinav1",
                  "(function(){location.href='" + pa +
                      "/page1.html';return 'tried'})()");
  Sleep(1000);
  SidebarEvalStep("sidebar navigates to birch://welcome", M, "uinav2",
                  "(function(){location.href='birch://welcome/';return 'tried'})()");
  Sleep(1000);
  SidebarEvalStep("sidebar navigates to another UI page", M, "uinav3",
                  "(function(){location.href='birch-ui://commandbar/index.html';"
                  "return 'tried'})()");
  Sleep(1000);
  SidebarEvalStep("sidebar opens a pop-up", M, "uipop",
                  "(function(){var w=window.open('" + pa +
                      "/page2.html');return w?'opened':'blocked'})()");
  SidebarEvalStep("sidebar fetches a web address", M, "uifetch",
                  "fetch('" + pa + "/page1.html').then(function(){return "
                  "'fetched'},function(){return 'refused'})");
  Sleep(1000);
  Then("ui locked", [base, rows] {
    Expect("channel", "sidebar still on its own page", "yes",
           YesNo(StartsWith(SidebarUrl(), "birch-ui://sidebar/")));
    Expect("channel", "UI navigations refused (3)", "yes",
           YesNo(S().navigations_refused - base->navigations_refused >= 3));
    Expect("channel", "UI pop-up refused", "yes",
           YesNo(S().popups_refused > base->popups_refused ||
                 Value("uipop") == "blocked"));
    Expect("channel", "no tab added by the UI pop-up", std::to_string(*rows),
           std::to_string(M()->sidebar_titles().size()));
    Expect("channel", "UI page cannot fetch the web", "refused",
           Value("uifetch"));
    Expect("channel", "sidebar still ready", "yes",
           YesNo(M()->sidebar_page()->ready()));
  });

  // ---- unknown and malformed messages -------------------------------------------------------
  Then("before bad messages", [base, rows] {
    *base = S();
    *rows = M()->sidebar_titles().size();
  });
  SidebarEvalStep(
      "sidebar sends bad messages", M, "bad",
      "(function(){var s=window.birchUI.send;"
      "s('file.read',{path:'/etc/passwd'});"
      "s('eval',{code:'1'});"
      "s('tab.select',{id:42});"
      "s('tab.select',{id:'x',extra:1});"
      "s('address.submit',{text:'a'.repeat(10000)});"
      "s('tab.close');"
      "s('tab.select',{id:'0F8FAD5B-D9CB-469F-A165-70867728950E'});"
      "return 'sent'})()");
  Sleep(1500);
  Then("bad messages refused", [base, rows] {
    Expect("channel", "unknown/malformed messages refused", "6",
           std::to_string(S().refused_message - base->refused_message));
    Expect("channel", "well-formed select of an unknown tab: accepted, ignored",
           "1", std::to_string(S().accepted - base->accepted));
    Expect("channel", "tabs unchanged", std::to_string(*rows),
           std::to_string(M()->sidebar_titles().size()));
    Expect("channel", "page unchanged", "yes",
           YesNo(EndsWith(Committed(M()), "/forge.html")));
  });

  // ---- app -> UI data stays text ---------------------------------------------------------------
  LoadStep("hostile title", M, pa + "/hostile.html",
           [](const std::string& u) { return EndsWith(u, "/hostile.html"); });
  Do("title arrives", [] {},
     [] {
       for (const std::string& t : M()->sidebar_titles()) {
         if (t.find("onerror") != std::string::npos) {
           return true;
         }
       }
       return false;
     },
     10000);
  SidebarMatchesStep("channel", "hostile title shown as text", M);
  SidebarEvalStep("no markup injected", M, "inject",
                  "document.querySelectorAll('#tabs img,#tabs script').length+"
                  "'/'+document.title");
  Then("no injection", [] {
    Expect("channel", "hostile title injected nothing", "0/Birch sidebar",
           Value("inject"));
  });

  // ---- UI and web content never share a renderer process ---------------------------------
  Then("renderer ids", [ui_key, web_keys] {
    *ui_key = M()->sidebar_page()->RendererKeyForTest();
    web_keys->clear();
    const core::Space& space = M()->store().CurrentSpace(M()->session());
    for (const core::SidebarRow& r : M()->store().SidebarRows(space.id)) {
      if (engine::Page* p = r.target_id.empty() ? nullptr : M()->PageFor(r.target_id)) {
        std::string k = p->RendererKeyForTest();
        if (!k.empty()) {
          web_keys->insert(k);
        }
      }
    }
    platform::Log("channel: renderer ids ui=" + *ui_key + " web=" +
                  std::to_string(web_keys->size()) + " distinct");
    Expect("channel", "renderer ids readable (UI and web)", "yes",
           YesNo(!ui_key->empty() && !web_keys->empty()));
    Expect("channel", "UI page shares a renderer with a web page", "no",
           YesNo(web_keys->count(*ui_key) > 0));
  });
  // Crash the sidebar's renderer: the web page must live on (it would be
  // gone too if they shared a process), and the sidebar must come back.
  auto crashes = std::make_shared<int>(0);
  auto page_url = std::make_shared<std::string>();
  Do("crash the sidebar's renderer",
     [crashes, page_url] {
       *crashes = S().crashes;
       *page_url = Committed(M());
       M()->sidebar_page()->DevToolsForTest(
           "Page.crash", nullptr, [](bool, const std::string&) {});
     },
     [crashes] { return S().crashes > *crashes; }, 15000);
  Do("sidebar back", [] {},
     [] { return M()->sidebar_page()->ready(); }, 20000);
  EvalStep("web page alive after the sidebar crash", M, "alive", "6*7");
  Then("separate processes", [page_url] {
    Expect("channel", "web page alive after the UI renderer crashed", "42",
           Value("alive"));
    Expect("channel", "web page not replaced by the error page", "yes",
           YesNo(Committed(M()) == *page_url));
    Expect("channel", "sidebar reloaded and ready", "yes",
           YesNo(M()->sidebar_page()->ready()));
  });
  SidebarMatchesStep("channel", "after the sidebar's own crash", M);
  Then("ui renderer id after reload", [web_keys] {
    std::string k = M()->sidebar_page()->RendererKeyForTest();
    Expect("channel", "reloaded UI page shares a renderer with a web page",
           "no", YesNo(!k.empty() && web_keys->count(k) > 0));
  });

  // Screenshots for the owner (CI shows the window).
  std::string hold = platform::Env("BIRCH_HOLD");
  if (!hold.empty()) {
    Then("channel hold", [] { platform::Log("channel: hold"); });
    Sleep(std::stoi(hold) * 1000);
    WindowRef p = std::make_shared<CefRefPtr<ui::MainWindow>>();
    Do("private window", [p] {
         *p = CefRefPtr<ui::MainWindow>(app::Shell::Get().OpenPrivate());
       },
       [p] {
         return p->get() && p->get()->cef_window() && p->get()->sidebar_page() &&
                p->get()->sidebar_page()->ready();
       },
       20000);
    Do("private page",
       [p, pa] { (*p)->NewTab(pa + "/page2.html", true); },
       [p] { return Settled(SelectedPage(p->get())); }, 20000);
    SidebarMatchesStep("channel", "private window",
                       [p]() -> ui::MainWindow* { return p->get(); });
    Then("private hold", [] { platform::Log("channel: private hold"); });
    Sleep(std::stoi(hold) * 1000);
  }
}

}  // namespace birch::tests
