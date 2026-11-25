// Windows: known folders, environment, Mark of the Web.
#include <windows.h>
#include <aclapi.h>
#include <knownfolders.h>
#include <sddl.h>
#include <shlobj.h>

#include <string>

#include "core/codec.h"
#include "platform/platform.h"

namespace birch::platform {

namespace {

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

std::string Narrow(const wchar_t* w, size_t len) {
  if (len == 0) {
    return std::string();
  }
  int n = WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(len), nullptr, 0,
                              nullptr, nullptr);
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(len), &out[0], n,
                      nullptr, nullptr);
  return out;
}

std::string KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  std::string out;
  if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path)) &&
      path) {
    out = Narrow(path, wcslen(path));
  }
  CoTaskMemFree(path);
  return out;
}

}  // namespace

std::string Env(const char* name) {
  std::wstring wname = Wide(name);
  DWORD n = GetEnvironmentVariableW(wname.c_str(), nullptr, 0);
  if (n == 0) {
    return std::string();
  }
  std::wstring buffer(n, L'\0');
  DWORD got = GetEnvironmentVariableW(wname.c_str(), &buffer[0], n);
  return got == 0 || got >= n ? std::string() : Narrow(buffer.c_str(), got);
}

std::string DefaultProfileDir() {
  std::string base = KnownFolder(FOLDERID_LocalAppData);
  if (base.empty()) {
    base = Env("LOCALAPPDATA");
  }
  return core::JoinPath(base, "Birch");
}

std::string DefaultDownloadsDir() {
  std::string dir = KnownFolder(FOLDERID_Downloads);
  if (dir.empty()) {
    dir = core::JoinPath(Env("USERPROFILE"), "Downloads");
  }
  return dir;
}

std::string ExecutableDir() {
  std::wstring buffer(MAX_PATH, L'\0');
  while (true) {
    DWORD n = GetModuleFileNameW(nullptr, &buffer[0],
                                 static_cast<DWORD>(buffer.size()));
    if (n == 0) {
      return std::string();
    }
    if (n < buffer.size()) {
      buffer.resize(n);
      break;
    }
    buffer.resize(buffer.size() * 2);
  }
  size_t slash = buffer.find_last_of(L"\\/");
  std::wstring dir = slash == std::wstring::npos ? buffer : buffer.substr(0, slash);
  return Narrow(dir.c_str(), dir.size());
}

std::string PrepareAppFolderForSandbox() {
  std::wstring dir = Wide(ExecutableDir());
  PSID sid = nullptr;
  if (dir.empty() || !ConvertStringSidToSidW(L"S-1-15-2-2", &sid)) {
    return "failed";
  }
  std::string result = "failed";
  PACL dacl = nullptr;
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (GetNamedSecurityInfoW(dir.c_str(), SE_FILE_OBJECT,
                            DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl,
                            nullptr, &sd) == ERROR_SUCCESS) {
    TRUSTEE_W trustee = {};
    trustee.TrusteeForm = TRUSTEE_IS_SID;
    trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
    trustee.ptstrName = static_cast<LPWSTR>(sid);
    ACCESS_MASK rights = 0;
    const ACCESS_MASK kWanted = FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
    if (dacl && GetEffectiveRightsFromAclW(dacl, &trustee, &rights) ==
                    ERROR_SUCCESS &&
        (rights & kWanted) == kWanted) {
      result = "present";
    } else {
      EXPLICIT_ACCESS_W ea = {};
      ea.grfAccessPermissions = GENERIC_READ | GENERIC_EXECUTE;
      ea.grfAccessMode = GRANT_ACCESS;
      ea.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
      ea.Trustee = trustee;
      PACL updated = nullptr;
      if (SetEntriesInAclW(1, &ea, dacl, &updated) == ERROR_SUCCESS) {
        if (SetNamedSecurityInfoW(&dir[0], SE_FILE_OBJECT,
                                  DACL_SECURITY_INFORMATION, nullptr, nullptr,
                                  updated, nullptr) == ERROR_SUCCESS) {
          result = "added";
        }
        LocalFree(updated);
      }
    }
    LocalFree(sd);
  }
  LocalFree(sid);
  return result;
}

std::string ReadDownloadMark(const std::string& path) {
  std::string data;
  if (!core::ReadFileUtf8Path(path + ":Zone.Identifier", &data)) {
    return std::string();
  }
  return data;
}

bool StripDownloadOrigin(const std::string& path) {
  // ZoneId=3 is the Internet zone, as Chromium writes for web downloads;
  // HostUrl and ReferrerUrl are left out.
  static const char kMark[] = "[ZoneTransfer]\r\nZoneId=3\r\n";
  HANDLE h = CreateFileW(Wide(path + ":Zone.Identifier").c_str(),
                         GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  BOOL ok = WriteFile(h, kMark, static_cast<DWORD>(sizeof(kMark) - 1),
                      &written, nullptr);
  CloseHandle(h);
  return ok && written == sizeof(kMark) - 1;
}

}  // namespace birch::platform
