// Linux entry point. The same executable runs every process type; Chromium's
// sandbox (user namespaces or the setuid chrome-sandbox helper, plus
// seccomp-bpf) is set up by CEF itself.
#include "birch.h"

int main(int argc, char* argv[]) {
  CefMainArgs main_args(argc, argv);
  CefRefPtr<birch::BirchApp> app(new birch::BirchApp);
  int code = CefExecuteProcess(main_args, app, nullptr);
  if (code >= 0) {
    return code;  // a sub-process finished
  }
  CefSettings settings;
  birch::FillSettings(&settings);
  if (!CefInitialize(main_args, settings, app, nullptr)) {
    return CefGetExitCode();
  }
  CefRunMessageLoop();
  CefShutdown();
  birch::Log("app: exited");
  return 0;
}
