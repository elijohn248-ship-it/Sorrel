// The engine boundary. engine/ is the only code that touches CEF's browser
// API (CefBrowser, CefClient handlers, request contexts, schemes, switches,
// preferences). ui/ hosts a page through Page::view(), a CEF Views object
// (CEF Views is ui/'s widget toolkit), and hears about the page only through
// PageObserver. Nothing here gives a web page a channel into the app
// (AGENTS.md rule 4): there is no message router, no JS binding and no
// script message handler. The one approved exception, for Birch's own UI
// pages only, is engine/ui_page.h.
//
// Owners (CLAUDE.md ▸ Chromium edition ▸ module map): engine/cef/ shared
// (wave-2 shell; coordinate changes), engine/privacy/ and engine/extensions/
// wave-3 agent 7, engine/cef/downloads.* agent 8.
#ifndef BIRCH_ENGINE_ENGINE_H_
#define BIRCH_ENGINE_ENGINE_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "include/cef_app.h"
#include "include/cef_values.h"
#include "include/views/cef_view.h"

namespace birch::engine {

// ---- startup -----------------------------------------------------------------

struct AppCallbacks {
  // CEF is ready (UI thread): create windows.
  std::function<void()> on_ready;
  // Someone started Birch again with the same profile: show a window.
  std::function<void()> on_relaunch;
};
// The CefApp for every process (browser, renderer, GPU, …). Strips any
// sandbox-disabling switch, applies Birch's privacy switches and registers
// the birch:// scheme.
CefRefPtr<CefApp> CreateApp(AppCallbacks callbacks);
// CEF settings for the browser process: Chromium's data under
// <profile_dir>/Chromium (in memory for test runs), sandbox on, logging off.
void FillSettings(const std::string& profile_dir, CefSettings* settings);

// Browsers still alive (pages not yet torn down), for shutdown.
int LiveBrowserCount();
// Called (UI thread) each time a browser finishes closing.
void SetBrowserClosedListener(std::function<void()> listener);

// ---- storage profiles ------------------------------------------------------------

class Profile {
 public:
  // The normal profile: Chromium's global request context. On disk under the
  // profile folder; in memory in test runs (BIRCH_HOME) unless BIRCH_PERSIST.
  static std::shared_ptr<Profile> Normal();
  // A private profile: Chromium's off-the-record storage (empty cache path).
  // Cookies, cache, storage and history live in memory and go when the last
  // page using it closes.
  static std::shared_ptr<Profile> NewPrivate();

  bool is_private() const { return private_; }
  CefRefPtr<CefRequestContext> context() const { return context_; }

  Profile(bool is_private, CefRefPtr<CefRequestContext> context)
      : private_(is_private), context_(context) {}

 private:
  bool private_;
  CefRefPtr<CefRequestContext> context_;
};

// ---- pages --------------------------------------------------------------------------

// Everything a page reports, on the UI thread. |url| values are committed
// main-frame URLs as Chromium canonicalised them (lowercase host, IDN as
// punycode): the real origin, never page-supplied text.
class PageObserver {
 public:
  virtual ~PageObserver() = default;
  // |is_error_page|: Birch's own birch://error page replaced a failed load.
  virtual void OnPageAddress(const std::string& url, bool is_error_page) = 0;
  virtual void OnPageTitle(const std::string& title) = 0;
  virtual void OnPageLoading(bool loading, bool can_go_back,
                             bool can_go_forward) = 0;
  virtual void OnPageCrashed() = 0;
  // The browser is torn down; the Page may be deleted now.
  virtual void OnPageClosed() = 0;
  // A link the person opened in a new tab (Ctrl/middle-click, target=_blank
  // or a user-gesture window.open). Pop-ups without a user gesture are
  // blocked and never reach this.
  virtual void OnPageWantsNewTab(const std::string& url, bool foreground) = 0;
};

class Page {
 public:
  // Starts loading |url| in |profile|. |observer| must outlive the Page or be
  // detached by destroying the Page.
  static std::unique_ptr<Page> Create(std::shared_ptr<Profile> profile,
                                      const std::string& url,
                                      PageObserver* observer);
  ~Page();  // forces the browser closed if it is still open

  // The view to place in a ui/ panel.
  CefRefPtr<CefView> view() const;
  bool is_private() const;

  void Load(const std::string& url);
  void Back();
  void Forward();
  void Reload();
  void Stop();
  void Focus();
  bool CanGoBack() const;
  bool CanGoForward() const;
  bool IsLoading() const;
  bool HasBrowser() const;
  const std::string& committed_url() const;
  const std::string& title() const;

  // Close this page alone: its view leaves the window, then OnPageClosed.
  void Close();
  // While its window closes: true when the browser may go (Views closes it
  // with the window).
  bool TryCloseForWindow();
  bool closed() const;

  // Test runs only (BIRCH_HOME set; refused otherwise): one DevTools
  // protocol call (e.g. Runtime.evaluate with a fixed expression, or
  // Page.crash). The JSON result arrives on the UI thread. This is the
  // test harness reading the page from outside; it is not a page bridge.
  using DevToolsCallback = std::function<void(bool ok, const std::string& json)>;
  bool DevToolsForTest(const std::string& method,
                       CefRefPtr<CefDictionaryValue> params,
                       DevToolsCallback callback);
  // Test runs only: Chromium's id for the renderer process hosting the main
  // frame ("" if unknown); UI pages must never share one with a web page.
  std::string RendererKeyForTest() const;

  class Client;  // engine/cef/page.cc

 private:
  Page() = default;
  CefRefPtr<Client> client_;
  std::shared_ptr<Profile> profile_;
};

// ---- downloads --------------------------------------------------------------------------

struct DownloadEvent {
  uint32_t id = 0;
  std::string path;  // where the file was saved
  bool complete = false;
  bool failed = false;
  bool is_private = false;
  int64_t bytes = 0;
  // Windows: the Zone.Identifier text after Birch's handling; Linux: the
  // origin attributes. "" when there is none.
  std::string mark;
  bool mark_written_by_chromium = false;
};
// One listener (the app); finished and failed downloads only.
void SetDownloadListener(std::function<void(const DownloadEvent&)> listener);

// Counters for test hooks (what reached Birch's handlers). Read on the UI
// thread; no addresses are kept.
struct EngineStats {
  int camera_requests = 0;
  int microphone_requests = 0;
  int location_requests = 0;
  int notification_requests = 0;
  int other_permission_requests = 0;
  int permissions_granted = 0;  // must stay 0
  int certificate_errors = 0;
  int popups_blocked = 0;
};
const EngineStats& Stats();

// The address of Birch's own error page for a failed load ("cert", "net",
// "crash"); no part of the failed page goes into it.
std::string ErrorPageUrl(const std::string& reason, int code);
bool IsErrorPageUrl(const std::string& url);

}  // namespace birch::engine

#endif  // BIRCH_ENGINE_ENGINE_H_
