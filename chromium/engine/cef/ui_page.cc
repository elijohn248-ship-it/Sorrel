// UI browsers: one CEF browser per Birch UI page, in a request context of its
// own, locked to its birch-ui:// page, and the browser-process half of the
// UI-only channel. See engine/ui_page.h for the rules.
#include "engine/ui_page.h"

#include <chrono>
#include <map>
#include <mutex>
#include <set>

#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context_handler.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"

#include "engine/cef/internal.h"
#include "engine/privacy/privacy.h"
#include "platform/platform.h"

namespace birch::engine {

namespace {

UiPageStats g_ui_stats;

// Browser id -> UI page name. Written on the UI thread, read on the IO
// thread by the birch-ui:// scheme handler.
std::mutex& RegistryLock() {
  static std::mutex m;
  return m;
}
std::map<int, std::string>& Registry() {
  static std::map<int, std::string> r;
  return r;
}

class UiContextHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> context) override {
    RegisterUiSchemeHandler(context);
    privacy::ApplyProfilePrefs(context, "ui");
  }

 private:
  IMPLEMENT_REFCOUNTING(UiContextHandler);
};

// One in-memory request context for every UI page: a browser context of its
// own, so Chromium never puts a UI page and web content in one renderer
// process, and the only place birch-ui:// has a handler.
CefRefPtr<CefRequestContext> UiContext() {
  static CefRefPtr<CefRequestContext> context = [] {
    CefRequestContextSettings settings;  // empty cache path: memory only
    return CefRequestContext::CreateContext(settings, new UiContextHandler());
  }();
  return context;
}

std::string PageUrl(const std::string& page) {
  return std::string(kUiScheme) + "://" + page + "/index.html";
}

// scheme and host of |url|, lower case as Chromium canonicalised them.
bool SchemeHost(const std::string& url, std::string* scheme,
                std::string* host) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }
  *scheme = CefString(&parts.scheme).ToString();
  *host = CefString(&parts.host).ToString();
  return true;
}

std::string SchemeOnly(const std::string& url) {
  std::string scheme, host;
  return SchemeHost(url, &scheme, &host) ? scheme : std::string("(none)");
}

}  // namespace

const UiPageStats& UiStats() {
  return g_ui_stats;
}

std::string UiPageOfBrowser(int browser_id) {
  std::lock_guard<std::mutex> lock(RegistryLock());
  auto it = Registry().find(browser_id);
  return it == Registry().end() ? std::string() : it->second;
}

void NoteWebProcessMessage(const std::string& name) {
  g_ui_stats.refused_sender++;
  platform::Log("channel: refused message '" + name.substr(0, 40) +
                "' reason=sender is not a UI page");
}

std::string RendererKeyOf(CefRefPtr<CefFrame> frame) {
  if (!frame) {
    return std::string();
  }
  std::string id = frame->GetIdentifier().ToString();
  size_t dash = id.find('-');
  return dash == std::string::npos || dash == 0 ? std::string()
                                                : id.substr(0, dash);
}

