// birch-ui://<page>/<file>: Birch's own UI pages from chromium/ui/web/,
// compiled into the app (tools/embed_ui.py). Never the network, never the
// profile. birch-ui://<page>/shared/<file> serves ui/web/shared/<file>, so
// every page loads the shared motion and channel files from its own origin.
#include <algorithm>
#include <cstring>

#include "include/cef_parser.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"
#include "include/cef_scheme.h"

#include "engine/cef/internal.h"
#include "engine/cef/ui_resources.h"

namespace birch::engine {

namespace {

// Strict: only the page's own files; no inline script, no frames, no
// network, no forms.
const char kCsp[] =
    "default-src 'none'; script-src 'self'; style-src 'self'; "
    "img-src 'self' data:; font-src 'self'; connect-src 'none'; "
    "media-src 'none'; object-src 'none'; frame-src 'none'; "
    "child-src 'none'; worker-src 'none'; frame-ancestors 'none'; "
    "base-uri 'none'; form-action 'none'";

class BytesHandler : public CefResourceHandler {
 public:
  BytesHandler(const unsigned char* data, size_t size, std::string mime,
               int status)
      : data_(data), size_(size), mime_(std::move(mime)), status_(status) {}

  bool Open(CefRefPtr<CefRequest>, bool& handle_request,
            CefRefPtr<CefCallback>) override {
    handle_request = true;
    return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length, CefString&) override {
    response->SetStatus(status_);
    response->SetMimeType(mime_);
    response->SetCharset("utf-8");
    response->SetHeaderByName("Content-Security-Policy", kCsp, true);
    response->SetHeaderByName("X-Content-Type-Options", "nosniff", true);
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response->SetHeaderByName("Referrer-Policy", "no-referrer", true);
    response_length = static_cast<int64_t>(size_);
  }
  bool Read(void* data_out, int bytes_to_read, int& bytes_read,
            CefRefPtr<CefResourceReadCallback>) override {
    size_t left = size_ - offset_;
    size_t n = std::min(left, static_cast<size_t>(std::max(bytes_to_read, 0)));
    if (n == 0) {
      bytes_read = 0;
      return false;
    }
    std::memcpy(data_out, data_ + offset_, n);
    offset_ += n;
    bytes_read = static_cast<int>(n);
    return true;
  }
  void Cancel() override {}

 private:
  const unsigned char* data_;
  size_t size_;
  std::string mime_;
  int status_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(BytesHandler);
};

const unsigned char kNotFound[] = "not found";

CefRefPtr<CefResourceHandler> NotFound() {
  return new BytesHandler(kNotFound, sizeof kNotFound - 1, "text/plain", 404);
}

bool PathCharsOk(const std::string& p) {
  if (p.find("..") != std::string::npos || p.find("//") != std::string::npos) {
    return false;
  }
  for (char c : p) {
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
              c == '/';
    if (!ok) {
      return false;
    }
  }
  return true;
}

class UiSchemeFactory : public CefSchemeHandlerFactory {
 public:
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame>, const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    // This handler exists only in the UI request context, which hosts only
    // UI browsers. A browser already known as a UI page gets only its own
    // page's files (its first request can come before it is registered).
    std::string owner =
        browser ? UiPageOfBrowser(browser->GetIdentifier()) : std::string();
    CefURLParts parts;
    if (!browser || request->GetMethod().ToString() != "GET" ||
        !CefParseURL(request->GetURL(), parts)) {
      return NotFound();
    }
    std::string host = CefString(&parts.host).ToString();
    std::string path = CefString(&parts.path).ToString();
    if ((!owner.empty() && host != owner) || host == "shared" ||
        path.empty() || path[0] != '/' || !PathCharsOk(path) ||
        !ui_resources::Find(host + "/index.html")) {
      return NotFound();
    }
    std::string file;
    if (path == "/") {
      file = host + "/index.html";
    } else if (path.rfind("/shared/", 0) == 0) {
      file = path.substr(1);
    } else {
      file = host + path;
    }
    const ui_resources::Resource* r = ui_resources::Find(file);
    if (!r) {
      return NotFound();
    }
    return new BytesHandler(r->data, r->size, r->mime, 200);
  }

 private:
  IMPLEMENT_REFCOUNTING(UiSchemeFactory);
};

}  // namespace

void RegisterUiSchemeName(CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(kUiScheme, CEF_SCHEME_OPTION_STANDARD |
                                            CEF_SCHEME_OPTION_SECURE |
                                            CEF_SCHEME_OPTION_DISPLAY_ISOLATED);
}

void RegisterUiSchemeHandler(CefRefPtr<CefRequestContext> context) {
  static CefRefPtr<CefSchemeHandlerFactory> factory = new UiSchemeFactory();
  context->RegisterSchemeHandlerFactory(kUiScheme, "", factory);
}

}  // namespace birch::engine
