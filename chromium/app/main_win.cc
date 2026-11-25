// Windows entry point. birch.exe is CEF's prebuilt bootstrap executable
// (bootstrap.exe, renamed, with Birch's icon); it loads birch.dll and calls
// RunWinMain with the sandbox information the Chromium sandbox needs since
// M138. Every process type (browser, renderer, GPU, …) starts here. Birch
// refuses to run without the sandbox.
#include <windows.h>

#include "include/cef_sandbox_win.h"
#include "include/cef_version_info.h"

#include "app/shell.h"
#include "engine/engine.h"
#include "platform/platform.h"

namespace {

int Run(void* sandbox_info) {
  CefMainArgs main_args(GetModuleHandle(nullptr));
  birch::engine::AppCallbacks callbacks;
  callbacks.on_ready = [] { birch::app::Shell::Get().OnEngineReady(); };
  callbacks.on_relaunch = [] { birch::app::Shell::Get().OnRelaunch(); };
  CefRefPtr<CefApp> app = birch::engine::CreateApp(callbacks);
  int code = CefExecuteProcess(main_args, app, sandbox_info);
  if (code >= 0) {
    return code;  // a sub-process finished
  }
  if (!sandbox_info) {
    birch::platform::Log("sandbox: bootstrap passed no sandbox info; refusing");
    return 3;
  }
  birch::platform::Log("sandbox: app folder readable by the network sandbox: " +
                       birch::platform::PrepareAppFolderForSandbox());
  std::string profile = birch::platform::ProfileDir();
  birch::app::Shell::Get().Load(profile);
  CefSettings settings;
  birch::engine::FillSettings(profile, &settings);
  if (!CefInitialize(main_args, settings, app, sandbox_info)) {
    return CefGetExitCode();
  }
  CefRunMessageLoop();
  birch::app::Shell::Get().FinalSave();
  CefShutdown();
  birch::platform::Log("app: exited");
  return 0;
}

}  // namespace

// The windowed bootstrap (bootstrap.exe) calls this one.
CEF_BOOTSTRAP_EXPORT int RunWinMain(HINSTANCE, LPTSTR, int, void* sandbox_info,
                                    cef_version_info_t*) {
  return Run(sandbox_info);
}

// The console bootstrap (bootstrapc.exe), should anyone pair it with this DLL.
CEF_BOOTSTRAP_EXPORT int RunConsoleMain(int, char*[], void* sandbox_info,
                                        cef_version_info_t*) {
  return Run(sandbox_info);
}