class UiPage::Client : public CefClient,
                       public CefDisplayHandler,
                       public CefLifeSpanHandler,
                       public CefRequestHandler,
                       public CefResourceRequestHandler,
                       public CefContextMenuHandler,
                       public CefPermissionHandler,
                       public CefDevToolsMessageObserver,
                       public CefBrowserViewDelegate {
 public:
  Client(std::string page, UiPageObserver* observer, int width)
      : page_(std::move(page)), observer_(observer), width_(width) {}

  void Detach() { observer_ = nullptr; }

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  // ---- the channel: browser-process checks -------------------------------------

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    std::string kind = message->GetName().ToString();
    // Who sent it, from what the browser process itself knows: this UI
    // browser, its main frame, currently on its own birch-ui:// page.
    std::string scheme, host;
    bool sender_ok =
        source_process == PID_RENDERER && browser && browser_ &&
        browser->IsSame(browser_) && frame && frame->IsValid() &&
        frame->IsMain() &&
        SchemeHost(frame->GetURL().ToString(), &scheme, &host) &&
        scheme == kUiScheme && host == page_ && kind == kUiSendMessage;
    if (!sender_ok) {
      g_ui_stats.refused_sender++;
      platform::Log("channel: refused page=" + page_ +
                    " reason=sender (main=" +
                    (frame && frame->IsMain() ? "yes" : "no") +
                    " scheme=" + scheme + " kind=" + kind.substr(0, 40) + ")");
      return true;
    }
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() != 2 || args->GetType(0) != VTYPE_STRING ||
        args->GetType(1) != VTYPE_STRING) {
      g_ui_stats.refused_message++;
      platform::Log("channel: refused page=" + page_ + " reason=envelope");
      return true;
    }
    std::string name = args->GetString(0).ToString();
    core::ui_channel::ParseResult r =
        core::ui_channel::Parse(name, args->GetString(1).ToString());
    if (!r.message) {
      g_ui_stats.refused_message++;
      // The name only when it is a listed one (never page-chosen text).
      platform::Log("channel: refused page=" + page_ + " reason=" + r.error);
      return true;
    }
    g_ui_stats.accepted++;
    if (r.message->kind == core::ui_channel::Kind::kUiReady) {
      ready_ = true;
    }
    platform::Log("channel: accepted page=" + page_ + " " + r.message->name);
    if (observer_) {
      observer_->OnUiMessage(*r.message);
    }
    return true;
  }

  // ---- locked to its own page ----------------------------------------------------

  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool,
                      bool) override {
    std::string url = request->GetURL().ToString();
    std::string scheme, host;
    bool ok = frame->IsMain() && SchemeHost(url, &scheme, &host) &&
              scheme == kUiScheme && host == page_;
    if (!ok) {
      g_ui_stats.navigations_refused++;
      platform::Log("ui: navigation refused page=" + page_ + " scheme=" +
                    SchemeOnly(url) + (frame->IsMain() ? "" : " (frame)"));
    }
    return !ok;  // true cancels
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        const CefString& target_url,
                        cef_window_open_disposition_t, bool) override {
    g_ui_stats.navigations_refused++;
    platform::Log("ui: open-in-tab refused page=" + page_ + " scheme=" +
                  SchemeOnly(target_url.ToString()));
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     cef_window_open_disposition_t, bool,
                     const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    g_ui_stats.popups_refused++;
    platform::Log("ui: pop-up refused page=" + page_ + " scheme=" +
                  SchemeOnly(target_url.ToString()));
    return true;
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool,
      bool, const CefString&, bool&) override {
    return this;
  }
  // IO thread. Everything a UI page loads must be its own birch-ui:// file
  // (its CSP says the same; this is the second lock).
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>,
                                          CefRefPtr<CefFrame>,
                                          CefRefPtr<CefRequest> request,
                                          CefRefPtr<CefCallback>) override {
    std::string scheme, host;
    if (SchemeHost(request->GetURL().ToString(), &scheme, &host) &&
        scheme == kUiScheme && host == page_) {
      return RV_CONTINUE;
    }
    std::string what = SchemeOnly(request->GetURL().ToString());
    std::string page = page_;
    PostUI([what, page] {
      g_ui_stats.requests_refused++;
      platform::Log("ui: request refused page=" + page + " scheme=" + what);
    });
    return RV_CANCEL;
  }

  // No context menu (no back/reload/inspect); editable fields keep the
  // editing commands only.
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    if (!(params->GetTypeFlags() & CM_TYPEFLAG_EDITABLE)) {
      model->Clear();
      return;
    }
    for (int i = static_cast<int>(model->GetCount()) - 1; i >= 0; --i) {
      int id = model->GetCommandIdAt(static_cast<size_t>(i));
      if (id < MENU_ID_UNDO || id > MENU_ID_SELECT_ALL) {
        model->RemoveAt(static_cast<size_t>(i));
      }
    }
  }

  // UI pages ask for nothing; anything asked is refused.
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString&, uint32_t,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    callback->Cancel();
    return true;
  }
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  // Test runs: the UI page's own console errors go to the test log.
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString&,
                        int line) override {
    if (level >= LOGSEVERITY_WARNING) {
      platform::Log("ui: console page=" + page_ + " line=" +
                    std::to_string(line) + " " +
                    message.ToString().substr(0, 300));
    }
    return false;
  }

  // ---- life span -----------------------------------------------------------------

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    {
      std::lock_guard<std::mutex> lock(RegistryLock());
      Registry()[browser->GetIdentifier()] = page_;
    }
    NoteBrowserCreated();
    if (platform::IsTestRun()) {
      devtools_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    }
  }
  bool DoClose(CefRefPtr<CefBrowser>) override { return false; }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    {
      std::lock_guard<std::mutex> lock(RegistryLock());
      Registry().erase(browser->GetIdentifier());
    }
    browser_ = nullptr;
    devtools_ = nullptr;
    view_ = nullptr;
    closed_ = true;
    ready_ = false;
    pending_.clear();
    NoteBrowserClosed();
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int,
                                 const CefString&) override {
    ready_ = false;
    g_ui_stats.crashes++;
    platform::Log("ui: renderer ended page=" + page_ +
                  " status=" + std::to_string(status));
    if (observer_) {
      observer_->OnUiCrashed();
    }
    // Reload, but not in a tight loop: at most five times a minute.
    auto now = std::chrono::steady_clock::now();
    if (now - crash_window_ > std::chrono::minutes(1)) {
      crash_window_ = now;
      crash_count_ = 0;
    }
    if (++crash_count_ <= 5) {
      CefRefPtr<CefBrowser> b = browser;
      std::string url = PageUrl(page_);
      PostUI([b, url] { b->GetMainFrame()->LoadURL(url); }, 300);
    }
  }

  // ---- DevTools (test runs only) -----------------------------------------------------

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id,
                              bool success, const void* result,
                              size_t result_size) override {
    auto it = pending_.find(message_id);
    if (it == pending_.end()) {
      return;
    }
    DevToolsCallback cb = std::move(it->second);
    pending_.erase(it);
    cb(success, std::string(static_cast<const char*>(result), result_size));
  }

  // ---- CefBrowserViewDelegate -------------------------------------------------------

  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_ALLOY;
  }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override {
    return CEF_CTT_NONE;
  }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> view,
                        CefRefPtr<CefBrowser>) override {
    view->SetPreferAccelerators(true);  // Ctrl+T etc. work from the sidebar
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override {
    return CefSize(width_, 0);
  }

  // State read by UiPage.
  std::string page_;
  UiPageObserver* observer_;
  int width_;
  CefRefPtr<CefBrowserView> view_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_;
  bool ready_ = false, closed_ = false;
  std::map<int, DevToolsCallback> pending_;
  int next_message_id_ = 1000;
  std::chrono::steady_clock::time_point crash_window_;
  int crash_count_ = 0;

 private:
  IMPLEMENT_REFCOUNTING(Client);
};

