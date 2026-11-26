// birch:// pages: Birch's own welcome and error pages. Fixed HTML; nothing
// from a web page is ever placed into them (error pages carry only a reason
// word and a number, both re-checked here).
#include <algorithm>
#include <cstring>

#include "include/cef_parser.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"
#include "include/cef_scheme.h"

#include "core/model.h"
#include "engine/cef/internal.h"
#include "engine/engine.h"

namespace birch::engine {

namespace {

const char kStyle[] =
    "<style>body{font:15px/1.5 system-ui,sans-serif;margin:0;display:flex;"
    "min-height:100vh;align-items:center;justify-content:center;"
    "background:linear-gradient(135deg,#ece8ff,#e2f2f8);color:#1d1d24}"
    "main{max-width:34em;padding:2em}h1{font-weight:600}"
    "@media (prefers-color-scheme:dark){body{background:linear-gradient("
    "135deg,#24213a,#1b2a30);color:#ecebf2}}</style>";

std::string WelcomePage() {
  return std::string("<!doctype html><meta charset=utf-8>"
                     "<title>Welcome to Birch</title>") +
         kStyle +
         "<main><h1>Welcome to Birch</h1>"
         "<p>This is the first build of Birch for Windows and Linux. Type an "
         "address or a search in the box at the top of the sidebar and press "
         "Enter. Ctrl+T opens a new tab, Ctrl+W closes one, Ctrl+Shift+N "
         "opens a private window.</p>"
         "<p>Birch has no telemetry. Linux test builds can check for signed updates; control those checks in the sidebar.</p>"
         "</main>";
}

std::string ErrorPage(const std::string& reason, const std::string& code) {
  std::string what = "Birch couldn't open this page.";
  if (reason == "cert") {
    what = "This site's security certificate isn't valid, so Birch didn't "
           "open it.";
  } else if (reason == "crash") {
    what = "This page stopped working. Reload to try again.";
  }
  return std::string("<!doctype html><meta charset=utf-8>"
                     "<title>Can't open this page</title>") +
         kStyle + "<body data-birch-error='" + reason + "' data-code='" +
         code + "'><main><h1>Can't open this page</h1><p>" + what +
         "</p><p>Error " + code + "</p></main>";
}

// Only [a-z0-9-], at most 32 characters.
std::string Clean(const std::string& in) {
  std::string out;
  for (char c : in) {
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
      out += c;
    }
  }
  return out.substr(0, 32);
}

std::string QueryValue(const std::string& query, const std::string& key) {
  for (size_t pos = 0; pos <= query.size();) {
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

class StringHandler : public CefResourceHandler {
 public:
  StringHandler(std::string body, int status)
      : body_(std::move(body)), status_(status) {}

  bool Open(CefRefPtr<CefRequest>, bool& handle_request,
            CefRefPtr<CefCallback>) override {
    handle_request = true;
    return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length, CefString&) override {
    response->SetStatus(status_);
    response->SetMimeType("text/html");
    response->SetCharset("utf-8");
    response->SetHeaderByName("Content-Security-Policy",
                              "default-src 'none'; style-src 'unsafe-inline'",
                              true);
    response_length = static_cast<int64_t>(body_.size());
  }
  bool Read(void* data_out, int bytes_to_read, int& bytes_read,
            CefRefPtr<CefResourceReadCallback>) override {
    size_t left = body_.size() - offset_;
    size_t n = std::min(left, static_cast<size_t>(std::max(bytes_to_read, 0)));
    if (n == 0) {
      bytes_read = 0;
      return false;  // done
    }
    std::memcpy(data_out, body_.data() + offset_, n);
    offset_ += n;
    bytes_read = static_cast<int>(n);
    return true;
  }
  void Cancel() override {}

 private:
  std::string body_;
  int status_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(StringHandler);
};

class BirchSchemeFactory : public CefSchemeHandlerFactory {
 public:
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser>,
                                       CefRefPtr<CefFrame>, const CefString&,
                                       CefRefPtr<CefRequest> request) override {
    CefURLParts parts;
    if (!CefParseURL(request->GetURL(), parts)) {
      return new StringHandler("Not found", 404);
    }
    std::string name = CefString(&parts.host).ToString();
    if (!core::bundled_page::PlainNameAllowed(name)) {
      return new StringHandler("Not found", 404);
    }
    if (name == "welcome") {
      return new StringHandler(WelcomePage(), 200);
    }
    if (name == "error") {
      std::string query = CefString(&parts.query).ToString();
      return new StringHandler(
          ErrorPage(Clean(QueryValue(query, "reason")),
                    Clean(QueryValue(query, "code"))),
          200);
    }
    return new StringHandler("<!doctype html><title>Not found</title>", 404);
  }

 private:
  IMPLEMENT_REFCOUNTING(BirchSchemeFactory);
};

}  // namespace

void RegisterBirchSchemeName(CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme("birch", CEF_SCHEME_OPTION_STANDARD |
                                          CEF_SCHEME_OPTION_SECURE |
                                          CEF_SCHEME_OPTION_DISPLAY_ISOLATED);
}

void RegisterBirchSchemeHandler(CefRefPtr<CefRequestContext> context) {
  static CefRefPtr<CefSchemeHandlerFactory> factory = new BirchSchemeFactory();
  if (context) {
    context->RegisterSchemeHandlerFactory("birch", "", factory);
  } else {
    CefRegisterSchemeHandlerFactory("birch", "", factory);
  }
}

std::string ErrorPageUrl(const std::string& reason, int code) {
  return "birch://error/?reason=" + Clean(reason) + "&code=" +
         (code < 0 ? "m" + std::to_string(-code) : std::to_string(code));
}

bool IsErrorPageUrl(const std::string& url) {
  return url.rfind("birch://error", 0) == 0;
}

}  // namespace birch::engine
