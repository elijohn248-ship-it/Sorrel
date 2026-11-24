// Birch CEF prototype: shared declarations. Throwaway code for the wave-1
// engine comparison (prototypes/cef/REPORT.md); not the product.
#ifndef BIRCH_CEF_BIRCH_H_
#define BIRCH_CEF_BIRCH_H_

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context_handler.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_label_button.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_textfield.h"
#include "include/views/cef_window.h"

namespace birch {

// ---- util.cc ---------------------------------------------------------------

// Value of an environment variable, or "" when unset.
std::string Env(const char* name);
bool EnvOn(const char* name);
// True when BIRCH_HOME is set: a test run with a scratch profile.
bool IsTestRun();
// Profile root (BIRCH_HOME, or a per-user default folder).
std::string ProfileRoot();
std::string JoinPath(const std::string& a, const std::string& b);
bool MakeDirs(const std::string& path);
bool WriteFile(const std::string& path, const std::string& data);
bool ReadFile(const std::string& path, std::string* data);

// One log line to stderr and to BIRCH_LOG (if set). Browser process only.
void Log(const std::string& line);
// "<area>: <what> expected=<e> got=<g> -> PASS|FAIL"
bool Check(const std::string& area, const std::string& what,
           const std::string& expected, const std::string& got);

// What Birch's address bar shows for a committed URL: the real origin, with
// the host exactly as Chromium canonicalised it (IDN stays punycode).
std::string DisplayOrigin(const std::string& url);

// Runs |fn| on the browser UI thread after |delay_ms|.
void PostUI(std::function<void()> fn, int64_t delay_ms = 0);

// Windows Mark of the Web (Zone.Identifier stream); "" elsewhere / missing.
std::string ReadZoneIdentifier(const std::string& path);
bool WriteZoneIdentifier(const std::string& path, const std::string& url);

// ---- tabs and windows --------------------------------------------------------

class BrowserWindow;

struct Tab {
  int id = 0;
  BrowserWindow* window = nullptr;  // cleared when the window goes away
  CefRefPtr<CefBrowserView> view;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> devtools_registration;
  std::string committed_url;
  bool loading = false;
  bool closed = false;          // OnBeforeClose ran
  bool closing_single = false;  // this tab alone is being closed
  int load_ends = 0;
  int last_error = 0;
  bool crashed = false;
  int cert_errors = 0;
};

enum class Style { kAlloy, kChrome };

class BirchClient;

// A top-level window. Alloy style: Birch's own toolbar (back, forward, reload,
// address field, tab buttons) above one BrowserView per tab. Chrome style: a
// single Chrome-style BrowserView with Chrome's location bar (extension
// buttons live there).
class BrowserWindow : public CefWindowDelegate,
                      public CefBrowserViewDelegate,
                      public CefButtonDelegate,
                      public CefTextfieldDelegate {
 public:
  BrowserWindow(Style style, bool is_private);

  static BrowserWindow* Open(Style style, bool is_private,
                             const std::string& url);

  std::shared_ptr<Tab> AddTab(const std::string& url);
  void SelectTab(int tab_id);
  void CloseTab(int tab_id);
  void Close();

  std::shared_ptr<Tab> active() const;
  std::shared_ptr<Tab> tab(int tab_id) const;
  size_t open_tab_count() const;
  std::string address_text() const;
  bool is_private() const { return private_; }
  bool destroyed() const { return destroyed_; }
  Style style() const { return style_; }
  CefRefPtr<CefRequestContext> context() const { return context_; }

  // From BirchClient.
  void OnTabAddressChanged(Tab* tab);
  bool OnTabDoClose(Tab* tab);
  void OnTabClosed(Tab* tab);

  // CefWindowDelegate
  void OnWindowCreated(CefRefPtr<CefWindow> window) override;
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override;
  bool CanClose(CefRefPtr<CefWindow> window) override;
  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override;
  cef_runtime_style_t GetWindowRuntimeStyle() override;
  // CefBrowserViewDelegate
  cef_runtime_style_t GetBrowserRuntimeStyle() override;
  ChromeToolbarType GetChromeToolbarType(
      CefRefPtr<CefBrowserView> browser_view) override;
  // CefButtonDelegate
  void OnButtonPressed(CefRefPtr<CefButton> button) override;
  // CefTextfieldDelegate (keep the window overload visible too)
  using CefWindowDelegate::OnKeyEvent;
  bool OnKeyEvent(CefRefPtr<CefTextfield> textfield,
                  const CefKeyEvent& event) override;

 private:
  void RefreshToolbar();

  Style style_;
  bool private_;
  bool destroyed_ = false;
  bool window_closing_ = false;
  CefRefPtr<CefRequestContext> context_;
  CefRefPtr<CefWindow> window_;
  CefRefPtr<CefPanel> tab_strip_;
  CefRefPtr<CefPanel> content_;
  CefRefPtr<CefTextfield> address_;
  CefRefPtr<CefLabelButton> back_, forward_, reload_, new_tab_;
  std::vector<std::shared_ptr<Tab>> tabs_;
  std::map<int, CefRefPtr<CefLabelButton>> tab_buttons_;
  int active_id_ = 0;
  std::string pending_url_;

  IMPLEMENT_REFCOUNTING(BrowserWindow);
};

// ---- client.cc ---------------------------------------------------------------

class BirchClient : public CefClient,
                    public CefDisplayHandler,
                    public CefLoadHandler,
                    public CefLifeSpanHandler,
                    public CefRequestHandler,
                    public CefDownloadHandler,
                    public CefPermissionHandler,
                    public CefDevToolsMessageObserver {
 public:
  explicit BirchClient(std::shared_ptr<Tab> tab);  // tab may be null

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading,
                            bool can_go_back, bool can_go_forward) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int http_status_code) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode error_code, const CefString& error_text,
                   const CefString& failed_url) override;
  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                     int popup_id, const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture, const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  // CefRequestHandler
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int error_code,
                                 const CefString& error_string) override;
  // CefDownloadHandler
  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url,
                   const CefString& request_method) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  // CefPermissionHandler
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;
  // CefDevToolsMessageObserver
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                              bool success, const void* result,
                              size_t result_size) override;

 private:
  std::shared_ptr<Tab> tab_;
  IMPLEMENT_REFCOUNTING(BirchClient);
};

