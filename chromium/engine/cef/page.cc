// One web page (an Alloy-style CEF browser in a BrowserView) and every
// per-page CEF callback: committed address, title, loading, errors, crashes,
// pop-ups, downloads and permissions. Permissions are always refused;
// certificate errors are never overridden; pop-ups without a user gesture are
// blocked; another app is never launched (CEF's default for external
// protocols is to refuse).
#include <map>

#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_task.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_panel.h"

#include "core/codec.h"
#include <map>
#include "engine/cef/internal.h"
#include "engine/engine.h"
#include "engine/privacy/privacy.h"
#include "platform/platform.h"

namespace birch::engine {

namespace {

int g_live_browsers = 0;
EngineStats g_stats;
std::function<void()>& BrowserClosedListener() {
  static std::function<void()> listener;
  return listener;
}

class FnTask : public CefTask {
 public:
  explicit FnTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(FnTask);
};

// For logs: scheme://host[:port] only, never paths or queries.
std::string Origin(const std::string& url) {
  CefURLParts parts;
  if (url.empty() || !CefParseURL(url, parts)) {
    return "(none)";
  }
  std::string host = CefString(&parts.host).ToString();
  std::string port = CefString(&parts.port).ToString();
  std::string out = CefString(&parts.scheme).ToString() + "://" + host;
  return port.empty() ? out : out + ":" + port;
}

std::string PermissionNames(uint32_t bits) {
  std::string out;
  auto add = [&out](const std::string& n) { out += out.empty() ? n : "," + n; };
  if (bits & CEF_PERMISSION_TYPE_CAMERA_STREAM) add("camera");
  if (bits & CEF_PERMISSION_TYPE_MIC_STREAM) add("microphone");
  if (bits & CEF_PERMISSION_TYPE_GEOLOCATION) add("geolocation");
  if (bits & CEF_PERMISSION_TYPE_NOTIFICATIONS) add("notifications");
  uint32_t known = CEF_PERMISSION_TYPE_CAMERA_STREAM |
                   CEF_PERMISSION_TYPE_MIC_STREAM |
                   CEF_PERMISSION_TYPE_GEOLOCATION |
                   CEF_PERMISSION_TYPE_NOTIFICATIONS;
  if (bits & ~known) add("other:" + std::to_string(bits & ~known));
  return out;
}

bool OpensNewTab(cef_window_open_disposition_t d) {
  return d == CEF_WOD_NEW_FOREGROUND_TAB || d == CEF_WOD_NEW_BACKGROUND_TAB ||
         d == CEF_WOD_NEW_POPUP || d == CEF_WOD_NEW_WINDOW;
}

class PrivateContextHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> context) override {
    RegisterBirchSchemeHandler(context);
    privacy::ApplyProfilePrefs(context, "private");
  }

 private:
  IMPLEMENT_REFCOUNTING(PrivateContextHandler);
};

}  // namespace

void PostUI(std::function<void()> fn, int64_t delay_ms) {
  CefRefPtr<CefTask> task = new FnTask(std::move(fn));
  if (delay_ms > 0) {
    CefPostDelayedTask(TID_UI, task, delay_ms);
  } else {
    CefPostTask(TID_UI, task);
  }
}

void NoteBrowserCreated() {
  g_live_browsers++;
}

void NoteBrowserClosed() {
  g_live_browsers--;
  if (BrowserClosedListener()) {
    BrowserClosedListener()();
  }
}

const EngineStats& Stats() {
  return g_stats;
}

int LiveBrowserCount() {
  return g_live_browsers;
}

void SetBrowserClosedListener(std::function<void()> listener) {
  BrowserClosedListener() = std::move(listener);
}

// ---- profiles -------------------------------------------------------------------

std::shared_ptr<Profile> Profile::Normal() {
  static std::shared_ptr<Profile> normal = std::make_shared<Profile>(
      false, CefRequestContext::GetGlobalContext());
  return normal;
}

std::shared_ptr<Profile> Profile::NewPrivate() {
  // An empty cache_path makes Chromium's off-the-record storage.
  CefRequestContextSettings settings;
  return std::make_shared<Profile>(
      true, CefRequestContext::CreateContext(settings,
                                             new PrivateContextHandler()));
}

