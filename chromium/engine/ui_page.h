// The UI host: Birch's own HTML pages (sidebar now; command bar, Peek,
// Library, settings in wave 3) each in a CEF browser of its own, and the
// UI-only channel between those pages and the app. This is the one approved
// exception to AGENTS.md rule 4 (owner, 2026-11-25); its limits are in
// CLAUDE.md ▸ Chromium edition ▸ UI host. In short:
//
//  * Pages come only from the app's own files (chromium/ui/web/, compiled
//    in), served as birch-ui://<page>/ in a request context of their own
//    (so a UI page never shares a renderer process with web content, and
//    web contexts have no birch-ui:// handler at all).
//  * A UI browser never loads anything else: navigation away from its own
//    page, pop-ups, drops and every non-birch-ui request are cancelled; no
//    context menu beyond editing; DevTools only for test runs (BIRCH_HOME).
//  * Messages are accepted only when the browser process itself sees that
//    they came from a UI browser's main frame showing its own page; the
//    renderer's claims are never trusted. Then core/ui_channel checks the
//    name and argument types. The JS object (`birchUI`) is created only in
//    UI browsers' main frames; web tabs, frames and pop-ups never have it.
//  * App -> UI data is JSON, delivered as a message and parsed by the page's
//    own JSON.parse; the app never builds JavaScript source.
//
// engine/ owns this (it is CEF code); ui/<area>/ uses it.
#ifndef BIRCH_ENGINE_UI_PAGE_H_
#define BIRCH_ENGINE_UI_PAGE_H_

#include <functional>
#include <memory>
#include <string>

#include "include/cef_values.h"
#include "include/views/cef_view.h"

#include "core/ui_channel.h"

namespace birch::engine {

class UiPageObserver {
 public:
  virtual ~UiPageObserver() = default;
  // A message that passed both the sender check and core::ui_channel.
  virtual void OnUiMessage(const core::ui_channel::Message& message) = 0;
  // The page's renderer ended; the page reloads itself (ui.ready follows).
  virtual void OnUiCrashed() {}
  virtual void OnUiClosed() {}
};

struct UiPageStats {
  int accepted = 0;
  int refused_sender = 0;   // not a UI browser's main frame on its own page
  int refused_message = 0;  // unknown name or bad arguments
  int navigations_refused = 0;
  int popups_refused = 0;
  int requests_refused = 0;  // subresources that weren't birch-ui://
  int crashes = 0;
};
// Totals over every UI page (test hooks read them).
const UiPageStats& UiStats();

class UiPage {
 public:
  // |page| is a folder of chromium/ui/web/ ("sidebar"). |width| is the
  // preferred width of its view (0 = whatever the layout gives it).
  static std::unique_ptr<UiPage> Create(const std::string& page,
                                        UiPageObserver* observer, int width,
                                        bool dark);
  ~UiPage();

  CefRefPtr<CefView> view() const;
  const std::string& page() const;
  // The page said ui.ready and has not crashed since.
  bool ready() const;
  // App -> UI: |name| and a JSON object (from core::ui_channel). Dropped
  // while the page isn't ready; the observer re-sends state on ui.ready.
  void Send(const std::string& name, const std::string& json);
  void Focus();

  // Same window-closing protocol as engine::Page.
  bool TryCloseForWindow();
  // Close a UI page detached from its overlay; completion is OnUiClosed.
  void CloseDetached();
  bool closed() const;

  // Test runs only: what engine::Page::DevToolsForTest does, on the UI page.
  using DevToolsCallback = std::function<void(bool ok, const std::string& json)>;
  bool DevToolsForTest(const std::string& method,
                       CefRefPtr<CefDictionaryValue> params,
                       DevToolsCallback callback);
  // Test runs only: the committed address of the UI page.
  std::string CommittedUrlForTest() const;
  // Test runs only: Chromium's id for the renderer process hosting the main
  // frame (from the frame identifier "<process>-<token>"), "" if unknown.
  std::string RendererKeyForTest() const;

  class Client;  // engine/cef/ui_page.cc

 private:
  UiPage() = default;
  CefRefPtr<Client> client_;
};

}  // namespace birch::engine

#endif  // BIRCH_ENGINE_UI_PAGE_H_
