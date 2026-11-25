// Chromium switches and preferences that keep Google's and Chromium's
// background services off, carried over from the CEF prototype
// (prototypes/cef/REPORT.md ▸ gate 5) and proven by the NetLog test
// (tests/harness/netlog_check.py). Owner: wave-3 agent 7
// (cx-privacy-extensions). Never weaken an entry to fix a bug (AGENTS.md
// 2.2 rule 1); the NetLog test must stay green.
#ifndef BIRCH_ENGINE_PRIVACY_PRIVACY_H_
#define BIRCH_ENGINE_PRIVACY_PRIVACY_H_

#include <string>

#include "include/cef_command_line.h"
#include "include/cef_request_context.h"

namespace birch::engine::privacy {

// Browser-process command line: removes every sandbox-disabling switch,
// adds the privacy switches and merges Birch's feature lists into CEF's own
// --disable-features / --enable-features values (a second switch would
// replace CEF's list and crash Chrome-style windows).
void ApplySwitches(CefRefPtr<CefCommandLine> command_line);

// Switches that would weaken Chromium's sandbox; ApplySwitches removes them.
bool IsSandboxDisablingSwitch(const std::string& name);

// Profile preferences for one request context (normal or private).
void ApplyProfilePrefs(CefRefPtr<CefRequestContext> context,
                       const char* label);
// Local State preferences (global), once after CEF starts.
void ApplyLocalStatePrefs();

}  // namespace birch::engine::privacy

#endif  // BIRCH_ENGINE_PRIVACY_PRIVACY_H_