std::shared_ptr<Profile> Profile::ForSpace(const std::string& profile_id) {
  std::string id;
  if (!core::ParseUuid(profile_id, &id)) return Normal();
  static std::map<std::string, std::shared_ptr<Profile>> profiles;
  auto found = profiles.find(id);
  if (found != profiles.end()) return found->second;
  CefRequestContextSettings settings;
  if (!platform::IsTestRun() || platform::EnvOn("BIRCH_PERSIST")) {
    CefString(&settings.cache_path) = core::JoinPath(
      core::JoinPath(platform::ProfileDir(), "Chromium"), "Space-" + id);
  }
  auto profile = std::make_shared<Profile>(false,
    CefRequestContext::CreateContext(settings, new PrivateContextHandler()));
  profiles[id] = profile;
  return profile;
}

// ---- the per-page client ----------------------------------------------------------------

class Page::Client : public CefClient,
                     public CefDisplayHandler,
                     public CefLoadHandler,
                     public CefLifeSpanHandler,
                     public CefRequestHandler,
                     public CefDownloadHandler,
                     public CefPermissionHandler,
                     public CefDevToolsMessageObserver,
                     public CefBrowserViewDelegate {
 public:
  Client(PageObserver* observer, bool is_private)
      : observer_(observer), private_(is_private) {}

  // Page is going away: no more observer calls.
  void Detach() { observer_ = nullptr; }

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  // Web content never reaches the app: the UI channel's messages are
  // accepted only from UI browsers (engine/cef/ui_page.cc), never here.
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                CefProcessId,
                                CefRefPtr<CefProcessMessage> message) override {
    NoteWebProcessMessage(message->GetName().ToString());
    return true;
  }

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) {
      return;
    }
    committed_url_ = url.ToString();
    if (observer_) {
      observer_->OnPageAddress(committed_url_, IsErrorPageUrl(committed_url_));
    }
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    title_ = title.ToString();
    if (observer_) {
      observer_->OnPageTitle(title_);
    }
  }

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back,
                            bool forward) override {
    loading_ = loading;
    can_back_ = back;
    can_forward_ = forward;
    if (observer_) {
      observer_->OnPageLoading(loading, back, forward);
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   ErrorCode error_code, const CefString&,
                   const CefString& failed_url) override {
    // ERR_ABORTED: a navigation replaced by another (or a download).
    // ERR_UNKNOWN_URL_SCHEME: another app's link, which Birch doesn't open.
    if (!frame->IsMain() || error_code == ERR_ABORTED ||
        error_code == ERR_UNKNOWN_URL_SCHEME) {
      return;
    }
    int code = error_code;
    platform::Log("load: main-frame error " + std::to_string(code) +
                  " origin=" + Origin(failed_url.ToString()));
    // Certificate errors are -200 … -299. Birch's own page; the failed
    // address is not put into it.
    bool cert = code <= -200 && code > -300;
    frame->LoadURL(ErrorPageUrl(cert ? "cert" : "net", code));
  }

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     cef_window_open_disposition_t disposition,
                     bool user_gesture, const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&,
                     bool*) override {
    std::string url = target_url.ToString();
    if (user_gesture && OpensNewTab(disposition) && !url.empty()) {
      OpenInNewTab(url, disposition != CEF_WOD_NEW_BACKGROUND_TAB);
    } else {
      g_stats.popups_blocked++;
      platform::Log("popup: blocked origin=" + Origin(url) +
                    " gesture=" + (user_gesture ? "yes" : "no"));
    }
    return true;  // never a separate pop-up browser
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    NoteBrowserCreated();
    devtools_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    // Native lifecycle observations only. No evaluation, page binding or
    // page-controlled command. Retain media pages conservatively until closed.
    browser->GetHost()->ExecuteDevToolsMethod(1, "Media.enable", nullptr);
    browser->GetHost()->ExecuteDevToolsMethod(2, "WebAudio.enable", nullptr);
  }
  bool DoClose(CefRefPtr<CefBrowser>) override {
    if (!closing_single_ || window_closing_) {
      return false;  // the window is closing; Views closes the browser with it
    }
    // One page closing on its own: take its view out of the window, which
    // destroys the browser (then OnBeforeClose).
    CefRefPtr<Client> self(this);
    PostUI([self] {
      if (self->view_) {
        CefRefPtr<CefView> parent = self->view_->GetParentView();
        if (parent && parent->AsPanel()) {
          parent->AsPanel()->RemoveChildView(self->view_);
        }
        self->view_ = nullptr;
      }
    });
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    browser_ = nullptr;
    devtools_ = nullptr;
    view_ = nullptr;
    closed_ = true;
    pending_.clear();
    NoteBrowserClosed();
    CefRefPtr<Client> self(this);
    PostUI([self] {
      if (self->observer_) {
        self->observer_->OnPageClosed();
      }
    });
  }

  // CefRequestHandler
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        const CefString& target_url,
                        cef_window_open_disposition_t disposition,
                        bool user_gesture) override {
    if (!OpensNewTab(disposition)) {
      return false;  // normal navigation in this tab
    }
    if (user_gesture) {
      OpenInNewTab(target_url.ToString(),
                   disposition != CEF_WOD_NEW_BACKGROUND_TAB);
    }
    return true;
  }
  bool OnCertificateError(CefRefPtr<CefBrowser>, cef_errorcode_t cert_error,
                          const CefString& request_url, CefRefPtr<CefSSLInfo>,
                          CefRefPtr<CefCallback>) override {
    // Never continue past a bad certificate: returning false cancels the
    // request, and OnLoadError shows Birch's error page.
    g_stats.certificate_errors++;
    platform::Log("tls: certificate error " + std::to_string(cert_error) +
                  " origin=" + Origin(request_url.ToString()) +
                  " decision=cancel");
    return false;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int error_code,
                                 const CefString&) override {
    platform::Log("crash: renderer terminated status=" +
                  std::to_string(status) + " code=" +
                  std::to_string(error_code));
    if (!window_closing_ && !closing_single_) {
      browser->GetMainFrame()->LoadURL(ErrorPageUrl("crash", status));
    }
    if (observer_) {
      observer_->OnPageCrashed();
    }
  }

  // CefDownloadHandler
  bool CanDownload(CefRefPtr<CefBrowser>, const CefString& url,
                   const CefString&) override {
    platform::Log("download: allowed origin=" + Origin(url.ToString()));
    return true;
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    return HandleBeforeDownload(browser, private_, item, suggested_name,
                                callback);
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback>) override {
    HandleDownloadUpdated(private_, item);
  }

  // CefPermissionHandler: nothing is ever granted here. Wave-3 agent 7 adds
  // the asking UI; until then every request is refused.
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
      g_stats.camera_requests++;
    }
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
      g_stats.microphone_requests++;
    }
    platform::Log("perm: media request origin=" +
                  Origin(requesting_origin.ToString()) +
                  " bits=" + std::to_string(requested_permissions) +
                  " decision=deny");
    callback->Cancel();
    return true;
  }
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t prompt_id,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    uint32_t known = CEF_PERMISSION_TYPE_CAMERA_STREAM |
                     CEF_PERMISSION_TYPE_MIC_STREAM |
                     CEF_PERMISSION_TYPE_GEOLOCATION |
                     CEF_PERMISSION_TYPE_NOTIFICATIONS;
    if (requested_permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM) {
      g_stats.camera_requests++;
    }
    if (requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM) {
      g_stats.microphone_requests++;
    }
    if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) {
      g_stats.location_requests++;
    }
    if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) {
      g_stats.notification_requests++;
    }
    if (requested_permissions & ~known) {
      g_stats.other_permission_requests++;
    }
    platform::Log("perm: prompt id=" + std::to_string(prompt_id) +
                  " origin=" + Origin(requesting_origin.ToString()) +
                  " types=" + PermissionNames(requested_permissions) +
                  " decision=deny");
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  void OnMediaAccessChange(CefRefPtr<CefBrowser>, bool video, bool audio) override {
    capturing_ = video || audio;
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method,
                       const void*, size_t) override {
    auto name = method.ToString();
    if (name == "Media.playersCreated" || name == "WebAudio.contextCreated")
      has_media_ = true;
  }
  // The only production calls are fixed native media subscriptions above.
  // Arbitrary protocol calls below remain restricted to scratch-profile tests.
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id,
                              bool success, const void* result,
                              size_t result_size) override {
    if (message_id == 1) { media_monitor_ = success; return; }
    if (message_id == 2) { audio_monitor_ = success; return; }
    auto it = pending_.find(message_id);
    if (it == pending_.end()) {
      return;
    }
    DevToolsCallback cb = std::move(it->second);
    pending_.erase(it);
    std::string json(static_cast<const char*>(result), result_size);
    cb(success, json);
  }

  // CefBrowserViewDelegate
  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_ALLOY;
  }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override {
    return CEF_CTT_NONE;
  }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> view,
                        CefRefPtr<CefBrowser>) override {
    // Birch's shortcuts (Ctrl+T, Ctrl+W, Ctrl+L, …) win over the page's.
    view->SetPreferAccelerators(true);
  }

  // State read by Page.
  CefRefPtr<CefBrowserView> view_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_;
  std::string committed_url_, title_;
  bool has_media_ = false, capturing_ = false, media_monitor_ = false, audio_monitor_ = false;
  bool loading_ = false, can_back_ = false, can_forward_ = false;
  bool closing_single_ = false, window_closing_ = false, closed_ = false;
  std::map<int, DevToolsCallback> pending_;
  int next_message_id_ = 1000;

 private:
  void OpenInNewTab(const std::string& url, bool foreground) {
    platform::Log("popup: new tab origin=" + Origin(url) +
                  (foreground ? " foreground" : " background"));
    CefRefPtr<Client> self(this);
    PostUI([self, url, foreground] {
      if (self->observer_) {
        self->observer_->OnPageWantsNewTab(url, foreground);
      }
    });
  }

  PageObserver* observer_;
  bool private_;
  IMPLEMENT_REFCOUNTING(Client);
};

