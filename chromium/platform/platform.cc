// Platform code shared by Windows and Linux.
#include <cstdio>
#include <mutex>

#include "core/codec.h"
#include "platform/platform.h"

namespace birch::platform {

bool EnvOn(const char* name) {
  std::string v = Env(name);
  return !v.empty() && v != "0";
}

bool IsTestRun() {
  return !Env("BIRCH_HOME").empty();
}

std::string ProfileDir() {
  std::string home = Env("BIRCH_HOME");
  return home.empty() ? DefaultProfileDir() : home;
}

std::string DownloadsDir() {
  if (IsTestRun()) {
    std::string dir = Env("BIRCH_DOWNLOADS");
    return dir.empty() ? core::JoinPath(Env("BIRCH_HOME"), "Downloads") : dir;
  }
  return DefaultDownloadsDir();
}

void Log(const std::string& line) {
  if (!IsTestRun()) {
    return;
  }
  static std::mutex mu;
  std::lock_guard<std::mutex> lock(mu);
  std::fprintf(stderr, "%s\n", line.c_str());
  std::fflush(stderr);
  static const std::string path = Env("BIRCH_LOG");
  if (!path.empty()) {
    core::AppendFileUtf8Path(path, line + "\n");
  }
}

bool Check(const std::string& area, const std::string& what,
           const std::string& expected, const std::string& got) {
  bool ok = expected == got;
  Log(area + ": " + what + " expected=" + expected + " got=" + got + " -> " +
      (ok ? "PASS" : "FAIL"));
  return ok;
}

std::string UniqueFilePath(const std::string& dir, const std::string& name) {
  std::string base = name, ext;
  size_t dot = name.rfind('.');
  if (dot != std::string::npos && dot > 0) {
    base = name.substr(0, dot);
    ext = name.substr(dot);
  }
  std::string path = core::JoinPath(dir, name);
  for (int i = 1; core::FileExists(path) && i < 10000; ++i) {
    path = core::JoinPath(dir, base + " (" + std::to_string(i) + ")" + ext);
  }
  return path;
}

}  // namespace birch::platform
