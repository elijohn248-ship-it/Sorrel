// The step runner behind every BIRCH_TEST scenario.
#include "tests/hooks/hooks.h"

#include <chrono>
#include <map>
#include <vector>

#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/cef_values.h"

#include "app/shell.h"
#include "core/ui_channel.h"
#include "engine/engine.h"
#include "engine/ui_page.h"
#include "platform/platform.h"
#include "ui/main_window.h"

namespace birch::tests {

namespace {

using Clock = std::chrono::steady_clock;

int g_checks = 0;
int g_failed = 0;
std::map<std::string, std::string> g_results;

std::map<std::string, ScenarioFn>& Registry() {
  static std::map<std::string, ScenarioFn> registry;
  return registry;
}

class FnTask : public CefTask {
 public:
  explicit FnTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(FnTask);
};

void Post(std::function<void()> fn, int64_t delay_ms) {
  CefPostDelayedTask(TID_UI, new FnTask(std::move(fn)), delay_ms);
}

struct Step {
  std::string name;
  std::function<void()> act;
  std::function<bool()> done;
  int timeout_ms;
};

class Runner {
 public:
  void Add(Step s) { steps_.push_back(std::move(s)); }
  void Start(std::function<void()> finish) {
    finish_ = std::move(finish);
    Tick();
  }

