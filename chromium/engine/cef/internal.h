// Shared between engine/cef/*.cc only.
#ifndef BIRCH_ENGINE_CEF_INTERNAL_H_
#define BIRCH_ENGINE_CEF_INTERNAL_H_

#include <functional>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_download_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_scheme.h"

namespace birch::engine {

// birch:// is standard, secure and display-isolated: web pages cannot link
// to, frame or fetch it.
void RegisterBirchSchemeName(CefRawPtr<CefSchemeRegistrar> registrar);
// Serves birch:// pages in |context| (nullptr = global).
void RegisterBirchSchemeHandler(CefRefPtr<CefRequestContext> context);

// birch-ui:// (engine/cef/ui_scheme.cc): Birch's own UI pages, compiled in.
// Standard, secure, display-isolated; a handler exists only in the UI
// request context, and it serves files only to UI browsers.
void RegisterUiSchemeName(CefRawPtr<CefSchemeRegistrar> registrar);
void RegisterUiSchemeHandler(CefRefPtr<CefRequestContext> context);

// The UI channel (engine/cef/ui_page.cc, engine/cef/ui_renderer.cc).
inline constexpr char kUiScheme[] = "birch-ui";
inline constexpr char kUiSendMessage[] = "birch-ui.send";        // UI -> app
inline constexpr char kUiDeliverMessage[] = "birch-ui.deliver";  // app -> UI
inline constexpr char kUiExtraInfoKey[] = "birch_ui_page";
// Test runs of BIRCH_TEST=channel only: renderers send forged channel
// messages from web pages, standing in for a compromised renderer.
inline constexpr char kForgeSwitch[] = "birch-test-forge-channel";
// Browser process: the UI page a browser shows ("" = not a UI browser).
std::string UiPageOfBrowser(int browser_id);
// A web page's renderer sent a message (never accepted).
void NoteWebProcessMessage(const std::string& name);
// Renderer process: creates `birchUI` in UI browsers' main frames only.
CefRefPtr<CefRenderProcessHandler> CreateRenderProcessHandler();
// "<process>" from a frame identifier "<process>-<token>", or "".
std::string RendererKeyOf(CefRefPtr<CefFrame> frame);

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
