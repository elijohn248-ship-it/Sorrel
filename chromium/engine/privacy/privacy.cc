#include "engine/privacy/privacy.h"

#include "include/cef_preference.h"
#include "include/cef_values.h"
#include "platform/platform.h"

namespace birch::engine::privacy {

namespace {

// Switches that turn off (part of) Chromium's sandbox. Birch never runs
// without it; CI checks every process.
const char* const kSandboxDisabling[] = {
    "no-sandbox",          "disable-gpu-sandbox", "disable-setuid-sandbox",
    "no-zygote-sandbox",   "disable-seccomp-filter-sandbox",
    "disable-namespace-sandbox", "single-process", "in-process-gpu",
};

// Remote DevTools would expose every page, Birch's UI pages included
// (CLAUDE.md ▸ Chromium edition ▸ UI host). Tests use in-process DevTools.
const char* const kRemoteDebugging[] = {
    "remote-debugging-port", "remote-debugging-pipe",
    "remote-debugging-address", "remote-allow-origins",
};

const char* const kPrivacySwitches[] = {
    "disable-background-networking",         // variations, network time, …
    "disable-component-update",              // CRLSet, CT lists, CDMs, …
    "disable-default-apps",
    "disable-sync",
    "disable-domain-reliability",
    "disable-client-side-phishing-detection",
    "disable-breakpad",                      // no crash reports
    "no-pings",                              // <a ping>
    "no-first-run",
    "no-default-browser-check",
    "disable-spell-checking",                // no dictionary downloads
};

// Chromium features that reach Google or other servers in the background.
// Unknown names are ignored by Chromium, so the list is safe across versions.
const char kDisabledFeatures[] =
    "OptimizationHints,OptimizationHintsFetching,"
    "OptimizationGuideModelDownloading,OptimizationTargetPrediction,"
    "MediaRouter,DialMediaRouteProvider,CastMediaRouteProvider,Translate,"
    "AutofillServerCommunication,CertificateTransparencyComponentUpdater,"
    "NetworkTimeServiceQuerying,InterestFeedContentSuggestions,DnsOverHttps,"
    "UseDnsHttpsSvcb,SafeBrowsingEnhancedProtection,ComponentUpdaterTimeouts,"
    "PrivacySandboxSettings4,PrivacySandboxAdsAPIsOverride,FedCm,"
    // "AI Mode" eligibility check (www.google.com/async/folae).
    "AimEnabled,AimServerEligibilityEnabled,AimServerRequestOnStartupEnabled,"
    "AimUrlNavigationFetchEnabled";

#if defined(_WIN32)
// Chromium 158 leaves the network service unsandboxed on Windows by default;
// Birch turns its LPAC sandbox on (the build grants the app folder to
// restricted app packages, as CEF's CMake does).
const char kEnabledFeatures[] = "NetworkServiceSandbox";
#endif

void MergeList(CefRefPtr<CefCommandLine> cl, const char* name,
               const std::string& ours) {
  std::string merged = ours;
  std::string existing = cl->GetSwitchValue(name).ToString();
  if (!existing.empty()) {
    merged = existing + "," + ours;
    cl->RemoveSwitch(name);
  }
  cl->AppendSwitchWithValue(name, merged);
}

CefRefPtr<CefValue> Bool(bool b) {
  CefRefPtr<CefValue> v = CefValue::Create();
  v->SetBool(b);
  return v;
}
CefRefPtr<CefValue> Int(int i) {
  CefRefPtr<CefValue> v = CefValue::Create();
  v->SetInt(i);
  return v;
}
CefRefPtr<CefValue> Str(const std::string& s) {
  CefRefPtr<CefValue> v = CefValue::Create();
  v->SetString(s);
  return v;
}

void Set(CefRefPtr<CefPreferenceManager> m, const char* label,
         const char* name, CefRefPtr<CefValue> value) {
  CefString error;
  bool ok = m->SetPreference(name, value, error);
  platform::Log(std::string("privacy: pref ") + label + " " + name + " -> " +
                (ok ? "set" : "not set (" + error.ToString() + ")"));
}

}  // namespace

bool IsSandboxDisablingSwitch(const std::string& name) {
  for (const char* s : kSandboxDisabling) {
    if (name == s) {
      return true;
    }
  }
  return false;
}

void ApplySwitches(CefRefPtr<CefCommandLine> cl) {
  for (const char* bad : kSandboxDisabling) {
    if (cl->HasSwitch(bad)) {
      cl->RemoveSwitch(bad);
      platform::Log(std::string("sandbox: removed forbidden switch --") + bad);
    }
  }
  for (const char* dev : kRemoteDebugging) {
    if (cl->HasSwitch(dev)) {
      cl->RemoveSwitch(dev);
      platform::Log(std::string("devtools: removed switch --") + dev);
    }
  }
  for (const char* sw : kPrivacySwitches) {
    cl->AppendSwitch(sw);
  }
  MergeList(cl, "disable-features", kDisabledFeatures);
#if defined(_WIN32)
  MergeList(cl, "enable-features", kEnabledFeatures);
#endif
  // Proxies: Birch follows the operating system's proxy settings, as Chrome
  // and Edge do, including Windows' "Automatically detect settings" (WPAD:
  // one DNS lookup of "wpad" on the local network). Owner decision
  // 2026-11-24; never add --no-proxy-server here.
}

void ApplyProfilePrefs(CefRefPtr<CefRequestContext> context,
                       const char* label) {
  if (!context) {
    return;
  }
  Set(context, label, "net.network_prediction_options", Int(2));  // no prefetch
  Set(context, label, "safebrowsing.enabled", Bool(false));
  Set(context, label, "search.suggest_enabled", Bool(false));
  Set(context, label, "alternate_error_pages.enabled", Bool(false));
  Set(context, label, "browser.enable_spellchecking", Bool(false));
  Set(context, label, "spellcheck.use_spelling_service", Bool(false));
  Set(context, label, "translate.enabled", Bool(false));
  Set(context, label, "url_keyed_anonymized_data_collection.enabled",
      Bool(false));
  Set(context, label, "credentials_enable_service", Bool(false));
  Set(context, label, "omnibox.ai_mode_settings", Int(1));
}

void ApplyLocalStatePrefs() {
  CefRefPtr<CefPreferenceManager> local =
      CefPreferenceManager::GetGlobalPreferenceManager();
  Set(local, "local-state", "dns_over_https.mode", Str("off"));
  Set(local, "local-state", "user_experience_metrics.reporting_enabled",
      Bool(false));
  Set(local, "local-state", "component_updates.component_updates_enabled",
      Bool(false));
}

}  // namespace birch::engine::privacy
