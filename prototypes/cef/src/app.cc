// Browser-process setup: CEF settings, privacy switches and preferences,
// Birch's own birch:// scheme, and the default client.
#include <cctype>

#include "include/cef_parser.h"
#include "include/cef_preference.h"
#include "include/cef_scheme.h"
#include "include/wrapper/cef_stream_resource_handler.h"

#include "birch.h"

namespace birch {

namespace {

bool PrivacyOff() {
  // Test-only baseline: shows what stock CEF contacts. Ignored outside tests.
  return IsTestRun() && Env("BIRCH_PRIVACY") == "off";
}

// Chromium features that reach Google or other servers in the background.
// Unknown names are ignored by Chromium, so the list is safe across versions.
const char kDisabledFeatures[] =
    "OptimizationHints,OptimizationHintsFetching,OptimizationGuideModelDownloading,"
    "OptimizationTargetPrediction,MediaRouter,DialMediaRouteProvider,"
    "CastMediaRouteProvider,Translate,AutofillServerCommunication,"
    "CertificateTransparencyComponentUpdater,NetworkTimeServiceQuerying,"
    "InterestFeedContentSuggestions,DnsOverHttps,UseDnsHttpsSvcb,"
    "SafeBrowsingEnhancedProtection,ComponentUpdaterTimeouts,"
    "PrivacySandboxSettings4,PrivacySandboxAdsAPIsOverride,"
    "FedCm,BackForwardCacheMemoryControls";

void SetPref(CefRefPtr<CefPreferenceManager> manager, const char* label,
             const std::string& name, CefRefPtr<CefValue> value) {
  CefString error;
  bool ok = manager->SetPreference(name, value, error);
  Log(std::string("privacy: pref ") + label + " " + name + " -> " +
      (ok ? "set" : "not set (" + error.ToString() + ")"));
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

std::string QueryValue(const std::string& query, const std::string& key) {
  size_t pos = 0;
  while (pos <= query.size()) {
    size_t end = query.find('&', pos);
    if (end == std::string::npos) {
      end = query.size();
    }
    std::string pair = query.substr(pos, end - pos);
    if (pair.rfind(key + "=", 0) == 0) {
      return pair.substr(key.size() + 1);
    }
    pos = end + 1;
  }
  return std::string();
}

// Only [a-z0-9-] survives, so nothing from the failed page reaches the HTML.
std::string Sanitize(const std::string& in) {
  std::string out;
  for (char c : in) {
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
      out += c;
    }
  }
  return out.substr(0, 32);
}

class BirchSchemeFactory : public CefSchemeHandlerFactory {
 public:
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser>,
                                       CefRefPtr<CefFrame>,
                                       const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    CefURLParts parts;
    CefParseURL(request->GetURL(), parts);
    std::string host = CefString(&parts.host).ToString();
    std::string query = CefString(&parts.query).ToString();
    std::string html;
    if (host == "error") {
      std::string reason = Sanitize(QueryValue(query, "reason"));
      std::string code = Sanitize(QueryValue(query, "code"));
      html =
          "<!doctype html><meta charset=utf-8><title>Can't open this "
          "page</title><body data-birch-error='" +
          reason + "' data-code='" + code +
          "' style='font:16px system-ui;margin:3em'><h1>Birch can't open "
          "this page</h1><p>Reason: " +
          reason + " " + code + "</p>";
    } else if (host == "blank") {
      html = "<!doctype html><title>New Tab</title><body>";
    } else {
      html = "<!doctype html><title>Not found</title><body>Not found";
    }
    auto* bytes = new std::string(html);
    // The stream reader copies nothing, so keep the bytes alive with the
    // handler: CreateForData does not take ownership, hence a leak-free copy.
    CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForData(
        static_cast<void*>(const_cast<char*>(bytes->data())), bytes->size());
    keep_.emplace_back(bytes);
    return new CefStreamResourceHandler("text/html", stream);
  }

 private:
  std::vector<std::unique_ptr<std::string>> keep_;
  IMPLEMENT_REFCOUNTING(BirchSchemeFactory);
};

CefRefPtr<BirchClient>& DefaultClient() {
  static CefRefPtr<BirchClient> client;
  return client;
}

}  // namespace

void FillSettings(CefSettings* settings) {
  std::string root = ProfileRoot();
  MakeDirs(root);
  CefString(&settings->root_cache_path) = root;
  // Test runs keep site data in memory unless a test needs the on-disk
  // profile (BIRCH_PERSIST=1, e.g. to prove private data stays off disk while
  // normal data is written). Everything stays inside BIRCH_HOME either way.
  bool persist = !IsTestRun() || EnvOn("BIRCH_PERSIST");
  if (persist) {
    CefString(&settings->cache_path) = JoinPath(root, "Default");
  }
  settings->persist_session_cookies = false;
  settings->no_sandbox = false;  // never disabled
  std::string cef_log = IsTestRun() ? Env("BIRCH_CEF_LOG") : std::string();
  if (!cef_log.empty()) {
    CefString(&settings->log_file) = cef_log;
    settings->log_severity = LOGSEVERITY_WARNING;
  } else {
    settings->log_severity = LOGSEVERITY_DISABLE;
  }
}

void BirchApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  if (!process_type.empty()) {
    return;
  }
  // Guard: the sandbox is never switched off, whatever the caller passed.
  for (const char* bad : {"no-sandbox", "disable-gpu-sandbox",
                          "disable-setuid-sandbox", "no-zygote-sandbox"}) {
    if (command_line->HasSwitch(bad)) {
      command_line->RemoveSwitch(bad);
      Log(std::string("sandbox: removed forbidden switch --") + bad);
    }
  }

  if (!PrivacyOff()) {
    for (const char* sw :
         {"disable-background-networking", "disable-component-update",
          "disable-default-apps", "disable-sync", "disable-domain-reliability",
          "disable-client-side-phishing-detection", "disable-breakpad",
          "no-pings", "no-first-run", "no-default-browser-check",
          "disable-spell-checking"}) {
      command_line->AppendSwitch(sw);
    }
    command_line->AppendSwitchWithValue("disable-features", kDisabledFeatures);
  }

  if (!IsTestRun()) {
    return;
  }
  // ---- test-only switches (BIRCH_HOME set) ----
  std::string rules = "MAP *.birch.test 127.0.0.1";
  std::string extra = Env("BIRCH_HOSTMAP");
  size_t pos = 0;
  while (!extra.empty() && pos <= extra.size()) {
    size_t end = extra.find(',', pos);
    if (end == std::string::npos) {
      end = extra.size();
    }
    std::string host = extra.substr(pos, end - pos);
    if (!host.empty()) {
      rules += ",MAP " + host + " 127.0.0.1";
    }
    pos = end + 1;
  }
  if (EnvOn("BIRCH_SEAL")) {
    rules += ",EXCLUDE 127.0.0.1,EXCLUDE localhost,MAP * ~NOTFOUND";
  }
  command_line->AppendSwitchWithValue("host-resolver-rules", rules);

  std::string netlog = Env("BIRCH_NETLOG");
  if (!netlog.empty()) {
    command_line->AppendSwitchWithValue("log-net-log", netlog);
    command_line->AppendSwitchWithValue("net-log-capture-mode", "Default");
  }
  std::string extensions = Env("BIRCH_EXTENSIONS");
  if (!extensions.empty()) {
    command_line->AppendSwitchWithValue("load-extension", extensions);
  }
  if (EnvOn("BIRCH_FAKE_MEDIA")) {
    // Fake capture devices so getUserMedia reaches the permission step on a
    // machine without a camera. This does NOT grant anything (that would be
    // --use-fake-ui-for-media-stream, which Birch never uses).
    command_line->AppendSwitch("use-fake-device-for-media-stream");
  }
  Log("app: command line " + command_line->GetCommandLineString().ToString());
}

void BirchApp::OnRegisterCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  // Display-isolated: web pages cannot link to, frame or fetch birch:// pages.
  registrar->AddCustomScheme("birch", CEF_SCHEME_OPTION_STANDARD |
                                          CEF_SCHEME_OPTION_SECURE |
                                          CEF_SCHEME_OPTION_DISPLAY_ISOLATED);
}

void ApplyPrivacyPrefs(CefRefPtr<CefRequestContext> context,
                       const char* label) {
  if (PrivacyOff() || !context) {
    return;
  }
  SetPref(context, label, "net.network_prediction_options", Int(2));
  SetPref(context, label, "safebrowsing.enabled", Bool(false));
  SetPref(context, label, "search.suggest_enabled", Bool(false));
  SetPref(context, label, "alternate_error_pages.enabled", Bool(false));
  SetPref(context, label, "browser.enable_spellchecking", Bool(false));
  SetPref(context, label, "spellcheck.use_spelling_service", Bool(false));
  SetPref(context, label, "translate.enabled", Bool(false));
  SetPref(context, label, "url_keyed_anonymized_data_collection.enabled",
          Bool(false));
  SetPref(context, label, "credentials_enable_service", Bool(false));
  SetPref(context, label, "enable_a_ping", Bool(false));
  SetPref(context, label, "domain_reliability.allowed_by_policy", Bool(false));
}

void RegisterBirchScheme(CefRefPtr<CefRequestContext> context) {
  static CefRefPtr<CefSchemeHandlerFactory> factory = new BirchSchemeFactory();
  if (context) {
    context->RegisterSchemeHandlerFactory("birch", "", factory);
  } else {
    CefRegisterSchemeHandlerFactory("birch", "", factory);
  }
}

void BirchApp::OnContextInitialized() {
  RegisterBirchScheme(nullptr);
  ApplyPrivacyPrefs(CefRequestContext::GetGlobalContext(), "profile");
  if (!PrivacyOff()) {
    CefRefPtr<CefPreferenceManager> local =
        CefPreferenceManager::GetGlobalPreferenceManager();
    SetPref(local, "local-state", "dns_over_https.mode", Str("off"));
    SetPref(local, "local-state", "user_experience_metrics.reporting_enabled",
            Bool(false));
    SetPref(local, "local-state",
            "component_updates.component_updates_enabled", Bool(false));
  }
  StartTests();
}

CefRefPtr<CefClient> BirchApp::GetDefaultClient() {
  // Used for browsers Chromium creates on its own (e.g. a tab an extension
  // opens in a Chrome-style window). Tracked so shutdown waits for them.
  if (!DefaultClient()) {
    DefaultClient() = new BirchClient(nullptr);
  }
  return DefaultClient();
}

}  // namespace birch
