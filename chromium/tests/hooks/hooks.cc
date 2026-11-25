// The step runner behind every BIRCH_TEST scenario.
#include "tests/hooks/hooks.h"

#include <chrono>
#include <map>
#include <vector>

#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/cef_values.h"

#include "app/shell.h"
#include "engine/engine.h"
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
     [] { return Settled(SelectedPage(Main())); }, 60000);
  it->second();
  R().Start([name] {
    platform::Log("summary: scenario=" + name +
                  " checks=" + std::to_string(g_checks) +
                  " failed=" + std::to_string(g_failed));
    app::Shell::Get().Quit("tests done");
  });
}

}  // namespace birch::tests
