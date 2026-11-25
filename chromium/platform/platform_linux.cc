// Linux: XDG folders, environment, download origin attributes.
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <string>
#include <vector>

#include "core/codec.h"
#include "platform/platform.h"

namespace birch::platform {

namespace {

std::string Home() {
  std::string home = Env("HOME");
  return home.empty() ? std::string("/tmp") : home;
}

// XDG_DOWNLOAD_DIR from ~/.config/user-dirs.dirs, e.g.
// XDG_DOWNLOAD_DIR="$HOME/Downloads".
std::string XdgDownloadDir() {
  std::string config = Env("XDG_CONFIG_HOME");
  if (config.empty()) {
    config = core::JoinPath(Home(), ".config");
  }
  std::string text;
  if (!core::ReadFileUtf8Path(core::JoinPath(config, "user-dirs.dirs"), &text)) {
    return std::string();
  }
  for (const std::string& raw : core::Split(text, '\n')) {
    std::string line = core::TrimSpaces(raw);
    const std::string key = "XDG_DOWNLOAD_DIR=";
    if (!core::StartsWith(line, key)) {
      continue;
    }
    std::string value = line.substr(key.size());
    if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
      value = value.substr(1, value.size() - 2);
    }
    if (core::StartsWith(value, "$HOME")) {
      value = Home() + value.substr(5);
    }
    // Only absolute paths count; "$HOME/" alone means "not set".
    if (value.empty() || value[0] != '/' || value == Home() + "/") {
      return std::string();
    }
    return value;
  }
  return std::string();
}

std::string GetAttr(const std::string& path, const char* name) {
  ssize_t n = getxattr(path.c_str(), name, nullptr, 0);
  if (n <= 0) {
    return std::string();
  }
  std::vector<char> buf(static_cast<size_t>(n));
  n = getxattr(path.c_str(), name, buf.data(), buf.size());
  return n > 0 ? std::string(buf.data(), static_cast<size_t>(n)) : std::string();
}

}  // namespace

std::string Env(const char* name) {
  const char* v = std::getenv(name);
  return v ? std::string(v) : std::string();
}

std::string DefaultProfileDir() {
  std::string data = Env("XDG_DATA_HOME");
  if (data.empty() || data[0] != '/') {
    data = core::JoinPath(Home(), ".local/share");
  }
  return core::JoinPath(data, "birch");
}

std::string DefaultDownloadsDir() {
  std::string dir = XdgDownloadDir();
  return dir.empty() ? core::JoinPath(Home(), "Downloads") : dir;
}

std::string ExecutableDir() {
  std::vector<char> buf(4096);
  ssize_t n = readlink("/proc/self/exe", buf.data(), buf.size() - 1);
  if (n <= 0) {
    return std::string();
  }
  std::string exe(buf.data(), static_cast<size_t>(n));
  size_t slash = exe.rfind('/');
  return slash == std::string::npos ? exe : exe.substr(0, slash);
}

std::string ReadDownloadMark(const std::string& path) {
  std::string origin = GetAttr(path, "user.xdg.origin.url");
  std::string referrer = GetAttr(path, "user.xdg.referrer.url");
  if (origin.empty() && referrer.empty()) {
    return std::string();
  }
  return "origin=" + origin + " referrer=" + referrer;
}

std::string PrepareAppFolderForSandbox() {
  return "n/a";
}

bool StripDownloadOrigin(const std::string& path) {
  bool ok = true;
  for (const char* name : {"user.xdg.origin.url", "user.xdg.referrer.url"}) {
    if (removexattr(path.c_str(), name) != 0 && errno != ENODATA &&
        errno != ENOTSUP) {
      ok = false;
    }
  }
  return ok;
}

}  // namespace birch::platform
