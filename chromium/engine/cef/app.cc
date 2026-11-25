// The CefApp shared by every process, CEF settings, and test-only switches.
#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"

#include "core/codec.h"
#include "engine/cef/internal.h"
#include "engine/engine.h"
#include "engine/privacy/privacy.h"
#include "platform/platform.h"

namespace birch::engine {

namespace {

class BirchApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit BirchApp(AppCallbacks callbacks)
      : callbacks_(std::move(callbacks)),
        renderer_(CreateRenderProcessHandler()) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  // Renderer processes: the UI channel's JS side (UI pages only).
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return renderer_;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;  // sub-processes get their switches from the browser process
    }
    privacy::ApplySwitches(command_line);
    if (platform::IsTestRun()) {
      AddTestSwitches(command_line);
    }
  }

  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    RegisterBirchSchemeName(registrar);
    RegisterUiSchemeName(registrar);
  }

  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override {
    if (platform::IsTestRun() && platform::Env("BIRCH_TEST") == "channel") {
      command_line->AppendSwitch(kForgeSwitch);
    }
  }

  void OnContextInitialized() override {
    RegisterBirchSchemeHandler(nullptr);
    privacy::ApplyProfilePrefs(CefRequestContext::GetGlobalContext(),
                               "profile");
    privacy::ApplyLocalStatePrefs();
    if (callbacks_.on_ready) {
      callbacks_.on_ready();
    }
  }

  bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine>,
                                   const CefString&) override {
    if (callbacks_.on_relaunch) {
      callbacks_.on_relaunch();
    }
    return true;  // handled: no second browser process
  }

 private:
  // BIRCH_HOME is set: local fixtures only, NetLog, fake capture devices.
  static void AddTestSwitches(CefRefPtr<CefCommandLine> cl) {
    std::string rules = "MAP *.birch.test 127.0.0.1";
    std::string extra = platform::Env("BIRCH_HOSTMAP");
    for (const std::string& host : core::Split(extra, ',')) {
      if (!host.empty()) {
        rules += ",MAP " + host + " 127.0.0.1";
      }
    }
    cl->AppendSwitchWithValue("host-resolver-rules", rules);
    std::string netlog = platform::Env("BIRCH_NETLOG");
    if (!netlog.empty()) {
      cl->AppendSwitchWithValue("log-net-log", netlog);
      cl->AppendSwitchWithValue("net-log-capture-mode", "Default");
    }
    if (platform::EnvOn("BIRCH_FAKE_MEDIA")) {
      // Fake capture devices so getUserMedia reaches the permission step on
      // a machine without a camera. This grants nothing (that would be
      // --use-fake-ui-for-media-stream, which Birch never uses).
      cl->AppendSwitch("use-fake-device-for-media-stream");
    }
    platform::Log("app: command line " +
                  cl->GetCommandLineString().ToString());
  }

  AppCallbacks callbacks_;
  CefRefPtr<CefRenderProcessHandler> renderer_;
  IMPLEMENT_REFCOUNTING(BirchApp);
};

}  // namespace

CefRefPtr<CefApp> CreateApp(AppCallbacks callbacks) {
  return new BirchApp(std::move(callbacks));
}

void FillSettings(const std::string& profile_dir, CefSettings* settings) {
  std::string root = core::JoinPath(profile_dir, "Chromium");
  core::MakeDirectories(root);
  CefString(&settings->root_cache_path) = root;
  // Test runs keep site data in memory unless a test needs the on-disk
  // profile as a positive control (BIRCH_PERSIST=1). Everything stays inside
  // BIRCH_HOME either way.
  bool persist = !platform::IsTestRun() || platform::EnvOn("BIRCH_PERSIST");
  if (persist) {
    CefString(&settings->cache_path) = core::JoinPath(root, "Default");
  }
  settings->persist_session_cookies = false;
  settings->no_sandbox = false;  // never disabled
  std::string cef_log =
      platform::IsTestRun() ? platform::Env("BIRCH_CEF_LOG") : std::string();
  if (!cef_log.empty()) {
    CefString(&settings->log_file) = cef_log;
    settings->log_severity = LOGSEVERITY_WARNING;
  } else {
    settings->log_severity = LOGSEVERITY_DISABLE;
  }
}

}  // namespace birch::engine
