// BIRCH_* test hooks. Each scenario is a list of steps (action + condition +
// timeout) run on the UI thread. Results are logged as
// "<area>: <what> expected=… got=… -> PASS|FAIL". Page reads go through the
// DevTools protocol with fixed expressions: no page-to-app bridge exists.
#include <chrono>

#include "include/cef_parser.h"
#include "include/cef_values.h"

#include "birch.h"

namespace birch {

State& state() {
  static State s;
  return s;
}

namespace {

using Clock = std::chrono::steady_clock;

int g_checks = 0;
int g_failed = 0;
bool g_quit_posted = false;
CefRefPtr<BrowserWindow> g_main;

void Expect(const std::string& area, const std::string& what,
            const std::string& expected, const std::string& got) {
  g_checks++;
  if (!Check(area, what, expected, got)) {
    g_failed++;
  }
}

std::string YesNo(bool b) {
  return b ? "yes" : "no";
}

bool EndsWith(const std::string& s, const std::string& suffix) {
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool StartsWith(const std::string& s, const std::string& prefix) {
  return s.rfind(prefix, 0) == 0;
}

// ---- step runner -------------------------------------------------------------

struct Step {
  std::string name;
  std::function<void()> act;
  std::function<bool()> done;
  int timeout_ms;
};

class Runner {
 public:
  void Do(const std::string& name, std::function<void()> act,
          std::function<bool()> done, int timeout_ms = 15000) {
    steps_.push_back({name, std::move(act), std::move(done), timeout_ms});
  }
  void Then(const std::string& name, std::function<void()> act) {
    Do(name, std::move(act), [] { return true; }, 1000);
  }
  void Sleep(int ms) {
    auto until = std::make_shared<Clock::time_point>();
    Do(
        "sleep " + std::to_string(ms),
        [until, ms] { *until = Clock::now() + std::chrono::milliseconds(ms); },
        [until] { return Clock::now() >= *until; }, ms + 5000);
  }
  void Start(std::function<void()> finish) {
    finish_ = std::move(finish);
    Tick();
  }

 private:
  void Tick() {
    if (state().quitting) {
      return;
    }
    if (index_ >= steps_.size()) {
      if (finish_) {
        auto f = std::move(finish_);
        finish_ = nullptr;
        f();
      }
      return;
    }
    Step& step = steps_[index_];
    if (!started_) {
      started_ = true;
      begin_ = Clock::now();
      step.act();
    }
    bool timed_out = Clock::now() - begin_ >
                     std::chrono::milliseconds(step.timeout_ms);
    if (step.done() || timed_out) {
      if (timed_out) {
        g_checks++;
        g_failed++;
        Log("step: '" + step.name + "' expected=done got=timeout -> FAIL");
      }
      index_++;
      started_ = false;
    }
    PostUI([this] { Tick(); }, 100);
  }

  std::vector<Step> steps_;
  size_t index_ = 0;
  bool started_ = false;
  Clock::time_point begin_;
  std::function<void()> finish_;
};

Runner& runner() {
  static Runner r;
  return r;
}

// ---- helpers ---------------------------------------------------------------

std::string HttpPort() {
  std::string p = Env("BIRCH_HTTP_PORT");
  return p.empty() ? "8000" : p;
}
std::string HttpsPort() {
  std::string p = Env("BIRCH_HTTPS_PORT");
  return p.empty() ? "8443" : p;
}
std::string Site(const std::string& host) {
  return "http://" + host + ".birch.test:" + HttpPort();
}

// The value of a Runtime.evaluate result (strings unquoted), or
// "exception"/"missing".
std::string Value(const std::string& key) {
  auto it = state().results.find(key);
  if (it == state().results.end()) {
    return "missing";
  }
  CefRefPtr<CefValue> root = CefParseJSON(it->second, JSON_PARSER_RFC);
  if (!root || root->GetType() != VTYPE_DICTIONARY) {
    return "unparsable";
  }
  CefRefPtr<CefDictionaryValue> d = root->GetDictionary();
  if (d->HasKey("devtools_error")) {
    return "devtools-error";
  }
  if (d->HasKey("exceptionDetails")) {
    return "exception";
  }
  CefRefPtr<CefDictionaryValue> r = d->GetDictionary("result");
  if (!r || !r->HasKey("value")) {
    return "undefined";
  }
  CefRefPtr<CefValue> v = r->GetValue("value");
  switch (v->GetType()) {
    case VTYPE_STRING:
      return v->GetString().ToString();
    case VTYPE_BOOL:
      return v->GetBool() ? "true" : "false";
    case VTYPE_INT:
      return std::to_string(v->GetInt());
    case VTYPE_DOUBLE:
      return std::to_string(v->GetDouble());
    default:
      return "other";
  }
}

bool Has(const std::string& key) {
  return state().results.count(key) > 0;
}

void EvalStep(const std::string& name, std::function<std::shared_ptr<Tab>()> tab,
              const std::string& key, const std::string& expression,
              bool gesture = false, int timeout_ms = 15000) {
  runner().Do(
      name,
      [tab, key, expression, gesture] {
        state().results.erase(key);
        Evaluate(tab(), key, expression, gesture);
      },
      [key] { return Has(key); }, timeout_ms);
}

std::shared_ptr<Tab> MainTab() {
  return g_main ? g_main->active() : nullptr;
}

bool Settled(const std::shared_ptr<Tab>& t) {
  return t && t->browser && !t->loading && !t->committed_url.empty();
}

void LoadStep(const std::string& name,
              std::function<std::shared_ptr<Tab>()> tab, const std::string& url,
              std::function<bool(const std::string&)> committed_ok,
              int timeout_ms = 20000) {
  auto before = std::make_shared<int>(0);
  runner().Do(
      name,
      [tab, url, before] {
        std::shared_ptr<Tab> t = tab();
        if (t && t->browser) {
          *before = t->load_ends;
          t->loading = true;
          t->browser->GetMainFrame()->LoadURL(url);
        }
      },
      [tab, committed_ok] {
        std::shared_ptr<Tab> t = tab();
        return Settled(t) && committed_ok(t->committed_url);
      },
      timeout_ms);
}

void WaitReady(const std::string& name,
               std::function<std::shared_ptr<Tab>()> tab,
               int timeout_ms = 20000) {
  runner().Do(name, [] {}, [tab] { return Settled(tab()); }, timeout_ms);
}

void WriteSnapshot(const std::string& key, const std::string& path) {
  auto it = state().results.find(key);
  if (it == state().results.end()) {
    Log("snapshot: none");
    return;
  }
  CefRefPtr<CefValue> root = CefParseJSON(it->second, JSON_PARSER_RFC);
  if (!root || root->GetType() != VTYPE_DICTIONARY ||
      !root->GetDictionary()->HasKey("data")) {
    Log("snapshot: failed");
    return;
  }
  CefRefPtr<CefBinaryValue> png =
      CefBase64Decode(root->GetDictionary()->GetString("data"));
  std::string bytes(png ? png->GetSize() : 0, '\0');
  if (png) {
    png->GetData(&bytes[0], bytes.size(), 0);
  }
  Log(std::string("snapshot: wrote=") + YesNo(WriteFile(path, bytes)) +
      " bytes=" + std::to_string(bytes.size()));
}

void SnapshotSteps(std::function<std::shared_ptr<Tab>()> tab) {
  std::string path = Env("BIRCH_SNAPSHOT");
  if (path.empty()) {
    return;
  }
  runner().Do(
      "snapshot",
      [tab] {
        state().results.erase("snapshot");
        DevTools(tab(), "snapshot", "Page.captureScreenshot", nullptr);
      },
      [] { return Has("snapshot"); }, 10000);
  runner().Then("write snapshot", [path] { WriteSnapshot("snapshot", path); });
}

// ---- scenarios -------------------------------------------------------------

// Gate 1: tabs, navigation, origin display, punycode, crash recovery, teardown.
void TabsScenario() {
  auto a = std::make_shared<std::shared_ptr<Tab>>();
  auto b = std::make_shared<std::shared_ptr<Tab>>();
  auto A = [a] { return *a; };
  auto B = [b] { return *b; };
  std::string pa = Site("a"), pb = Site("b");
  std::string idn = "http://xn--pple-43d.birch.test:" + HttpPort();

  runner().Do("first tab", [a] { *a = MainTab(); },
              [a] { return Settled(*a); });
  runner().Then("origin a", [pa] {
    Expect("tabs", "address shows origin", pa, g_main->address_text());
  });
  LoadStep("page2", A, pa + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  runner().Do("back", [a] { (*a)->browser->GoBack(); },
              [a] {
                return Settled(*a) && EndsWith((*a)->committed_url, "/page1.html");
              });
  runner().Then("after back", [a] {
    Expect("tabs", "back reached page1", "yes",
           YesNo(EndsWith((*a)->committed_url, "/page1.html")));
    Expect("tabs", "can go forward", "yes", YesNo((*a)->browser->CanGoForward()));
  });
  runner().Do("forward", [a] { (*a)->browser->GoForward(); },
              [a] {
                return Settled(*a) && EndsWith((*a)->committed_url, "/page2.html");
              });
  auto ends = std::make_shared<int>(0);
  runner().Do(
      "reload",
      [a, ends] {
        *ends = (*a)->load_ends;
        (*a)->loading = true;
        (*a)->browser->Reload();
      },
      [a, ends] { return Settled(*a) && (*a)->load_ends > *ends; });
  EvalStep("navigation type", A, "navtype",
           "performance.getEntriesByType('navigation')[0].type");
  runner().Then("reload checked", [] {
    Expect("tabs", "reload navigation type", "reload", Value("navtype"));
  });

  runner().Do("second tab", [b, pb] { *b = g_main->AddTab(pb + "/page1.html"); },
              [b] { return *b && Settled(*b); });
  runner().Then("origin b", [pb, a, pa] {
    Expect("tabs", "address follows active tab (b)", pb, g_main->address_text());
    g_main->SelectTab((*a)->id);
    Expect("tabs", "address follows active tab (a)", pa, g_main->address_text());
    Expect("tabs", "open tabs", "2", std::to_string(g_main->open_tab_count()));
  });
  runner().Then("select b", [b] { g_main->SelectTab((*b)->id); });
  // U+0430 CYRILLIC SMALL LETTER A + "pple": a lookalike of "apple".
  LoadStep("punycode lookalike", B,
           "http://\xD0\xB0pple.birch.test:" + HttpPort() + "/page1.html",
           [](const std::string& u) {
             return u.find("birch.test") != std::string::npos;
           });
  runner().Then("punycode shown", [idn] {
    Expect("tabs", "lookalike shown as punycode", idn, g_main->address_text());
  });

  runner().Do(
      "crash renderer",
      [b] {
        (*b)->loading = true;
        DevTools(*b, "crash", "Page.crash", nullptr);
      },
      [b] {
        return (*b)->crashed && Settled(*b) &&
               StartsWith((*b)->committed_url, "birch://error");
      },
      25000);
  runner().Then("crash page", [b] {
    Expect("tabs", "renderer crash detected", "yes", YesNo((*b)->crashed));
    Expect("tabs", "crash shows error page origin", "birch://error",
           g_main->address_text());
  });
  EvalStep("error page reason", B, "crashreason",
           "document.body.dataset.birchError");
  runner().Then("crash reason", [] {
    Expect("tabs", "error page reason", "crash", Value("crashreason"));
  });
  LoadStep("recover", B, pb + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  runner().Then("recovered", [b] {
    Expect("tabs", "tab usable after crash", "yes",
           YesNo(EndsWith((*b)->committed_url, "/page2.html")));
  });

  // A web page must not reach birch:// (display-isolated scheme).
  EvalStep("page links to birch://", B, "spoof",
           "(function(){try{location.href='birch://error/?reason=spoof';"
           "return 'tried'}catch(e){return 'threw'}})()");
  runner().Sleep(1500);
  runner().Then("spoof blocked", [b] {
    Expect("tabs", "web page cannot open birch://", "blocked",
           StartsWith((*b)->committed_url, "birch://") ? "opened" : "blocked");
  });
  EvalStep("page fetches birch://", B, "spooffetch",
           "fetch('birch://error/').then(function(){return 'fetched'},"
           "function(){return 'refused'})");
  runner().Then("fetch refused", [] {
    Expect("tabs", "web page cannot fetch birch://", "refused",
           Value("spooffetch"));
  });

  runner().Do("close tab b", [b] { g_main->CloseTab((*b)->id); },
              [b] { return (*b)->closed; }, 10000);
  runner().Then("after close", [a, b, pa] {
    Expect("tabs", "closed tab torn down (OnBeforeClose)", "yes",
           YesNo((*b)->closed && !(*b)->browser));
    Expect("tabs", "open tabs after close", "1",
           std::to_string(g_main->open_tab_count()));
    Expect("tabs", "remaining tab active", std::to_string((*a)->id),
           g_main->active() ? std::to_string(g_main->active()->id) : "none");
    Expect("tabs", "address after close", pa, g_main->address_text());
  });
  SnapshotSteps(A);
}

// Gate 2: normal vs private storage. The orchestrator scans BIRCH_HOME after
// exit for the private markers.
void StorageScenario() {
  std::string nonce = Env("BIRCH_NONCE");
  auto p = std::make_shared<BrowserWindow*>(nullptr);
  auto P = [p] { return *p ? (*p)->active() : nullptr; };
  std::string normal = Site("normal"), priv = Site("private");

  LoadStep("normal storage", MainTab,
           normal + "/storage?role=normal&nonce=" + nonce,
           [](const std::string& u) { return u.find("/storage") != std::string::npos; });
  EvalStep("normal cookie", MainTab, "ncookie",
           "document.cookie.indexOf('birchnormal_" + nonce + "')>=0?'yes':'no'");
  runner().Then("normal cookie set", [] {
    Expect("storage", "normal cookie set", "yes", Value("ncookie"));
  });
  runner().Do(
      "open private window",
      [p, priv, nonce] {
        *p = BrowserWindow::Open(Style::kAlloy, true,
                                 priv + "/storage?role=private&nonce=" + nonce);
      },
      [P] { return Settled(P()); });
  EvalStep("private cookie", P, "pcookie",
           "document.cookie.indexOf('birchprivate_" + nonce + "')>=0?'yes':'no'");
  runner().Then("private cookie set", [] {
    Expect("storage", "private cookie set (in memory)", "yes", Value("pcookie"));
  });
  LoadStep("private sees normal site", P, normal + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  EvalStep("private reads normal cookie", P, "pcross",
           "document.cookie.indexOf('birchnormal_')>=0?'yes':'no'");
  runner().Then("isolation 1", [] {
    Expect("storage", "private window sees normal cookie", "no", Value("pcross"));
  });
  LoadStep("normal sees private site", MainTab, priv + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  EvalStep("normal reads private cookie", MainTab, "ncross",
           "document.cookie.indexOf('birchprivate_')>=0?'yes':'no'");
  runner().Then("isolation 2", [] {
    Expect("storage", "normal window sees private cookie", "no", Value("ncross"));
  });
  runner().Do("close private window", [p] { (*p)->Close(); },
              [p] { return (*p)->destroyed(); }, 15000);
  runner().Then("private closed", [p] {
    Expect("storage", "private window closed", "yes", YesNo((*p)->destroyed()));
    Log("storage: private-window-closed");
  });
  LoadStep("normal back to its site", MainTab, normal + "/page2.html",
           [](const std::string& u) { return EndsWith(u, "/page2.html"); });
  runner().Sleep(2000);
}

// Gate 3: download into a scratch folder with Mark of the Web.
void DownloadScenario() {
  auto w = std::make_shared<BrowserWindow*>(nullptr);
  runner().Do(
      "download (alloy tab)",
      [] {
        MainTab()->browser->GetMainFrame()->LoadURL(
            Site("dl") + "/download/birch-test.bin");
      },
      [] { return state().downloads_done >= 1; }, 20000);
  runner().Then("download 1", [] {
    Expect("download", "alloy-style download complete", "yes",
           YesNo(state().downloads_done >= 1));
  });
  runner().Do(
      "download (chrome-style window)",
      [w] {
        *w = BrowserWindow::Open(Style::kChrome, false,
                                 Site("dl2") + "/download/birch-test-2.bin");
      },
      [] { return state().downloads_done >= 2; }, 25000);
  runner().Then("download 2", [w] {
    Expect("download", "chrome-style download complete", "yes",
           YesNo(state().downloads_done >= 2));
    if (*w) {
      (*w)->Close();
    }
  });
  runner().Sleep(1500);
}

void LogPageLines(const std::string& prefix, const std::string& text) {
  size_t pos = 0;
  int n = 0;
  while (pos < text.size() && n < 80) {
    size_t end = text.find('\n', pos);
    if (end == std::string::npos) {
      end = text.size();
    }
    std::string line = text.substr(pos, end - pos);
    if (!line.empty()) {
      Log(prefix + line);
      n++;
    }
    pos = end + 1;
  }
}

// Gates 4 and 11: Chromium's own sandbox report, then a pause while the
// orchestrator inspects the running processes.
void SandboxScenario() {
  auto t = std::make_shared<std::shared_ptr<Tab>>();
  auto w = std::make_shared<BrowserWindow*>(nullptr);
  auto T = [t] { return *t; };
  auto W = [w] { return *w ? (*w)->active() : nullptr; };
  LoadStep("renderer page", MainTab, Site("a") + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  runner().Do("alloy chrome://sandbox",
              [t] { *t = g_main->AddTab("chrome://sandbox"); },
              [t] { return *t && Settled(*t); });
  runner().Sleep(4000);
  EvalStep("read alloy sandbox page", T, "sbx1",
           "document.body?document.body.innerText.slice(0,6000):''");
  runner().Then("log alloy", [t] {
    Log("sandbox: alloy page origin=" + DisplayOrigin((*t)->committed_url));
    LogPageLines("sandboxpage-alloy: ", Value("sbx1"));
  });
  runner().Do(
      "chrome-style chrome://sandbox",
      [w] { *w = BrowserWindow::Open(Style::kChrome, false, "chrome://sandbox"); },
      [W] { return Settled(W()); });
  runner().Sleep(4000);
  EvalStep("read chrome sandbox page", W, "sbx2",
           "document.body?document.body.innerText.slice(0,6000):''");
  runner().Then("log chrome", [] {
    LogPageLines("sandboxpage-chrome: ", Value("sbx2"));
    Log("sandbox: hold");
  });
  std::string hold = Env("BIRCH_HOLD");
  runner().Sleep(hold.empty() ? 20000 : std::stoi(hold) * 1000);
}

// Gate 6: permission requests reach Birch and are refused.
void PermissionScenario() {
  LoadStep("permission page", MainTab,
           "http://127.0.0.1:" + HttpPort() + "/perm.html",
           [](const std::string& u) { return EndsWith(u, "/perm.html"); });
  EvalStep("camera", MainTab, "cam",
           "navigator.mediaDevices.getUserMedia({video:true}).then("
           "function(){return 'granted'},function(e){return e.name})",
           true);
  EvalStep("microphone", MainTab, "mic",
           "navigator.mediaDevices.getUserMedia({audio:true}).then("
           "function(){return 'granted'},function(e){return e.name})",
           true);
  EvalStep("location", MainTab, "geo",
           "new Promise(function(r){navigator.geolocation.getCurrentPosition("
           "function(){r('granted')},function(e){r('error'+e.code)},"
           "{timeout:10000})})",
           true, 20000);
  EvalStep("notifications", MainTab, "notif",
           "Notification.requestPermission()", true);
  EvalStep("permission states", MainTab, "states",
           "Promise.all(['camera','microphone','geolocation','notifications']"
           ".map(function(n){return navigator.permissions.query({name:n})"
           ".then(function(s){return n+'='+s.state},function(){return n+'=?'})"
           "})).then(function(a){return a.join(',')})");
  runner().Then("permission results", [] {
    State& s = state();
    Expect("perm", "camera result", "NotAllowedError", Value("cam"));
    Expect("perm", "microphone result", "NotAllowedError", Value("mic"));
    Expect("perm", "location result", "error1", Value("geo"));
    Expect("perm", "notification result", "denied", Value("notif"));
    Expect("perm", "camera request reached Birch", "yes",
           YesNo(s.camera_prompts > 0 || s.media_prompts > 0));
    Expect("perm", "microphone request reached Birch", "yes",
           YesNo(s.mic_prompts > 0 || s.media_prompts > 1));
    Expect("perm", "location request reached Birch", "yes",
           YesNo(s.geo_prompts > 0));
    Expect("perm", "notification request reached Birch", "yes",
           YesNo(s.notification_prompts > 0));
    std::string states = Value("states");
    Expect("perm", "nothing granted afterwards", "no",
           YesNo(states.find("granted") != std::string::npos));
    Log("perm: states " + states);
  });
}

// Gate 7: a bad certificate never loads.
void TlsScenario() {
  auto w = std::make_shared<BrowserWindow*>(nullptr);
  auto W = [w] { return *w ? (*w)->active() : nullptr; };
  std::string url = "https://bad.birch.test:" + HttpsPort() + "/tls/secret.html";
  LoadStep("bad certificate (alloy)", MainTab, url,
           [](const std::string& u) { return StartsWith(u, "birch://error"); });
  EvalStep("alloy error page", MainTab, "tls1",
           "document.body.dataset.birchError+'|'+(document.body.innerText"
           ".indexOf('BADCERT-CONTENT')>=0?'content':'no-content')");
  runner().Then("alloy tls", [] {
    Expect("tls", "alloy: certificate error reached Birch", "yes",
           YesNo(MainTab()->cert_errors > 0));
    Expect("tls", "alloy: page shown", "cert|no-content", Value("tls1"));
    Expect("tls", "alloy: address", "birch://error", g_main->address_text());
  });
  runner().Do(
      "bad certificate (chrome style)",
      [w, url] { *w = BrowserWindow::Open(Style::kChrome, false, url); },
      [W] { return Settled(W()); }, 20000);
  runner().Sleep(1500);
  EvalStep("chrome error page", W, "tls2",
           "location.protocol+'|'+(document.body.innerText"
           ".indexOf('BADCERT-CONTENT')>=0?'content':'no-content')");
  runner().Then("chrome tls", [W] {
    Expect("tls", "chrome style: certificate error reached Birch", "yes",
           YesNo(W() && W()->cert_errors > 0));
    Expect("tls", "chrome style: page shown", "birch:|no-content", Value("tls2"));
  });
}

// Gate 8: uBlock Origin Lite blocks a known ad request.
void UbolScenario() {
  bool expect_block = EnvOn("BIRCH_EXPECT_BLOCK");
  auto w = std::make_shared<BrowserWindow*>(nullptr);
  auto W = [w] { return *w ? (*w)->active() : nullptr; };
  auto id = std::make_shared<std::string>();
  runner().Sleep(8000);  // extension install + rule registration
  LoadStep("ad test page", MainTab, Site("news") + "/ubol.html",
           [](const std::string& u) { return EndsWith(u, "/ubol.html"); });
  runner().Sleep(2500);
  EvalStep("ad results", MainTab, "ads", "JSON.stringify(window.__birch_ads)");
  runner().Then("ad check", [expect_block] {
    std::string r = Value("ads");
    Log("ubol: alloy results " + r);
    std::string ad = expect_block ? "\"adsense\":\"blocked\"" : "\"adsense\":\"loaded\"";
    std::string ga = expect_block ? "\"analytics\":\"blocked\"" : "\"analytics\":\"loaded\"";
    Expect("ubol", "alloy: ad script", "yes", YesNo(r.find(ad) != std::string::npos));
    Expect("ubol", "alloy: analytics beacon", "yes",
           YesNo(r.find(ga) != std::string::npos));
    Expect("ubol", "alloy: control script (not an ad host)", "yes",
           YesNo(r.find("\"control\":\"loaded\"") != std::string::npos));
  });
  if (!expect_block) {
    return;
  }
  runner().Do(
      "chrome://extensions",
      [w] { *w = BrowserWindow::Open(Style::kChrome, false, "chrome://extensions"); },
      [W] { return Settled(W()); });
  runner().Sleep(2000);
  EvalStep("extension list", W, "exts",
           "(chrome.developerPrivate?chrome.developerPrivate.getExtensionsInfo()"
           ".then(function(a){return JSON.stringify(a.map(function(e){return {"
           "id:e.id,name:e.name,version:e.version,state:e.state,location:e.location,"
           "manifestErrors:(e.manifestErrors||[]).length,runtimeErrors:"
           "(e.runtimeErrors||[]).length}}))}):Promise.resolve('no-api'))");
  EvalStep("ubol id", W, "ubolid",
           "(chrome.developerPrivate?chrome.developerPrivate.getExtensionsInfo()"
           ".then(function(a){var e=a.filter(function(x){return /uBlock/i.test("
           "x.name)})[0];return e?e.id:''}):Promise.resolve(''))");
  runner().Then("extension listed", [id] {
    Log("ubol: extensions " + Value("exts"));
    *id = Value("ubolid");
    Expect("ubol", "uBOL listed in chrome://extensions", "yes",
           YesNo(id->size() == 32));
  });
  runner().Do(
      "open uBOL popup page",
      [w, id] {
        if (*w && (*w)->active() && (*w)->active()->browser && id->size() == 32) {
          (*w)->active()->loading = true;
          (*w)->active()->browser->GetMainFrame()->LoadURL(
              "chrome-extension://" + *id + "/popup.html");
        }
      },
      [W] {
        return Settled(W()) &&
               StartsWith(W()->committed_url, "chrome-extension://");
      },
      15000);
  runner().Sleep(2000);
  EvalStep("popup rendered", W, "popup",
           "document.readyState+'|'+document.querySelectorAll('*').length");
  runner().Then("popup check", [] {
    std::string r = Value("popup");
    Log("ubol: popup page " + r);
    Expect("ubol", "uBOL popup page renders", "yes",
           YesNo(StartsWith(r, "complete|") && r != "complete|0"));
  });
  LoadStep("ad page in chrome style", W, Site("news2") + "/ubol.html",
           [](const std::string& u) { return EndsWith(u, "/ubol.html"); });
  runner().Sleep(2500);
  EvalStep("chrome ad results", W, "ads2", "JSON.stringify(window.__birch_ads)");
  runner().Then("chrome ad check", [] {
    std::string r = Value("ads2");
    Log("ubol: chrome-style results " + r);
    Expect("ubol", "chrome style: ad script", "yes",
           YesNo(r.find("\"adsense\":\"blocked\"") != std::string::npos));
  });
}

// Gate 10: codecs and DRM.
void CodecScenario() {
  LoadStep("codec page", MainTab, Site("media") + "/codecs.html",
           [](const std::string& u) { return EndsWith(u, "/codecs.html"); });
  EvalStep("codec tests", MainTab, "codecs", "window.runCodecTests()", true,
           60000);
  runner().Then("codec results", [] { Log("codecs: " + Value("codecs")); });
}

// Gate 12: one blank tab, idle.
void IdleScenario() {
  runner().Then("idle", [] { Log("idle: hold"); });
  std::string hold = Env("BIRCH_HOLD");
  runner().Sleep(hold.empty() ? 25000 : std::stoi(hold) * 1000);
}

// Gate 5: ordinary browsing against local fixtures, then a long idle so
// background services get a chance to call home. The orchestrator reads the
// NetLog afterwards.
void NetlogScenario() {
  auto p = std::make_shared<BrowserWindow*>(nullptr);
  auto c = std::make_shared<BrowserWindow*>(nullptr);
  LoadStep("page", MainTab, Site("a") + "/page1.html",
           [](const std::string& u) { return EndsWith(u, "/page1.html"); });
  runner().Do("second tab",
              [] { g_main->AddTab(Site("b") + "/page2.html"); },
              [] { return Settled(g_main->active()); });
  runner().Do(
      "private window",
      [p] { *p = BrowserWindow::Open(Style::kAlloy, true, Site("private") + "/page1.html"); },
      [p] { return Settled((*p)->active()); });
  runner().Do(
      "chrome-style window",
      [c] { *c = BrowserWindow::Open(Style::kChrome, false, Site("c") + "/page1.html"); },
      [c] { return Settled((*c)->active()); });
  runner().Then("netlog hold", [] { Log("netlog: hold"); });
  std::string hold = Env("BIRCH_HOLD");
  runner().Sleep(hold.empty() ? 75000 : std::stoi(hold) * 1000);
}

}  // namespace

void Evaluate(const std::shared_ptr<Tab>& tab, const std::string& key,
              const std::string& expression, bool user_gesture) {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  params->SetBool("userGesture", user_gesture);
  DevTools(tab, key, "Runtime.evaluate", params);
}

void DevTools(const std::shared_ptr<Tab>& tab, const std::string& key,
              const std::string& method, CefRefPtr<CefDictionaryValue> params) {
  State& s = state();
  if (!tab || !tab->browser) {
    s.results[key] = "{\"devtools_error\":\"no browser\"}";
    return;
  }
  int id = s.next_message_id++;
  s.pending[id] = key;
  if (tab->browser->GetHost()->ExecuteDevToolsMethod(id, method, params) == 0) {
    s.pending.erase(id);
    s.results[key] = "{\"devtools_error\":\"not sent\"}";
  }
}

void StartTests() {
  std::string tests = Env("BIRCH_TEST");
  std::string open = Env("BIRCH_OPEN");
  std::string first = open;
  if (first.empty()) {
    first = tests.empty() ? "birch://blank/" : Site("a") + "/page1.html";
  }
  if (tests == "idle" || tests == "perm") {
    first = "birch://blank/";
  }
  g_main = BrowserWindow::Open(Style::kAlloy, false, first);
  if (tests.empty()) {
    return;  // interactive use
  }
  Log("test: start " + tests);
  WaitReady("main window", MainTab);
  if (tests == "tabs") {
    TabsScenario();
  } else if (tests == "storage") {
    StorageScenario();
  } else if (tests == "download") {
    DownloadScenario();
  } else if (tests == "sandbox") {
    SandboxScenario();
  } else if (tests == "perm") {
    PermissionScenario();
  } else if (tests == "tls") {
    TlsScenario();
  } else if (tests == "ubol") {
    UbolScenario();
  } else if (tests == "codecs") {
    CodecScenario();
  } else if (tests == "idle") {
    IdleScenario();
  } else if (tests == "netlog") {
    NetlogScenario();
  } else {
    Log("test: unknown scenario " + tests);
  }
  runner().Start([tests] {
    Log("summary: scenario=" + tests + " checks=" + std::to_string(g_checks) +
        " failed=" + std::to_string(g_failed));
    Shutdown("tests done");
  });
  std::string delay = Env("BIRCH_DELAY");
  if (!delay.empty()) {
    PostUI(
        [] {
          if (!state().quitting) {
            Log("timeout: BIRCH_DELAY reached; checks=" +
                std::to_string(g_checks) + " failed=" +
                std::to_string(g_failed));
            Shutdown("timeout");
          }
        },
        static_cast<int64_t>(std::stoi(delay)) * 1000);
  }
}

void Shutdown(const std::string& why) {
  State& s = state();
  if (s.quitting) {
    return;
  }
  s.quitting = true;
  Log("app: shutdown (" + why + ")");
  std::vector<CefRefPtr<BrowserWindow>> windows = s.windows;
  for (auto& w : windows) {
    w->Close();
  }
  for (auto& b : s.orphans) {
    b->GetHost()->CloseBrowser(true);
  }
  PostUI(
      [] {
        if (!g_quit_posted) {
          Log("app: shutdown forced after 15 s (live browsers=" +
              std::to_string(state().live_browsers) + ")");
          g_quit_posted = true;
          CefQuitMessageLoop();
        }
      },
      15000);
  MaybeQuit();
}

void MaybeQuit() {
  State& s = state();
  if (s.quitting && !g_quit_posted && s.live_browsers <= 0 &&
      s.windows.empty()) {
    g_quit_posted = true;
    g_main = nullptr;
    Log("app: all browsers closed");
    CefQuitMessageLoop();
  }
}

}  // namespace birch
