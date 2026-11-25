// BIRCH_* test hooks, compiled into the app and run only in test runs
// (BIRCH_HOME set). BIRCH_TEST=<scenario> picks a scenario; each is a list of
// steps (action + condition + timeout) on the UI thread, logging
// "<area>: <what> expected=… got=… -> PASS|FAIL" and finally
// "summary: scenario=<name> checks=N failed=M" (CLAUDE.md ▸ Chromium edition
// ▸ Testing). Page reads use the DevTools protocol with fixed expressions
// (engine::Page::DevToolsForTest): there is no page-to-app bridge.
//
// Adding a scenario: a new tests/hooks/<area>_hooks.cc with
//   BIRCH_TEST_SCENARIO(myarea) { … steps … }
// CMake picks the file up; no shared list to edit.
#ifndef BIRCH_TESTS_HOOKS_HOOKS_H_
#define BIRCH_TESTS_HOOKS_HOOKS_H_

#include <functional>
#include <memory>
#include <string>

namespace birch::ui {
class MainWindow;
}
namespace birch::engine {
class Page;
}

namespace birch::tests {

// Called by the app once windows exist (test runs only).
void StartTests();

using ScenarioFn = void (*)();
struct ScenarioRegistrar {
  ScenarioRegistrar(const char* name, ScenarioFn fn);
};
#define BIRCH_TEST_SCENARIO(name)                                          \
  static void BirchScenario_##name();                                     \
  static ::birch::tests::ScenarioRegistrar birch_registrar_##name(#name,  \
                                                    &BirchScenario_##name); \
  static void BirchScenario_##name()

// ---- steps -----------------------------------------------------------------------
void Do(const std::string& name, std::function<void()> act,
        std::function<bool()> done, int timeout_ms = 15000);
void Then(const std::string& name, std::function<void()> act);
void Sleep(int ms);
// Logs and counts one check.
void Expect(const std::string& area, const std::string& what,
            const std::string& expected, const std::string& got);
std::string YesNo(bool b);

// ---- environment -----------------------------------------------------------------
std::string HttpPort();
std::string HttpsPort();
// "http://<host>.birch.test:<port>"
std::string Site(const std::string& host);

// ---- windows and pages ------------------------------------------------------------
ui::MainWindow* Main();
// The selected tab's page in |w| (nullptr when none).
engine::Page* SelectedPage(ui::MainWindow* w);
// Not loading, with a committed address.
bool Settled(engine::Page* page);
// Loads |url| in |w|'s selected tab and waits until the committed address
// satisfies |ok|.
void LoadStep(const std::string& name, std::function<ui::MainWindow*()> w,
              const std::string& url, std::function<bool(const std::string&)> ok,
              int timeout_ms = 20000);
// Evaluates a fixed |expression| in |w|'s selected page; the value lands in
// Value(key). |gesture|: as if the person had clicked.
void EvalStep(const std::string& name, std::function<ui::MainWindow*()> w,
              const std::string& key, const std::string& expression,
              bool gesture = false, int timeout_ms = 15000);
// A plain value from an EvalStep ("missing", "exception", … on failure).
std::string Value(const std::string& key);
// A raw DevTools call on |w|'s selected page; the JSON lands in Raw(key).
void DevToolsStep(const std::string& name, std::function<ui::MainWindow*()> w,
                  const std::string& key, const std::string& method);
// The same, in |w|'s HTML sidebar (the UI host page). Test runs only, like
// every DevTools read; the sidebar's own channel is not used for reading.
void SidebarEvalStep(const std::string& name, std::function<ui::MainWindow*()> w,
                     const std::string& key, const std::string& expression,
                     int timeout_ms = 15000);
// Types |text| into the sidebar's address field and presses Enter, through
// the page's own handlers (so it travels the UI channel). Waits up to 3 s for
// the field to have focus first; Value(key) is "focused" or "not-focused".
void SidebarTypeStep(const std::string& name, std::function<ui::MainWindow*()> w,
                     const std::string& key, const std::string& text);
// Clicks the sidebar element |css| (a fixed selector) once it is enabled.
void SidebarClickStep(const std::string& name, std::function<ui::MainWindow*()> w,
                      const std::string& key, const std::string& css);
// The same, at once (inside a step's action, for ids known only then).
void SidebarClick(ui::MainWindow* w, const std::string& key,
                  const std::string& css);
// Waits (up to 8 s) until the sidebar's DOM shows what the app last sent it
// (tab rows, address box text, "Not secure"), then checks it.
void SidebarMatchesStep(const std::string& area, const std::string& label,
                        std::function<ui::MainWindow*()> w);
// A CSS attribute selector for a sidebar row: li.tab[data-target="<id>"].
std::string RowSelector(const std::string& item_id);
bool EndsWith(const std::string& s, const std::string& suffix);
bool StartsWith(const std::string& s, const std::string& prefix);

}  // namespace birch::tests

#endif  // BIRCH_TESTS_HOOKS_HOOKS_H_
