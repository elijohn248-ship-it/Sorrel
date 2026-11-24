// Per-tab CEF callbacks: navigation state, close, errors, downloads and
// permission decisions. Permissions are always refused; certificates are
// never overridden; pop-ups are blocked.
#include "include/cef_parser.h"

#include "birch.h"

namespace birch {

namespace {

std::string Num(int64_t v) {
  return std::to_string(v);
}

std::string ErrorPage(const std::string& reason, int code) {
  return "birch://error/?reason=" + reason + "&code=" +
         (code < 0 ? "m" + Num(-code) : Num(code));
}

std::string SafeFileName(const std::string& suggested) {
  std::string out;
  for (char c : suggested) {
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
    out += ok ? c : '_';
  }
  if (out.empty() || out[0] == '.') {
    out = "download" + out;
  }
  return out;
}

std::string PermissionNames(uint32_t bits) {
  std::string out;
  auto add = [&out](const char* n) {
    out += out.empty() ? n : std::string(",") + n;
  };
  if (bits & CEF_PERMISSION_TYPE_CAMERA_STREAM) add("camera");
  if (bits & CEF_PERMISSION_TYPE_MIC_STREAM) add("microphone");
  if (bits & CEF_PERMISSION_TYPE_GEOLOCATION) add("geolocation");
  if (bits & CEF_PERMISSION_TYPE_NOTIFICATIONS) add("notifications");
  uint32_t known = CEF_PERMISSION_TYPE_CAMERA_STREAM |
                   CEF_PERMISSION_TYPE_MIC_STREAM |
                   CEF_PERMISSION_TYPE_GEOLOCATION |
                   CEF_PERMISSION_TYPE_NOTIFICATIONS;
  if (bits & ~known) add(("other:" + Num(bits & ~known)).c_str());
  return out;
}

}  // namespace

BirchClient::BirchClient(std::shared_ptr<Tab> tab) : tab_(std::move(tab)) {}

void BirchClient::OnAddressChange(CefRefPtr<CefBrowser>,
                                  CefRefPtr<CefFrame> frame,
                                  const CefString& url) {
  if (!tab_ || !frame->IsMain()) {
    return;
  }
  tab_->committed_url = url.ToString();
  if (tab_->window) {
    tab_->window->OnTabAddressChanged(tab_.get());
  }
}

void BirchClient::OnLoadingStateChange(CefRefPtr<CefBrowser>, bool is_loading,
                                       bool, bool) {
  if (tab_) {
    tab_->loading = is_loading;
    if (tab_->window) {
      tab_->window->OnTabAddressChanged(tab_.get());
    }
  }
}

void BirchClient::OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                            int) {
  if (tab_ && frame->IsMain()) {
    tab_->load_ends++;
  }
}

void BirchClient::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                              ErrorCode error_code, const CefString&,
                              const CefString& failed_url) {
  if (!frame->IsMain() || error_code == ERR_ABORTED) {
    return;
  }
  Log("load: main-frame error " + Num(error_code) + " origin=" +
      DisplayOrigin(failed_url.ToString()));
  if (tab_) {
    tab_->last_error = error_code;
  }
  // Birch shows its own page; the failed address is not put into it.
  // Chromium's certificate errors are -200 ... -299.
  int code = error_code;
  bool cert = code <= -200 && code > -300;
  frame->LoadURL(ErrorPage(cert ? "cert" : "net", error_code));
}

bool BirchClient::OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                                const CefString& target_url, const CefString&,
                                cef_window_open_disposition_t, bool,
                                const CefPopupFeatures&, CefWindowInfo&,
                                CefRefPtr<CefClient>&, CefBrowserSettings&,
                                CefRefPtr<CefDictionaryValue>&, bool*) {
  state().popups_blocked++;
  Log("popup: blocked origin=" + DisplayOrigin(target_url.ToString()));
  return true;
}

void BirchClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  state().live_browsers++;
  if (tab_) {
    tab_->browser = browser;
    tab_->devtools_registration =
        browser->GetHost()->AddDevToolsMessageObserver(this);
  } else {
    state().orphans.push_back(browser);
    Log("app: browser created by Chromium itself (default client) origin=" +
        DisplayOrigin(browser->GetMainFrame()->GetURL().ToString()));
    if (state().quitting) {
      browser->GetHost()->CloseBrowser(true);
    }
  }
}

bool BirchClient::DoClose(CefRefPtr<CefBrowser>) {
  if (tab_ && tab_->window) {
    return tab_->window->OnTabDoClose(tab_.get());
  }
  return false;
}

void BirchClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  state().live_browsers--;
  auto& orphans = state().orphans;
  for (size_t i = 0; i < orphans.size(); ++i) {
    if (orphans[i]->IsSame(browser)) {
      orphans.erase(orphans.begin() + static_cast<std::ptrdiff_t>(i));
      break;
    }
  }
  if (tab_) {
    tab_->devtools_registration = nullptr;
    tab_->browser = nullptr;
    tab_->closed = true;
    if (tab_->window) {
      tab_->window->OnTabClosed(tab_.get());
    }
  }
  MaybeQuit();
}

