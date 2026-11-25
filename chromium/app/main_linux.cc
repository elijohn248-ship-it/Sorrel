// Linux entry point. The same executable runs every process type; Chromium's
// sandbox (user namespaces or the setuid chrome-sandbox helper, plus
// seccomp-bpf) is set up by CEF itself, and Birch never switches it off.
#include "app/shell.h"
#include "engine/engine.h"
#include "platform/platform.h"

int main(int argc, char* argv[]) {
  CefMainArgs main_args(argc, argv);
  birch::engine::AppCallbacks callbacks;
  callbacks.on_ready = [] { birch::app::Shell::Get().OnEngineReady(); };
  callbacks.on_relaunch = [] { birch::app::Shell::Get().OnRelaunch(); };
  CefRefPtr<CefApp> app = birch::engine::CreateApp(callbacks);
  int code = CefExecuteProcess(main_args, app, nullptr);
  if (code >= 0) {
    return code;  // a sub-process finished
  }
  std::string profile = birch::platform::ProfileDir();
  birch::app::Shell::Get().Load(profile);
  CefSettings settings;
  birch::engine::FillSettings(profile, &settings);
  if (!CefInitialize(main_args, settings, app, nullptr)) {
    return CefGetExitCode();
  }
  CefRunMessageLoop();
  birch::app::Shell::Get().FinalSave();
  CefShutdown();
  birch::platform::Log("app: exited");
  return 0;
}
