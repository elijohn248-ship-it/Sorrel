// Small helpers: environment, logging, files, address display, Mark of the Web.
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "include/cef_parser.h"
#include "include/cef_task.h"

#include "birch.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#endif

namespace birch {

namespace {

class FnTask : public CefTask {
 public:
  explicit FnTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(FnTask);
};

#if defined(_WIN32)
std::wstring Wide(const std::string& s) {
  if (s.empty()) {
    return std::wstring();
  }
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
}
#endif

}  // namespace

std::string Env(const char* name) {
#if defined(_WIN32)
  // getenv is fine here (read-only, single thread at the call sites), but MSVC
  // flags it at /W4; use the wide API instead.
  wchar_t buffer[4096];
  DWORD n = GetEnvironmentVariableW(Wide(name).c_str(), buffer, 4096);
  if (n == 0 || n >= 4096) {
    return std::string();
  }
  int len = WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(n),
                                nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(n), &out[0], len,
                      nullptr, nullptr);
  return out;
#else
  const char* v = std::getenv(name);
  return v ? std::string(v) : std::string();
#endif
}

bool EnvOn(const char* name) {
  std::string v = Env(name);
  return !v.empty() && v != "0";
}

bool IsTestRun() {
  return !Env("BIRCH_HOME").empty();
}

std::string ProfileRoot() {
  std::string home = Env("BIRCH_HOME");
  if (!home.empty()) {
    return home;
  }
#if defined(_WIN32)
  return JoinPath(Env("LOCALAPPDATA"), "BirchCefPrototype");
#else
  std::string xdg = Env("XDG_DATA_HOME");
  if (xdg.empty()) {
    xdg = JoinPath(Env("HOME"), ".local/share");
  }
  return JoinPath(xdg, "birch-cef-prototype");
#endif
}

std::string JoinPath(const std::string& a, const std::string& b) {
  if (a.empty()) {
    return b;
  }
#if defined(_WIN32)
  const char sep = '\\';
#else
  const char sep = '/';
#endif
  if (a.back() == '/' || a.back() == '\\') {
    return a + b;
  }
  return a + sep + b;
}

bool MakeDirs(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  std::string partial;
  for (size_t i = 0; i < path.size(); ++i) {
    partial += path[i];
    bool last = i + 1 == path.size();
    if (path[i] == '/' || path[i] == '\\' || last) {
      if (partial.size() <= 1 || partial.back() == ':' ||
          (partial.size() == 3 && partial[1] == ':')) {
        continue;
      }
#if defined(_WIN32)
      CreateDirectoryW(Wide(partial).c_str(), nullptr);
#else
      mkdir(partial.c_str(), 0700);
#endif
    }
  }
  return true;
}

bool WriteFile(const std::string& path, const std::string& data) {
#if defined(_WIN32)
  std::ofstream out(Wide(path).c_str(), std::ios::binary | std::ios::trunc);
#else
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
#endif
  if (!out) {
    return false;
  }
  out.write(data.data(), static_cast<std::streamsize>(data.size()));
  return static_cast<bool>(out);
}

bool ReadFile(const std::string& path, std::string* data) {
#if defined(_WIN32)
  std::ifstream in(Wide(path).c_str(), std::ios::binary);
#else
  std::ifstream in(path, std::ios::binary);
#endif
  if (!in) {
    return false;
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  *data = ss.str();
  return true;
}

void Log(const std::string& line) {
  std::fprintf(stderr, "%s\n", line.c_str());
  std::fflush(stderr);
  static std::string path = Env("BIRCH_LOG");
  if (!path.empty()) {
#if defined(_WIN32)
    std::ofstream out(Wide(path).c_str(), std::ios::app | std::ios::binary);
#else
    std::ofstream out(path, std::ios::app | std::ios::binary);
#endif
    out << line << "\n";
  }
}

bool Check(const std::string& area, const std::string& what,
           const std::string& expected, const std::string& got) {
  bool ok = expected == got;
  Log(area + ": " + what + " expected=" + expected + " got=" + got + " -> " +
      (ok ? "PASS" : "FAIL"));
  return ok;
}

std::string DisplayOrigin(const std::string& url) {
  CefURLParts parts;
  if (url.empty() || !CefParseURL(url, parts)) {
    return url;
  }
  std::string scheme = CefString(&parts.scheme).ToString();
  std::string host = CefString(&parts.host).ToString();
  std::string port = CefString(&parts.port).ToString();
  if (host.empty()) {
    // about:blank, data:, chrome-extension pages without a host, ...
    return scheme + ":";
  }
  std::string out = scheme + "://" + host;
  if (!port.empty()) {
    out += ":" + port;
  }
  return out;
}

void PostUI(std::function<void()> fn, int64_t delay_ms) {
  CefRefPtr<CefTask> task = new FnTask(std::move(fn));
  if (delay_ms > 0) {
    CefPostDelayedTask(TID_UI, task, delay_ms);
  } else {
    CefPostTask(TID_UI, task);
  }
}

std::string ReadZoneIdentifier(const std::string& path) {
#if defined(_WIN32)
  std::string data;
  if (!ReadFile(path + ":Zone.Identifier", &data)) {
    return std::string();
  }
  return data;
#else
  (void)path;
  return std::string();
#endif
}

bool WriteZoneIdentifier(const std::string& path, const std::string& url) {
#if defined(_WIN32)
  // ZoneId=3 is the Internet zone, as Chromium writes for web downloads.
  std::string data = "[ZoneTransfer]\r\nZoneId=3\r\n";
  if (!url.empty()) {
    data += "HostUrl=" + url + "\r\n";
  }
  return WriteFile(path + ":Zone.Identifier", data);
#else
  (void)path;
  (void)url;
  return false;
#endif
}

}  // namespace birch