bool BirchClient::OnCertificateError(CefRefPtr<CefBrowser>,
                                     cef_errorcode_t cert_error,
                                     const CefString& request_url,
                                     CefRefPtr<CefSSLInfo>,
                                     CefRefPtr<CefCallback>) {
  // Never continue past a bad certificate. Returning false cancels the
  // request; OnLoadError then shows Birch's error page.
  if (tab_) {
    tab_->cert_errors++;
  }
  Log("tls: certificate error " + Num(cert_error) + " origin=" +
      DisplayOrigin(request_url.ToString()) + " decision=cancel");
  return false;
}

void BirchClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                            TerminationStatus status,
                                            int error_code,
                                            const CefString&) {
  Log("crash: renderer terminated status=" + Num(status) + " code=" +
      Num(error_code));
  if (tab_) {
    tab_->crashed = true;
  }
  if (!state().quitting) {
    browser->GetMainFrame()->LoadURL(ErrorPage("crash", status));
  }
}

bool BirchClient::CanDownload(CefRefPtr<CefBrowser>, const CefString& url,
                              const CefString&) {
  Log("download: allowed origin=" + DisplayOrigin(url.ToString()));
  return true;
}

bool BirchClient::OnBeforeDownload(
    CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  std::string dir = Env("BIRCH_DOWNLOADS");
  if (dir.empty()) {
    dir = JoinPath(ProfileRoot(), "Downloads");
  }
  MakeDirs(dir);
  std::string path = JoinPath(dir, SafeFileName(suggested_name.ToString()));
  Log("download: start id=" + Num(item->GetId()) + " -> " + path);
  callback->Continue(path, false);
  return true;
}

void BirchClient::OnDownloadUpdated(CefRefPtr<CefBrowser>,
                                    CefRefPtr<CefDownloadItem> item,
                                    CefRefPtr<CefDownloadItemCallback>) {
  if (!item->IsComplete() && !item->IsCanceled() && !item->IsInterrupted()) {
    return;
  }
  std::string path = item->GetFullPath().ToString();
  if (!item->IsComplete()) {
    Log("download: failed id=" + Num(item->GetId()) +
        " interrupt=" + Num(item->GetInterruptReason()));
    return;
  }
  state().downloads_done++;
  state().download_paths.push_back(path);
  Log("download: complete id=" + Num(item->GetId()) +
      " bytes=" + Num(item->GetReceivedBytes()));
#if defined(_WIN32)
  std::string zone = ReadZoneIdentifier(path);
  bool chromium_wrote = zone.find("ZoneId=3") != std::string::npos;
  Log(std::string("motw: written-by-chromium=") +
      (chromium_wrote ? "yes" : "no"));
  if (!chromium_wrote) {
    // Fallback: Birch writes the mark itself (Internet zone).
    WriteZoneIdentifier(path, item->GetOriginalUrl().ToString());
    zone = ReadZoneIdentifier(path);
  }
  std::string compact;
  for (char c : zone) {
    compact += (c == '\r') ? ' ' : (c == '\n' ? '|' : c);
  }
  Log("motw: stream=" + compact);
#endif
}

bool BirchClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
    const CefString& requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  State& s = state();
  s.media_prompts++;
  if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    s.camera_prompts++;
  }
  if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    s.mic_prompts++;
  }
  Log("perm: media request origin=" + requesting_origin.ToString() +
      " bits=" + Num(requested_permissions) + " decision=deny");
  callback->Cancel();
  return true;
}

bool BirchClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser>, uint64_t prompt_id,
    const CefString& requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  State& s = state();
  if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) {
    s.geo_prompts++;
  }
  if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) {
    s.notification_prompts++;
  }
  if (requested_permissions & (CEF_PERMISSION_TYPE_CAMERA_STREAM |
                               CEF_PERMISSION_TYPE_MIC_STREAM)) {
    s.media_prompts++;
  }
  if (!(requested_permissions & (CEF_PERMISSION_TYPE_GEOLOCATION |
                                 CEF_PERMISSION_TYPE_NOTIFICATIONS |
                                 CEF_PERMISSION_TYPE_CAMERA_STREAM |
                                 CEF_PERMISSION_TYPE_MIC_STREAM))) {
    s.other_prompts++;
  }
  Log("perm: prompt id=" + Num(static_cast<int64_t>(prompt_id)) +
      " origin=" + requesting_origin.ToString() +
      " types=" + PermissionNames(requested_permissions) + " decision=deny");
  callback->Continue(CEF_PERMISSION_RESULT_DENY);
  return true;
}

void BirchClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id,
                                         bool success, const void* result,
                                         size_t result_size) {
  State& s = state();
  auto it = s.pending.find(message_id);
  if (it == s.pending.end()) {
    return;
  }
  std::string key = it->second;
  s.pending.erase(it);
  std::string json(static_cast<const char*>(result), result_size);
  s.results[key] = success ? json : std::string("{\"devtools_error\":") +
                                        (json.empty() ? "null" : json) + "}";
}

}  // namespace birch