// ---- app.cc --------------------------------------------------------------------

class BirchApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BirchApp() = default;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;
  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override;
  void OnContextInitialized() override;
  CefRefPtr<CefClient> GetDefaultClient() override;

 private:
  IMPLEMENT_REFCOUNTING(BirchApp);
};

// Settings shared by the entry points (main_win.cc / main_linux.cc).
void FillSettings(CefSettings* settings);

// Applies Birch's privacy preferences to a request context (UI thread).
void ApplyPrivacyPrefs(CefRefPtr<CefRequestContext> context, const char* label);
// Serves birch:// pages (only Birch's own error page in the prototype).
void RegisterBirchScheme(CefRefPtr<CefRequestContext> context);

// ---- global state ------------------------------------------------------------

struct State {
  std::vector<CefRefPtr<BrowserWindow>> windows;
  int live_browsers = 0;
  bool quitting = false;
  int next_tab_id = 1;
  // DevTools evaluation results by key, and pending message ids.
  std::map<std::string, std::string> results;
  std::map<int, std::string> pending;
  int next_message_id = 1000;
  // Counters the tests read.
  int media_prompts = 0, camera_prompts = 0, mic_prompts = 0;
  int geo_prompts = 0, notification_prompts = 0, other_prompts = 0;
  int downloads_done = 0;
  int popups_blocked = 0;
  std::vector<std::string> download_paths;
  // Browsers Chromium created itself (default client); closed at shutdown.
  std::vector<CefRefPtr<CefBrowser>> orphans;
};
State& state();

// Starts BIRCH_TEST scenarios (or just opens BIRCH_OPEN).
void StartTests();
// Closes every window and quits once all browsers are gone.
void Shutdown(const std::string& why);
void MaybeQuit();

// Evaluates a fixed expression in |tab| through the DevTools protocol (no page
// bridge). The JSON-encoded result lands in state().results[key].
void Evaluate(const std::shared_ptr<Tab>& tab, const std::string& key,
              const std::string& expression, bool user_gesture);
void DevTools(const std::shared_ptr<Tab>& tab, const std::string& key,
              const std::string& method, CefRefPtr<CefDictionaryValue> params);

}  // namespace birch

#endif  // BIRCH_CEF_BIRCH_H_