 private:
  void Tick() {
    if (app::Shell::Get().quitting()) {
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
    bool timed_out =
        Clock::now() - begin_ > std::chrono::milliseconds(step.timeout_ms);
    if (step.done() || timed_out) {
      if (timed_out) {
        g_checks++;
        g_failed++;
        platform::Log("step: '" + step.name +
                      "' expected=done got=timeout -> FAIL");
      }
      index_++;
      started_ = false;
    }
    Post([this] { Tick(); }, 100);
  }

  std::vector<Step> steps_;
  size_t index_ = 0;
  bool started_ = false;
  Clock::time_point begin_;
  std::function<void()> finish_;
};

Runner& R() {
  static Runner r;
  return r;
}

std::string ValueOf(const std::string& json) {
  CefRefPtr<CefValue> root = CefParseJSON(json, JSON_PARSER_RFC);
  if (!root || root->GetType() != VTYPE_DICTIONARY) {
    return "unparsable";
  }
  CefRefPtr<CefDictionaryValue> d = root->GetDictionary();
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

}  // namespace

ScenarioRegistrar::ScenarioRegistrar(const char* name, ScenarioFn fn) {
  Registry()[name] = fn;
}

namespace {

// Runtime.evaluate on the sidebar page of |w|; the value lands in |key|.
void SidebarEvaluate(ui::MainWindow* w, const std::string& key,
                     const std::string& expression) {
  g_results.erase(key);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  params->SetBool("userGesture", true);
  engine::UiPage* ui = w ? w->sidebar_page() : nullptr;
  bool sent = ui && ui->DevToolsForTest(
                        "Runtime.evaluate", params,
                        [key](bool ok, const std::string& json) {
                          g_results[key] = ok ? ValueOf(json) : "devtools-error";
                        });
  if (!sent) {
    g_results[key] = "not-sent";
  }
}

// Runtime.evaluate on any UI page (the command bar's); the value lands in |key|.
void UiEvaluate(engine::UiPage* ui, const std::string& key,
                const std::string& expression) {
  g_results.erase(key);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  params->SetBool("userGesture", true);
  bool sent = ui && ui->DevToolsForTest(
                        "Runtime.evaluate", params,
                        [key](bool ok, const std::string& json) {
                          g_results[key] = ok ? ValueOf(json) : "devtools-error";
                        });
  if (!sent) {
    g_results[key] = "not-sent";
  }
}

const char kDomSummary[] =
    "(function(){var r=[].map.call(document.querySelectorAll("
    "'#tabs li.tab:not(.leaving) .title'),function(e){return e.textContent})"
    ".join('|');return r+'#'+document.getElementById('address').value+'#'+"
    "(document.getElementById('not-secure').hidden?'no':'yes')})()";

std::string ExpectedSummary(ui::MainWindow* w) {
  std::string rows;
  for (const std::string& t : w->sidebar_titles()) {
    rows += (rows.empty() ? "" : "|") + t;
  }
  return rows + "#" + w->address_text() + "#" + YesNo(w->not_secure_shown());
}

}  // namespace

void Do(const std::string& name, std::function<void()> act,
        std::function<bool()> done, int timeout_ms) {
  R().Add({name, std::move(act), std::move(done), timeout_ms});
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

void Expect(const std::string& area, const std::string& what,
            const std::string& expected, const std::string& got) {
  g_checks++;
  if (!platform::Check(area, what, expected, got)) {
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

std::string HttpPort() {
  std::string p = platform::Env("BIRCH_HTTP_PORT");
  return p.empty() ? "8000" : p;
}

std::string HttpsPort() {
  std::string p = platform::Env("BIRCH_HTTPS_PORT");
  return p.empty() ? "8443" : p;
}

std::string Site(const std::string& host) {
  return "http://" + host + ".birch.test:" + HttpPort();
}

ui::MainWindow* Main() {
  return app::Shell::Get().main_window();
}

engine::Page* SelectedPage(ui::MainWindow* w) {
  if (!w) {
    return nullptr;
  }
  std::optional<std::string> sel = w->selected_id();
  return sel ? w->PageFor(*sel) : nullptr;
}

bool Settled(engine::Page* p) {
  return p && p->HasBrowser() && !p->IsLoading() && !p->committed_url().empty();
}

void LoadStep(const std::string& name, std::function<ui::MainWindow*()> w,
              const std::string& url, std::function<bool(const std::string&)> ok,
              int timeout_ms) {
  Do(
      name,
      [w, url] {
        if (engine::Page* p = SelectedPage(w())) {
          p->Load(url);
        }
      },
      [w, ok] {
        engine::Page* p = SelectedPage(w());
        return Settled(p) && ok(p->committed_url());
      },
      timeout_ms);
}

void EvalStep(const std::string& name, std::function<ui::MainWindow*()> w,
              const std::string& key, const std::string& expression,
              bool gesture, int timeout_ms) {
  Do(
      name,
      [w, key, expression, gesture] {
        g_results.erase(key);
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetString("expression", expression);
        params->SetBool("returnByValue", true);
        params->SetBool("awaitPromise", true);
        params->SetBool("userGesture", gesture);
        engine::Page* p = SelectedPage(w());
        bool sent = p && p->DevToolsForTest(
                             "Runtime.evaluate", params,
                             [key](bool ok, const std::string& json) {
                               g_results[key] = ok ? ValueOf(json) : "devtools-error";
                             });
        if (!sent) {
          g_results[key] = "not-sent";
        }
      },
      [key] { return g_results.count(key) > 0; }, timeout_ms);
}

void SidebarEvalStep(const std::string& name, std::function<ui::MainWindow*()> w,
                     const std::string& key, const std::string& expression,
                     int timeout_ms) {
  Do(
      name, [w, key, expression] { SidebarEvaluate(w(), key, expression); },
      [key] { return g_results.count(key) > 0; }, timeout_ms);
}

void UiEvalStep(const std::string& name, std::function<engine::UiPage*()> page,
                const std::string& key, const std::string& expression,
                int timeout_ms) {
  Do(
      name, [page, key, expression] { UiEvaluate(page(), key, expression); },
      [key] { return g_results.count(key) > 0; }, timeout_ms);
}

void BarTypeStep(const std::string& name, std::function<ui::MainWindow*()> w,
                 const std::string& key, const std::string& text) {
  UiEvalStep(
      name, [w] { return w() ? w()->command_bar_page() : nullptr; }, key,
      "new Promise(function(done){var i=document.getElementById('text'),n=0;"
      "(function go(){if((document.getElementById('bar').hidden||"
      "document.activeElement!==i)&&n++<30){setTimeout(go,100);return}"
      "var f=document.activeElement===i;i.value=" + core::ui_channel::JsonQuote(text) +
      ";i.dispatchEvent(new Event('input',{bubbles:true}));"
      "i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));"
      "done(f?'focused':'not-focused')})()})");
}

void SidebarTypeStep(const std::string& name, std::function<ui::MainWindow*()> w,
                     const std::string& key, const std::string& text) {
  // The text is a test-chosen string, quoted as a JSON string literal.
  SidebarEvalStep(
      name, w, key,
      "new Promise(function(done){var i=document.getElementById('address'),"
      "n=0;(function go(){if(document.activeElement!==i&&n++<30){"
      "setTimeout(go,100);return}var f=document.activeElement===i;i.focus();"
      "i.value=" + core::ui_channel::JsonQuote(text) + ";"
      "i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));"
      "done(f?'focused':'not-focused')})()})");
}

std::string ClickExpression(const std::string& css) {
  return
      "new Promise(function(done){var n=0;(function go(){var e="
      "document.querySelector(" + core::ui_channel::JsonQuote(css) + ");"
      "if((!e||e.disabled)&&n++<50){setTimeout(go,100);return}"
      "if(!e){done('missing');return}if(e.disabled){done('disabled');return}"
      "e.click();done('clicked')})()})";
}

void SidebarClick(ui::MainWindow* w, const std::string& key,
                  const std::string& css) {
  SidebarEvaluate(w, key, ClickExpression(css));
}

void SidebarClickStep(const std::string& name, std::function<ui::MainWindow*()> w,
                      const std::string& key, const std::string& css) {
  SidebarEvalStep(name, w, key, ClickExpression(css));
}

void SidebarMatchesStep(const std::string& area, const std::string& label,
                        std::function<ui::MainWindow*()> w) {
  auto key = std::make_shared<std::string>("dom:" + label);
  auto until = std::make_shared<Clock::time_point>();
  Do(
      "sidebar DOM: " + label,
      [w, key, until] {
        *until = Clock::now() + std::chrono::seconds(8);
        SidebarEvaluate(w(), *key, kDomSummary);
      },
      [w, key, until] {
        if (!g_results.count(*key)) {
          return false;
        }
        if (g_results[*key] == ExpectedSummary(w()) || Clock::now() > *until) {
          return true;
        }
        SidebarEvaluate(w(), *key, kDomSummary);  // not drawn yet: look again
        return false;
      },
      12000);
  Then("check sidebar DOM: " + label, [area, label, w, key] {
    Expect(area, "sidebar page shows it (" + label + ")", ExpectedSummary(w()),
           Value(*key));
  });
}

std::string RowSelector(const std::string& item_id) {
  return "#tabs li.tab[data-target=\"" + item_id + "\"]";
}

std::string Value(const std::string& key) {
  auto it = g_results.find(key);
  return it == g_results.end() ? "missing" : it->second;
}

void DevToolsStep(const std::string& name, std::function<ui::MainWindow*()> w,
                  const std::string& key, const std::string& method) {
  Do(
      name,
      [w, key, method] {
        g_results.erase(key);
        engine::Page* p = SelectedPage(w());
        bool sent = p && p->DevToolsForTest(
                             method, nullptr,
                             [key](bool ok, const std::string&) {
                               g_results[key] = ok ? "ok" : "error";
                             });
        if (!sent) {
          g_results[key] = "not-sent";
        }
      },
      [] { return true; }, 1000);
}

void StartTests() {
  std::string name = platform::Env("BIRCH_TEST");
  std::string delay = platform::Env("BIRCH_DELAY");
  if (!delay.empty()) {
    Post(
        [] {
          if (!app::Shell::Get().quitting()) {
            platform::Log("timeout: BIRCH_DELAY reached; checks=" +
                          std::to_string(g_checks) +
                          " failed=" + std::to_string(g_failed));
            app::Shell::Get().Quit("timeout");
          }
        },
        static_cast<int64_t>(std::stoi(delay)) * 1000);
  }
  if (name.empty()) {
    return;  // BIRCH_HOME alone: an interactive run with a scratch profile
  }
  auto it = Registry().find(name);
  platform::Log("test: start " + name);
  if (it == Registry().end()) {
    Expect("test", "scenario exists", name, "unknown");
    platform::Log("summary: scenario=" + name + " checks=1 failed=1");
    app::Shell::Get().Quit("unknown scenario");
    return;
  }
  // A cold first start on a CI runner (antivirus scanning freshly unpacked
  // binaries) has taken more than 20 s; allow 60 s for the first page.
  Do("main window ready", [] {},
     [] {
       return Settled(SelectedPage(Main())) && Main()->sidebar_page() &&
              Main()->sidebar_page()->ready();
     },
     60000);
  it->second();
  R().Start([name] {
    platform::Log("summary: scenario=" + name +
                  " checks=" + std::to_string(g_checks) +
                  " failed=" + std::to_string(g_failed));
    app::Shell::Get().Quit("tests done");
  });
}

}  // namespace birch::tests