std::unique_ptr<UiPage> UiPage::Create(const std::string& page,
                                       UiPageObserver* observer, int width,
                                       bool dark) {
  std::unique_ptr<UiPage> ui(new UiPage());
  ui->client_ = new Client(page, observer, width);
  CefBrowserSettings settings;
  // No flash of white before the page draws.
  settings.background_color =
      dark ? CefColorSetARGB(255, 0x26, 0x23, 0x2E)
           : CefColorSetARGB(255, 0xF7, 0xF5, 0xFA);
  settings.javascript_access_clipboard = STATE_DISABLED;
  settings.javascript_dom_paste = STATE_DISABLED;
  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  extra->SetString(kUiExtraInfoKey, page);
  ui->client_->view_ = CefBrowserView::CreateBrowserView(
      ui->client_, PageUrl(page), settings, extra, UiContext(), ui->client_);
  return ui;
}

UiPage::~UiPage() {
  if (!client_) {
    return;
  }
  client_->Detach();
  if (client_->browser_ && !client_->closed_) {
    client_->browser_->GetHost()->CloseBrowser(true);
  }
}

CefRefPtr<CefView> UiPage::view() const {
  return client_->view_;
}
const std::string& UiPage::page() const {
  return client_->page_;
}
bool UiPage::ready() const {
  return client_->ready_;
}
void UiPage::Send(const std::string& name, const std::string& json) {
  if (!client_->ready_ || !client_->browser_) {
    return;
  }
  CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create(kUiDeliverMessage);
  CefRefPtr<CefListValue> args = msg->GetArgumentList();
  args->SetString(0, name);
  args->SetString(1, json);
  client_->browser_->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
}
void UiPage::Focus() {
  if (client_->view_) {
    client_->view_->RequestFocus();
  }
}
bool UiPage::TryCloseForWindow() {
  if (!client_->browser_ || client_->closed_) {
    return true;
  }
  return client_->browser_->GetHost()->TryCloseBrowser();
}
bool UiPage::closed() const {
  return client_->closed_;
}

bool UiPage::DevToolsForTest(const std::string& method,
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

std::string UiPage::CommittedUrlForTest() const {
  if (!platform::IsTestRun() || !client_->browser_) {
    return std::string();
  }
  return client_->browser_->GetMainFrame()->GetURL().ToString();
}

std::string UiPage::RendererKeyForTest() const {
  if (!platform::IsTestRun() || !client_->browser_) {
    return std::string();
  }
  return RendererKeyOf(client_->browser_->GetMainFrame());
}

}  // namespace birch::engine
