// Windows entry point. birch_cef.exe is CEF's prebuilt console bootstrap
// (bootstrapc.exe, renamed); it loads birch_cef.dll and calls RunConsoleMain
// with the sandbox information, which is required for the Chromium sandbox
// since M138. Every process type (browser, renderer, GPU, ...) starts here.
#include <windows.h>

#include "include/cef_sandbox_win.h"
#include "include/cef_version_info.h"

#include "birch.h"

namespace {

int Run(void* sandbox_info) {
  CefMainArgs main_args(GetModuleHandle(nullptr));
  CefRefPtr<birch::BirchApp> app(new birch::BirchApp);
  int code = CefExecuteProcess(main_args, app, sandbox_info);
  if (code >= 0) {
    return code;  // a sub-process finished
  }
  if (!sandbox_info) {
    // Birch never runs without the Chromium sandbox.
    birch::Log("sandbox: bootstrap passed no sandbox info; refusing to start");
    return 3;
  }
  CefSettings settings;
  birch::FillSettings(&settings);
  if (!CefInitialize(main_args, settings, app, sandbox_info)) {
    return CefGetExitCode();
  }
  CefRunMessageLoop();
  CefShutdown();
  birch::Log("app: exited");
  return 0;
}

}  // namespace

CEF_BOOTSTRAP_EXPORT int RunConsoleMain(int, char*[], void* sandbox_info,
                                        cef_version_info_t*) {
  return Run(sandbox_info);
}
