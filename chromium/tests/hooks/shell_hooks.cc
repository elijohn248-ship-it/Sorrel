// Wave-2 scenarios: the shell itself (tabs, sidebar, address box, shortcuts,
// state.json), restore, a corrupt state file, private storage, downloads,
// permissions, certificates, sandbox and the NetLog runs. Driven by
// tests/harness/run_tests.py against the local fixture server.
#include <algorithm>

#include "include/cef_task.h"
#include "include/views/cef_window.h"

#include "app/shell.h"
#include "core/codec.h"
#include "core/state_file.h"
#include "engine/engine.h"
#include "platform/platform.h"
#include "tests/hooks/hooks.h"
#include "ui/main_window.h"

namespace birch::tests {

namespace {

std::string Join(const std::vector<std::string>& v) {
  std::string out;
  for (const std::string& s : v) {
    out += (out.empty() ? "" : "|") + s;
  }
  return out;
}

ui::MainWindow* M() {
  return Main();
}

std::string ProfileFile(const std::string& name) {
  return core::JoinPath(app::Shell::Get().profile_dir(), name);
}

std::string Committed(ui::MainWindow* w) {
  engine::Page* p = SelectedPage(w);
  return p ? p->committed_url() : std::string();
}

bool Has(const std::string& s, const std::string& part) {
  return s.find(part) != std::string::npos;
}

// Holds a window alive for the test even after the app drops it.
using WindowRef = std::shared_ptr<CefRefPtr<ui::MainWindow>>;

void HoldForScreenshot(const std::string& area) {
  std::string hold = platform::Env("BIRCH_HOLD");
  if (hold.empty()) {
    return;
  }
  Then(area + " hold", [area] { platform::Log(area + ": hold"); });
  Sleep(std::stoi(hold) * 1000);
}

}  // namespace

// ---- the shell: tabs, sidebar, address box, shortcuts, state.json ---------------------

BIRCH_TEST_SCENARIO(shell) {
  auto a = std::make_shared<std::string>();
  auto b = std::make_shared<std::string>();
  auto c = std::make_shared<std::string>();
  std::string pa = Site("a"), pb = Site("b");

  Then("fresh profile", [a] {
    ui::MainWindow* w = M();
    *a = w->selected_id().value_or("");
    Expect("shell", "fresh profile sidebar", "Welcome to Birch",
           Join(w->sidebar_titles()));
    Expect("shell", "welcome page address box", "Birch", w->address_text());
    Expect("shell", "welcome page committed", "birch://welcome/", Committed(w));
    Expect("shell", "profile folder is BIRCH_HOME", platform::Env("BIRCH_HOME"),
           app::Shell::Get().profile_dir());
    Expect("shell", "settings.json written", "yes",
           YesNo(core::FileExists(ProfileFile("settings.json"))));
    Expect("shell", "state.json written", "yes",
           YesNo(core::FileExists(ProfileFile("state.json"))));
  });
  Do(
      "address field: type an address", [pa] {
        M()->SubmitAddress(pa + "/page1.html", false);
      },
      [] {
        return Settled(SelectedPage(M())) &&
               EndsWith(Committed(M()), "/page1.html");
      },
      20000);
  Then("origin shown", [] {
    Expect("shell", "address box shows the host", "a.birch.test",
           M()->address_text());
    Expect("shell", "http page marked not secure", "yes",
           YesNo(M()->not_secure_shown()));
  });
  LoadStep("page 2", M, pa + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  Then("layout", [] {
    std::string layout = M()->LayoutForTest();
    platform::Log("layout: " + layout);
    auto number_after = [&layout](const std::string& key) {
      size_t pos = layout.find(key);
      int n = 0;
      for (pos = pos == std::string::npos ? layout.size() : pos + key.size();
           pos < layout.size() && layout[pos] >= '0' && layout[pos] <= '9'; ++pos) {
        n = n * 10 + (layout[pos] - '0');
      }
      return n;
    };
    int sidebar = number_after("sidebar=");
    // The page view's own width (the content panel's can lag on Linux).
    int content = std::max(number_after("content="), number_after("page="));
    Expect("layout", "sidebar keeps its width", std::to_string(
               std::clamp(static_cast<int>(M()->store().state().sidebar_width), 180, 480)),
           std::to_string(sidebar));
    Expect("layout", "page area gets the rest (wider than 300)", "yes",
           YesNo(content > 300));
  });
  Do("back", [] { M()->GoBack(); },
     [] {
       return Settled(SelectedPage(M())) &&
              EndsWith(Committed(M()), "/page1.html");
     });
  Then("after back", [] {
    Expect("shell", "back reached page 1", "yes",
           YesNo(EndsWith(Committed(M()), "/page1.html")));
    Expect("shell", "can go forward", "yes",
           YesNo(SelectedPage(M())->CanGoForward()));
  });
  Do("forward", [] { M()->GoForward(); },
     [] {
       return Settled(SelectedPage(M())) &&
              EndsWith(Committed(M()), "/page2.html");
     });
  Do("reload", [] { M()->Reload(); },
     [] { return Settled(SelectedPage(M())); });
  EvalStep("navigation type", M, "navtype",
           "performance.getEntriesByType('navigation')[0].type");
  Then("reloaded", [] {
    Expect("shell", "reload navigation type", "reload", Value("navtype"));
  });

  Do("new tab", [b, pb] { *b = M()->NewTab(pb + "/page1.html", true); },
     [b] {
       return !b->empty() && M()->selected_id() == *b &&
              Settled(SelectedPage(M())) && !M()->sidebar_titles().empty() &&
              M()->sidebar_titles()[0] == "Birch fixture page 1";
     });
  Then("two tabs", [a, b] {
    ui::MainWindow* w = M();
    Expect("shell", "sidebar lists both tabs, newest first",
           "Birch fixture page 1|Birch fixture page 2",
           Join(w->sidebar_titles()));
    Expect("shell", "address follows the selected tab (b)", "b.birch.test",
           w->address_text());
    w->SelectTab(*a);
    Expect("shell", "address follows the selected tab (a)", "a.birch.test",
           w->address_text());
    Expect("shell", "two live pages", "2", std::to_string(w->LivePageCount()));
    w->SelectTab(*b);
  });
  // U+0430 CYRILLIC SMALL LETTER A + "pple": a lookalike of "apple".
  LoadStep("lookalike host", M,
           "http://\xD0\xB0pple.birch.test:" + HttpPort() + "/page1.html",
           [](const std::string& u) { return Has(u, "birch.test"); });
  Then("punycode shown", [] {
    Expect("shell", "lookalike shown as punycode", "xn--pple-43d.birch.test",
           M()->address_text());
  });

  // A crashed renderer shows Birch's error page and the tab recovers.
  auto crash_start = std::make_shared<int64_t>(0);
  auto killed = std::make_shared<bool>(false);
  DevToolsStep("crash the renderer", M, "crash", "Page.crash");
  Do(
      "crash page", [crash_start] { *crash_start = core::NowSeconds(); },
      [crash_start, killed] {
        if (!*killed && core::NowSeconds() - *crash_start > 8) {
          *killed = true;
          platform::Log("crash: Page.crash did not end the renderer; chrome://kill");
          SelectedPage(M())->Load("chrome://kill");
        }
        return Settled(SelectedPage(M())) &&
               StartsWith(Committed(M()), "birch://error");
      },
      30000);
  EvalStep("error page reason", M, "crashreason",
           "document.body.dataset.birchError");
  Then("crash handled", [] {
    Expect("shell", "crash shows Birch's error page", "Birch",
           M()->address_text());
    Expect("shell", "error page reason", "crash", Value("crashreason"));
  });
  LoadStep("recover", M, pb + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  Then("recovered", [b] {
    Expect("shell", "tab usable after crash", "yes",
           YesNo(EndsWith(Committed(M()), "/page2.html")));
    const core::Item* item = M()->store().FindItem(*b);
    Expect("shell", "error page not saved as the tab's address", "yes",
           YesNo(item && item->url && EndsWith(*item->url, "/page2.html")));
  });

  // Web pages cannot reach birch:// (display-isolated scheme).
  EvalStep("page links to birch://", M, "spoof",
           "(function(){try{location.href='birch://error/?reason=spoof';"
           "return 'tried'}catch(e){return 'threw'}})()");
  Sleep(1500);
  Then("spoof blocked", [] {
    Expect("shell", "web page cannot open birch://", "blocked",
           StartsWith(Committed(M()), "birch://") ? "opened" : "blocked");
  });
  EvalStep("page fetches birch://", M, "spooffetch",
           "fetch('birch://welcome/').then(function(){return 'fetched'},"
           "function(){return 'refused'})");
  Then("fetch refused", [] {
    Expect("shell", "web page cannot fetch birch://", "refused",
           Value("spooffetch"));
  });
  EvalStep("pop-up without a click", M, "popup",
           "(function(){var w=window.open('" + Site("p") +
               "/page1.html');return w?'opened':'blocked'})()");
  Sleep(1000);
  Then("pop-up blocked", [] {
    // Blocked either by Birch's OnBeforePopup or by Chromium before it.
    platform::Log("popup: window.open returned " + Value("popup") +
                  ", blocked by Birch " +
                  std::to_string(engine::Stats().popups_blocked));
    Expect("shell", "pop-up without a user gesture blocked", "yes",
           YesNo(engine::Stats().popups_blocked > 0 ||
                 Value("popup") == "blocked"));
    Expect("shell", "no tab added by the pop-up", "2",
           std::to_string(M()->sidebar_titles().size()));
  });

  // A synthetic Ctrl+T through the window (CEF's test key press). Whether a
  // CI desktop delivers it is logged, not required: real keyboard routing is
  // an owner check. The commands themselves are checked next.
  auto key_reached = std::make_shared<bool>(false);
  Do("synthetic Ctrl+T", [] {
       if (CefRefPtr<CefWindow> w = M()->cef_window()) {
         w->Activate();
         w->SendKeyPress('T', EVENTFLAG_CONTROL_DOWN);
       }
     },
     [key_reached] { return *key_reached = M()->new_tab_mode(); }, 4000);
  Then("synthetic key result", [key_reached] {
    platform::Log(std::string("keyboard: synthetic Ctrl+T reached the "
                              "accelerator: ") + YesNo(*key_reached));
  });
  Do("command tab.new (Ctrl+T)", [] {
       if (!M()->new_tab_mode()) {
         M()->RunCommand("tab.new");
       }
     },
     [] { return M()->new_tab_mode(); }, 5000);
  Then("new-tab mode", [] {
    Expect("shell", "tab.new puts the address field in new-tab mode", "yes",
           YesNo(M()->new_tab_mode()));
  });
  Do("Enter in the new-tab field", [c] {
       M()->TypeAddressForTest(Site("c") + "/page1.html");
       *c = M()->selected_id().value_or("");
     },
     [] {
       return Settled(SelectedPage(M())) && M()->sidebar_titles().size() == 3;
     });
  Then("third tab", [] {
    Expect("shell", "Enter in new-tab mode opens a tab", "c.birch.test|3",
           M()->address_text() + "|" +
               std::to_string(M()->sidebar_titles().size()));
  });
  Do("command tab.close (Ctrl+W)", [] { M()->RunCommand("tab.close"); },
     [c] { return M()->sidebar_titles().size() == 2 && !M()->PageFor(*c); },
     10000);
  Then("tab.close closed it", [b] {
    Expect("shell", "tab.close closes the selected tab", "2",
           std::to_string(M()->sidebar_titles().size()));
    Expect("shell", "selection moves to the next tab", *b,
           M()->selected_id().value_or("none"));
  });

  Do("close tab b", [b] { M()->CloseTab(*b); },
     [b] { return !M()->PageFor(*b) && M()->sidebar_titles().size() == 1; },
     10000);
  Then("after close", [a] {
    Expect("shell", "one tab left", "1",
           std::to_string(M()->sidebar_titles().size()));
    Expect("shell", "remaining tab selected", *a,
           M()->selected_id().value_or("none"));
    Expect("shell", "address after close", "a.birch.test", M()->address_text());
  });

  Sleep(1500);  // the 0.8 s debounced save
  Then("state.json", [a] {
    std::string text;
    core::AppState s;
    std::string error;
    bool read = core::ReadFileUtf8Path(ProfileFile("state.json"), &text);
    bool ok = read && core::DecodeAppState(text, &s, &error);
    Expect("state", "state.json decodes (spec format)", "yes", YesNo(ok));
    if (!ok) {
      return;
    }
    Expect("state", "spaces", "1", std::to_string(s.spaces.size()));
    Expect("state", "today tabs", "1",
           std::to_string(s.spaces[0].today.size()));
    Expect("state", "tab address saved", "yes",
           YesNo(!s.spaces[0].today.empty() && s.spaces[0].today[0].url &&
                 EndsWith(*s.spaces[0].today[0].url, "/page2.html")));
    Expect("state", "selection saved", *a,
           s.spaces[0].selected_id.value_or("none"));
    Expect("state", "one window saved", "1",
           std::to_string(s.windows ? s.windows->size() : 0));
    Expect("state", "ids written uppercase", "yes",
           YesNo(a->find_first_of("abcdef") == std::string::npos));
  });
  HoldForScreenshot("shell");
}

// ---- smoke: the unpacked Windows zip loads pages (network service sandbox) -----------

BIRCH_TEST_SCENARIO(smoke) {
  WindowRef p = std::make_shared<CefRefPtr<ui::MainWindow>>();
  auto P = [p]() -> ui::MainWindow* { return p->get(); };
  LoadStep("a page", M, Site("a") + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  Then("page loaded", [] {
    Expect("smoke", "page loads (network works)", "a.birch.test",
           M()->address_text());
  });
  Do("private window",
     [p] { *p = CefRefPtr<ui::MainWindow>(app::Shell::Get().OpenPrivate()); },
     [p] { return p->get() && p->get()->cef_window(); }, 10000);
  Do("private page", [p] { (*p)->NewTab(Site("b") + "/page2.html", true); },
     [P] { return Settled(SelectedPage(P())); });
  Then("private page loaded", [P] {
    Expect("smoke", "private window loads pages", "b.birch.test",
           P()->address_text());
  });
  HoldForScreenshot("smoke");
}

// ---- restore: a state.json from the shell scenario, in a fresh profile --------------------

BIRCH_TEST_SCENARIO(restore) {
  Then("restored", [] {
    ui::MainWindow* w = M();
    Expect("restore", "tabs in the sidebar", platform::Env("BIRCH_EXPECT_ROWS"),
           std::to_string(w->sidebar_titles().size()));
    Expect("restore", "selected tab's page", "yes",
           YesNo(EndsWith(Committed(w), platform::Env("BIRCH_EXPECT_SUFFIX"))));
    Expect("restore", "address box", "a.birch.test", w->address_text());
    bool backup = false;
    for (const std::string& n :
         core::ListDirectory(app::Shell::Get().profile_dir())) {
      backup = backup || StartsWith(n, "state.unreadable-");
    }
    Expect("restore", "no unreadable-state backup", "no", YesNo(backup));
  });
}

// ---- a state.json that can't be read: fresh profile plus a backup --------------------------

BIRCH_TEST_SCENARIO(corrupt) {
  Then("seeded", [] {
    ui::MainWindow* w = M();
    Expect("corrupt", "fresh profile shown", "Welcome to Birch",
           Join(w->sidebar_titles()));
    bool backup = false;
    // The harness wrote "not json" as state.json.
    for (const std::string& n :
         core::ListDirectory(app::Shell::Get().profile_dir())) {
      std::string text;
      if (StartsWith(n, "state.unreadable-") &&
          core::ReadFileUtf8Path(ProfileFile(n), &text)) {
        backup = backup || text == "not json";
      }
    }
    Expect("corrupt", "unreadable state.json kept as a backup", "yes",
           YesNo(backup));
  });
}

// ---- private windows: separate storage, nothing on disk, never saved ------------------------

BIRCH_TEST_SCENARIO(private) {
  std::string nonce = platform::Env("BIRCH_NONCE");
  WindowRef p = std::make_shared<CefRefPtr<ui::MainWindow>>();
  auto P = [p]() -> ui::MainWindow* { return p->get(); };
  std::string normal = Site("normal"), priv = Site("private"),
              shared = Site("shared");
  auto is_storage = [](const std::string& u) { return Has(u, "/storage"); };

  LoadStep("normal storage", M, normal + "/storage?role=normal&nonce=" + nonce,
           is_storage);
  EvalStep("normal cookie", M, "ncookie",
           "document.cookie.indexOf('birchnormal_" + nonce +
               "')>=0?'yes':'no'");
  Then("normal cookie set", [] {
    Expect("private", "normal cookie set", "yes", Value("ncookie"));
  });
  LoadStep("normal on shared host", M,
           shared + "/storage?role=normalshared&nonce=" + nonce, is_storage);
  Do("open private window",
     [p] { *p = CefRefPtr<ui::MainWindow>(app::Shell::Get().OpenPrivate()); },
     [p] { return p->get() && p->get()->cef_window(); }, 10000);
  Do("private tab",
     [p, priv, nonce] {
       (*p)->NewTab(priv + "/storage?role=private&nonce=" + nonce, true);
     },
     [P] { return Settled(SelectedPage(P())); });
  Then("private window", [P] {
    Expect("private", "private window is private", "yes",
           YesNo(P()->is_private()));
    Expect("private", "private window title shows Private", "Private",
           P()->space_title());
  });
  EvalStep("private cookie", P, "pcookie",
           "document.cookie.indexOf('birchprivate_" + nonce +
               "')>=0?'yes':'no'");
  Then("private cookie set", [] {
    Expect("private", "private cookie set (in memory)", "yes", Value("pcookie"));
  });
  LoadStep("private on shared host", P,
           shared + "/storage?role=privshared&nonce=" + nonce, is_storage);
  EvalStep("private reads shared host", P, "pshared",
           "(document.cookie.indexOf('birchprivshared_')>=0?'own':'-')+'|'+"
           "(document.cookie.indexOf('birchnormalshared_')>=0?'normal':'-')");
  Then("isolation 1", [] {
    Expect("private", "private window on shared host sees (own|normal's)",
           "own|-", Value("pshared"));
  });
  LoadStep("normal back on shared host", M, shared + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  EvalStep("normal reads shared host", M, "nshared",
           "(document.cookie.indexOf('birchnormalshared_')>=0?'own':'-')+'|'+"
           "(document.cookie.indexOf('birchprivshared_')>=0?'private':'-')");
  Then("isolation 2", [] {
    Expect("private", "normal window on shared host sees (own|private's)",
           "own|-", Value("nshared"));
  });
  Sleep(1500);
  Then("private window not saved", [] {
    app::Shell::Get().SaveNow();
    std::string text;
    core::ReadFileUtf8Path(ProfileFile("state.json"), &text);
    Expect("private", "state.json mentions the private site", "no",
           YesNo(Has(text, "private.birch.test")));
    core::AppState s;
    std::string error;
    bool ok = core::DecodeAppState(text, &s, &error);
    Expect("private", "saved windows (normal only)", "1",
           std::to_string(ok && s.windows ? s.windows->size() : 0));
  });
  Do("close private window", [p] { (*p)->Close(); },
     [p] { return (*p)->destroyed(); }, 15000);
  Then("private closed", [] { platform::Log("private: private-window-closed"); });
  LoadStep("normal back to its site", M, normal + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  Sleep(2000);
}

// ---- downloads: Downloads folder, Mark of the Web, private origin removed ------------------

BIRCH_TEST_SCENARIO(download) {
  auto events = std::make_shared<std::vector<engine::DownloadEvent>>();
  WindowRef p = std::make_shared<CefRefPtr<ui::MainWindow>>();
  Then("listen", [events] {
    engine::SetDownloadListener(
        [events](const engine::DownloadEvent& e) { events->push_back(e); });
    std::string dir = platform::DownloadsDir();
    Expect("download", "test runs download into BIRCH_DOWNLOADS",
           platform::Env("BIRCH_DOWNLOADS"), dir);
#if defined(_WIN32)
    Expect("paths", "default profile folder ends in \\Birch", "yes",
           YesNo(EndsWith(platform::DefaultProfileDir(), "\\Birch")));
    Expect("paths", "default profile folder is under LOCALAPPDATA", "yes",
           YesNo(StartsWith(platform::DefaultProfileDir(),
                            platform::Env("LOCALAPPDATA"))));
#else
    Expect("paths", "default profile folder ends in /birch", "yes",
           YesNo(EndsWith(platform::DefaultProfileDir(), "/birch")));
#endif
    Expect("paths", "default Downloads folder found", "yes",
           YesNo(EndsWith(platform::DefaultDownloadsDir(), "Downloads")));
  });
  Do("normal download",
     [] { SelectedPage(M())->Load(Site("dl") + "/download/birch-test.bin"); },
     [events] { return !events->empty(); }, 20000);
  Then("normal download done", [events] {
    const engine::DownloadEvent e = events->front();
    Expect("download", "normal download complete", "yes", YesNo(e.complete));
    Expect("download", "saved in the Downloads folder", "yes",
           YesNo(StartsWith(e.path, platform::DownloadsDir()) &&
                 core::FileExists(e.path)));
    Expect("download", "file size", "1280", std::to_string(e.bytes));
#if defined(_WIN32)
    Expect("motw", "normal download: Internet zone", "yes",
           YesNo(Has(e.mark, "ZoneId=3")));
    Expect("motw", "normal download: source address kept", "yes",
           YesNo(Has(e.mark, "dl.birch.test")));
    Expect("motw", "mark written by Chromium itself", "yes",
           YesNo(e.mark_written_by_chromium));
#else
    platform::Log("motw: linux origin attributes: " +
                  std::string(e.mark.empty() ? "none" : "present"));
#endif
  });
  Do("private window",
     [p] { *p = CefRefPtr<ui::MainWindow>(app::Shell::Get().OpenPrivate()); },
     [p] { return p->get() && p->get()->cef_window(); }, 10000);
  Do("private download",
     [p] { (*p)->NewTab(Site("pdl") + "/download/birch-private.bin", true); },
     [events] { return events->size() >= 2; }, 25000);
  Then("private download done", [events] {
    const engine::DownloadEvent e = (*events)[1];
    Expect("download", "private download complete", "yes", YesNo(e.complete));
    Expect("download", "private download flagged private", "yes",
           YesNo(e.is_private));
    Expect("download", "private file saved where the person expects it", "yes",
           YesNo(core::FileExists(e.path)));
#if defined(_WIN32)
    Expect("motw", "private download: Internet zone kept", "yes",
           YesNo(Has(e.mark, "ZoneId=3")));
    Expect("motw", "private download: no source address", "no",
           YesNo(Has(e.mark, "pdl.birch.test") || Has(e.mark, "HostUrl")));
#else
    Expect("motw", "private download: no origin attributes", "",
           e.mark);
#endif
  });
  Do("close private window", [p] { (*p)->Close(); },
     [p] { return (*p)->destroyed(); }, 15000);
  Sleep(1000);
}

// ---- permissions: requests reach Birch and are refused ------------------------------------

BIRCH_TEST_SCENARIO(perm) {
  LoadStep("permission page", M,
           "http://127.0.0.1:" + HttpPort() + "/perm.html",
           [](const std::string& u) { return EndsWith(u, "/perm.html"); });
  EvalStep("camera", M, "cam",
           "navigator.mediaDevices.getUserMedia({video:true}).then("
           "function(){return 'granted'},function(e){return e.name})",
           true);
  EvalStep("microphone", M, "mic",
           "navigator.mediaDevices.getUserMedia({audio:true}).then("
           "function(){return 'granted'},function(e){return e.name})",
           true);
  EvalStep("location", M, "geo",
           "new Promise(function(r){navigator.geolocation.getCurrentPosition("
           "function(){r('granted')},function(e){r('error'+e.code)},"
           "{timeout:10000})})",
           true, 20000);
  EvalStep("notifications", M, "notif", "Notification.requestPermission()",
           true);
  EvalStep("permission states", M, "states",
           "Promise.all(['camera','microphone','geolocation','notifications']"
           ".map(function(n){return navigator.permissions.query({name:n})"
           ".then(function(s){return n+'='+s.state},function(){return n+'=?'})"
           "})).then(function(a){return a.join(',')})");
  Then("permission results", [] {
    const engine::EngineStats& s = engine::Stats();
    Expect("perm", "camera result", "NotAllowedError", Value("cam"));
    Expect("perm", "microphone result", "NotAllowedError", Value("mic"));
    Expect("perm", "location result", "error1", Value("geo"));
    Expect("perm", "notification result", "denied", Value("notif"));
    Expect("perm", "camera request reached Birch", "yes",
           YesNo(s.camera_requests > 0));
    Expect("perm", "microphone request reached Birch", "yes",
           YesNo(s.microphone_requests > 0));
    Expect("perm", "location request reached Birch", "yes",
           YesNo(s.location_requests > 0));
    Expect("perm", "notification request reached Birch", "yes",
           YesNo(s.notification_requests > 0));
    Expect("perm", "nothing granted afterwards", "no",
           YesNo(Has(Value("states"), "granted")));
    platform::Log("perm: states " + Value("states"));
  });
}

// ---- certificates: a bad one never loads ----------------------------------------------------

BIRCH_TEST_SCENARIO(tls) {
  LoadStep("bad certificate", M,
           "https://bad.birch.test:" + HttpsPort() + "/tls/secret.html",
           [](const std::string& u) { return StartsWith(u, "birch://error"); });
  EvalStep("error page", M, "tls",
           "document.body.dataset.birchError+'|'+(document.body.innerText"
           ".indexOf('BADCERT-CONTENT')>=0?'content':'no-content')");
  Then("tls", [] {
    Expect("tls", "certificate error reached Birch", "yes",
           YesNo(engine::Stats().certificate_errors > 0));
    Expect("tls", "Birch's error page, not the site", "cert|no-content",
           Value("tls"));
    Expect("tls", "address box", "Birch", M()->address_text());
  });
}

// ---- NetLog runs: ordinary browsing, then idle; the harness reads the log --------------------

BIRCH_TEST_SCENARIO(netlog) {
  WindowRef p = std::make_shared<CefRefPtr<ui::MainWindow>>();
  auto P = [p]() -> ui::MainWindow* { return p->get(); };
  LoadStep("page", M, Site("a") + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  Do("second tab", [] { M()->NewTab(Site("b") + "/page2.html", true); },
     [] { return Settled(SelectedPage(M())) && EndsWith(Committed(M()), "/page2.html"); });
  Do("private window",
     [p] { *p = CefRefPtr<ui::MainWindow>(app::Shell::Get().OpenPrivate()); },
     [p] { return p->get() && p->get()->cef_window(); }, 10000);
  Do("private page", [p] { (*p)->NewTab(Site("private") + "/page1.html", true); },
     [P] { return Settled(SelectedPage(P())); });
  Then("netlog hold", [] { platform::Log("netlog: hold"); });
  std::string hold = platform::Env("BIRCH_HOLD");
  Sleep(hold.empty() ? 75000 : std::stoi(hold) * 1000);
}

// Positive control for the NetLog check: one deliberate lookup of a host that
// is not a fixture. The harness must flag "control.example".
BIRCH_TEST_SCENARIO(netlogcontrol) {
  LoadStep("non-fixture host", M,
           "http://control.example:" + HttpPort() + "/page1.html",
           [](const std::string& u) { return StartsWith(u, "birch://error"); },
           30000);
  Sleep(2000);
}

// ---- sandbox: Chromium's own report, then a pause for process inspection ---------------------

BIRCH_TEST_SCENARIO(sandbox) {
  LoadStep("renderer page", M, Site("a") + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  Do("chrome://sandbox", [] { M()->NewTab("chrome://sandbox", true); },
     [] { return Settled(SelectedPage(M())); });
  Sleep(4000);
  EvalStep("read the sandbox page", M, "sbx",
           "document.body?document.body.innerText.slice(0,6000):''");
  Then("log", [] {
    std::string text = Value("sbx");
    for (const std::string& line : core::Split(text, '\n')) {
      if (!core::TrimSpaces(line).empty()) {
        platform::Log("sandboxpage: " + line.substr(0, 200));
      }
    }
    platform::Log("sandbox: hold");
  });
  std::string hold = platform::Env("BIRCH_HOLD");
  Sleep(hold.empty() ? 20000 : std::stoi(hold) * 1000);
}

}  // namespace birch::tests