// ---- Page ---------------------------------------------------------------------------------

std::unique_ptr<Page> Page::Create(std::shared_ptr<Profile> profile,
                                   const std::string& url,
                                   PageObserver* observer) {
  std::unique_ptr<Page> page(new Page());
  page->profile_ = profile;
  page->client_ = new Client(observer, profile->is_private());
  CefBrowserSettings settings;
  page->client_->view_ = CefBrowserView::CreateBrowserView(
      page->client_, url, settings, nullptr, profile->context(),
      page->client_);
  return page;
}

Page::~Page() {
  if (!client_) {
    return;
  }
  client_->Detach();
  if (client_->browser_ && !client_->closed_) {
    client_->closing_single_ = true;
    client_->browser_->GetHost()->CloseBrowser(true);
  }
}

CefRefPtr<CefView> Page::view() const {
  return client_->view_;
}
bool Page::is_private() const {
  return profile_ && profile_->is_private();
}
void Page::Load(const std::string& url) {
  if (client_->browser_) {
    client_->browser_->GetMainFrame()->LoadURL(url);
  }
}
void Page::Back() {
  if (client_->browser_) {
    client_->browser_->GoBack();
  }
}
void Page::Forward() {
  if (client_->browser_) {
    client_->browser_->GoForward();
  }
}
void Page::Reload() {
  if (client_->browser_) {
    client_->browser_->Reload();
  }
}
void Page::Stop() {
  if (client_->browser_) {
    client_->browser_->StopLoad();
  }
}
void Page::Focus() {
  if (client_->view_) {
    client_->view_->RequestFocus();
  }
}
bool Page::CanGoBack() const {
  return client_->can_back_;
}
bool Page::CanGoForward() const {
  return client_->can_forward_;
}
bool Page::IsLoading() const {
  return client_->loading_;
}
bool Page::HasBrowser() const {
  return client_->browser_ != nullptr;
}
const std::string& Page::committed_url() const {
  return client_->committed_url_;
}
const std::string& Page::title() const {
  return client_->title_;
}
bool Page::SafeToSleep() const {
  return client_->media_monitor_ && client_->audio_monitor_ && !client_->has_media_ &&
    !client_->capturing_ && !client_->loading_;
}
bool Page::closed() const {
  return client_->closed_;
}

void Page::Close() {
  if (client_->closed_) {
    return;
  }
  client_->closing_single_ = true;
  if (client_->browser_) {
    client_->browser_->GetHost()->CloseBrowser(false);
  }
}

bool Page::TryCloseForWindow() {
  client_->window_closing_ = true;
  if (!client_->browser_ || client_->closed_) {
    return true;
  }
  return client_->browser_->GetHost()->TryCloseBrowser();
}

std::string Page::RendererKeyForTest() const {
  if (!platform::IsTestRun() || !client_->browser_) {
    return std::string();
  }
  return RendererKeyOf(client_->browser_->GetMainFrame());
}

bool Page::DevToolsForTest(const std::string& method,
                           CefRefPtr<CefDictionaryValue> params,
                           DevToolsCallback callback) {
  if (!platform::IsTestRun() || !client_->browser_ || !client_->devtools_) {
    return false;
  }
  int id = client_->next_message_id_++;
  client_->pending_[id] = std::move(callback);
  if (client_->browser_->GetHost()->ExecuteDevToolsMethod(id, method, params) ==
      0) {
    client_->pending_.erase(id);
    return false;
  }
  return true;
}

}  // namespace birch::engine
