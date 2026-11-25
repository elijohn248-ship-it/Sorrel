// Operating-system services for the Chromium edition: environment, profile
// and Downloads folders, test logging, and download marks. Windows code is in
// platform_win.cc, Linux in platform_linux.cc, shared code in platform.cc.
// No CEF here. Owner: shared (CLAUDE.md ▸ Chromium edition ▸ module map);
// wave-3 agent 8 adds file pickers and "show in folder".
#ifndef BIRCH_PLATFORM_PLATFORM_H_
#define BIRCH_PLATFORM_PLATFORM_H_

#include <string>

namespace birch::platform {

// Value of an environment variable (UTF-8), or "" when unset.
std::string Env(const char* name);
// Set and not "0".
bool EnvOn(const char* name);

// True when BIRCH_HOME is set: a test run with a scratch profile. Test hooks
// (BIRCH_*) are honoured only then, and site data stays in memory.
bool IsTestRun();

// Where Birch keeps its profile without BIRCH_HOME:
// %LOCALAPPDATA%\Birch on Windows, $XDG_DATA_HOME/birch (normally
// ~/.local/share/birch) on Linux.
std::string DefaultProfileDir();
// BIRCH_HOME when set, else DefaultProfileDir().
std::string ProfileDir();

// The person's Downloads folder (Windows known folder; Linux XDG user dir,
// else ~/Downloads).
std::string DefaultDownloadsDir();
// Test runs: BIRCH_DOWNLOADS, else <BIRCH_HOME>/Downloads (never the real
// folder). Otherwise DefaultDownloadsDir().
std::string DownloadsDir();

// The folder holding the executable (resources such as birch.png live there).
std::string ExecutableDir();

// Test logging: one line to stderr and to BIRCH_LOG. Does nothing outside
// test runs, so a normal Birch never writes addresses to a log.
void Log(const std::string& line);
// "<area>: <what> expected=<e> got=<g> -> PASS|FAIL"; returns the result.
bool Check(const std::string& area, const std::string& what,
           const std::string& expected, const std::string& got);

// Download marks. Windows: the Zone.Identifier stream ("Mark of the Web");
// Linux: the user.xdg.origin.url / user.xdg.referrer.url attributes.
// Returns the mark as text ("" when there is none).
std::string ReadDownloadMark(const std::string& path);
// For a private window's download: keeps "came from the Internet" (ZoneId=3
// on Windows) but removes the source and referrer addresses, so nothing on
// disk says where a private download came from. Returns true on success.
bool StripDownloadOrigin(const std::string& path);

// Windows: Chromium's network-service sandbox (an LPAC app container) must be
// able to read Birch's program folder. Chrome's installer grants "ALL
// RESTRICTED APPLICATION PACKAGES" read/execute on it; a zip loses that, so
// the browser process adds the grant to its own folder when it is missing.
// Linux: nothing to do. Returns "present", "added", "failed" or "n/a".
std::string PrepareAppFolderForSandbox();

// A free file name in |dir| for |name| ("a.pdf", "a (1).pdf", …).
std::string UniqueFilePath(const std::string& dir, const std::string& name);

}  // namespace birch::platform

#endif  // BIRCH_PLATFORM_PLATFORM_H_
