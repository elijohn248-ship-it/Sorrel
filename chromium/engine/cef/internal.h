// Shared between engine/cef/*.cc only.
#ifndef BIRCH_ENGINE_CEF_INTERNAL_H_
#define BIRCH_ENGINE_CEF_INTERNAL_H_

#include <functional>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_download_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_scheme.h"

namespace birch::engine {

// birch:// is standard, secure and display-isolated: web pages cannot link
// to, frame or fetch it.
void RegisterBirchSchemeName(CefRawPtr<CefSchemeRegistrar> registrar);
// Serves birch:// pages in |context| (nullptr = global).
void RegisterBirchSchemeHandler(CefRefPtr<CefRequestContext> context);

// Runs |fn| on the UI thread (after |delay_ms|).
void PostUI(std::function<void()> fn, int64_t delay_ms = 0);

// Browser bookkeeping for LiveBrowserCount().
void NoteBrowserCreated();
void NoteBrowserClosed();

// Downloads (engine/cef/downloads.cc).
bool HandleBeforeDownload(CefRefPtr<CefBrowser> browser, bool is_private,
                          CefRefPtr<CefDownloadItem> item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback);
void HandleDownloadUpdated(bool is_private, CefRefPtr<CefDownloadItem> item);

}  // namespace birch::engine

#endif  // BIRCH_ENGINE_CEF_INTERNAL_H_
