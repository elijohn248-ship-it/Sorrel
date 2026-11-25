// Renderer half of the UI-only channel. Runs in (sandboxed) renderer
// processes. It creates `birchUI` = { send(name, args), onMessage(fn) } only
// in the main frame of a browser the app created as a UI page, while that
// frame shows the page's own birch-ui:// address. Web tabs, frames, pop-ups
// and extension pages never get it. The browser process re-checks every
// message's real sender anyway (engine/cef/ui_page.cc); nothing here is
// trusted. No logging: renderers can't write the test log.
#include <map>

#include "include/cef_command_line.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

#include "engine/cef/internal.h"

namespace birch::engine {

namespace {

struct UiContextState {
  CefRefPtr<CefV8Context> context;
  CefRefPtr<CefV8Value> json, stringify, parse;
  CefRefPtr<CefV8Value> callback;  // set by birchUI.onMessage
};

class UiRenderer;

class ChannelFunctions : public CefV8Handler {
 public:
  explicit ChannelFunctions(UiRenderer* owner) : owner_(owner) {}
  bool Execute(const CefString& name, CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments, CefRefPtr<CefV8Value>& retval,
               CefString& exception) override;

 private:
  UiRenderer* owner_;
  IMPLEMENT_REFCOUNTING(ChannelFunctions);
};

class UiRenderer : public CefRenderProcessHandler {
 public:
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info && extra_info->HasKey(kUiExtraInfoKey)) {
      ui_pages_[browser->GetIdentifier()] =
          extra_info->GetString(kUiExtraInfoKey).ToString();
    }
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    ui_pages_.erase(browser->GetIdentifier());
    contexts_.erase(browser->GetIdentifier());
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    auto page = ui_pages_.find(browser->GetIdentifier());
    std::string prefix = page == ui_pages_.end()
                             ? std::string()
                             : std::string(kUiScheme) + "://" + page->second + "/";
    std::string url = frame->GetURL().ToString();
    if (page == ui_pages_.end() || !frame->IsMain() ||
        url.rfind(prefix, 0) != 0) {
      MaybeForge(browser, frame, url);
      return;
    }
    // Before any page script runs: keep the original JSON functions.
    UiContextState st;
    st.context = context;
    CefRefPtr<CefV8Value> global = context->GetGlobal();
    st.json = global->GetValue("JSON");
    if (!st.json || !st.json->IsObject()) {
      return;
    }
    st.stringify = st.json->GetValue("stringify");
    st.parse = st.json->GetValue("parse");
    if (!st.stringify || !st.stringify->IsFunction() || !st.parse ||
        !st.parse->IsFunction()) {
      return;
    }
    CefRefPtr<CefV8Handler> fns = new ChannelFunctions(this);
    CefRefPtr<CefV8Value> api = CefV8Value::CreateObject(nullptr, nullptr);
    const auto fixed = static_cast<CefV8Value::PropertyAttribute>(
        V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTDELETE);
    api->SetValue("send", CefV8Value::CreateFunction("send", fns), fixed);
    api->SetValue("onMessage", CefV8Value::CreateFunction("onMessage", fns),
                  fixed);
    global->SetValue("birchUI", api, fixed);
    contexts_[browser->GetIdentifier()] = st;
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                         CefRefPtr<CefV8Context> context) override {
    auto it = contexts_.find(browser->GetIdentifier());
    if (it != contexts_.end() && it->second.context->IsSame(context)) {
      contexts_.erase(it);
    }
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (source_process != PID_BROWSER ||
        message->GetName().ToString() != kUiDeliverMessage) {
      return false;
    }
    auto it = contexts_.find(browser->GetIdentifier());
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (it == contexts_.end() || !frame->IsMain() || !it->second.callback ||
        args->GetSize() != 2) {
      return true;
    }
    UiContextState& st = it->second;
    if (!st.context->Enter()) {
      return true;
    }
    CefV8ValueList parse_args = {CefV8Value::CreateString(args->GetString(1))};
    CefRefPtr<CefV8Value> data = st.parse->ExecuteFunction(st.json, parse_args);
    if (data) {
      CefV8ValueList call_args = {CefV8Value::CreateString(args->GetString(0)),
                                  data};
      st.callback->ExecuteFunction(nullptr, call_args);
    }
    st.context->Exit();
    return true;
  }

  // birchUI.send(name, args) / birchUI.onMessage(fn).
  bool Run(const std::string& fn, const CefV8ValueList& arguments,
           CefString& exception) {
    CefRefPtr<CefV8Context> current = CefV8Context::GetCurrentContext();
    CefRefPtr<CefBrowser> browser = current ? current->GetBrowser() : nullptr;
    auto it = browser ? contexts_.find(browser->GetIdentifier())
                      : contexts_.end();
    if (it == contexts_.end() || !it->second.context->IsSame(current)) {
      exception = "birchUI is not available here";
      return true;
    }
    UiContextState& st = it->second;
    if (fn == "onMessage") {
      if (arguments.size() != 1 || !arguments[0]->IsFunction()) {
        exception = "onMessage(fn)";
        return true;
      }
      st.callback = arguments[0];
      return true;
    }
    if (arguments.empty() || !arguments[0]->IsString()) {
      exception = "send(name, args)";
      return true;
    }
    // The arguments as JSON text; the browser process validates them.
    std::string json = "{}";
    if (arguments.size() > 1) {
      CefV8ValueList one = {arguments[1]};
      CefRefPtr<CefV8Value> text = st.stringify->ExecuteFunction(st.json, one);
      json = text && text->IsString() ? text->GetStringValue().ToString()
                                      : std::string("null");
    }
    CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create(kUiSendMessage);
    msg->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    msg->GetArgumentList()->SetString(1, json);
    current->GetFrame()->SendProcessMessage(PID_BROWSER, msg);
    return true;
  }

 private:
  // BIRCH_TEST=channel only (a switch the browser adds to renderers in that
  // test run): a web page's renderer sends channel messages as if it were a
  // compromised renderer. The browser process must refuse every one.
  void MaybeForge(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                  const std::string& url) {
    static const bool forge =
        CefCommandLine::GetGlobalCommandLine()->HasSwitch(kForgeSwitch);
    if (!forge || url.find("/forge.html") == std::string::npos) {
      return;
    }
    const char* const forged[][2] = {
        {"tab.new", "{}"},
        {"nav.reload", "{}"},
        {"address.submit", "{\"text\":\"http://forged.birch.test/\"}"},
    };
    for (const auto& f : forged) {
      CefRefPtr<CefProcessMessage> msg =
          CefProcessMessage::Create(kUiSendMessage);
      msg->GetArgumentList()->SetString(0, f[0]);
      msg->GetArgumentList()->SetString(1, f[1]);
      frame->SendProcessMessage(PID_BROWSER, msg);
    }
  }

  std::map<int, std::string> ui_pages_;
  std::map<int, UiContextState> contexts_;
  IMPLEMENT_REFCOUNTING(UiRenderer);
};

bool ChannelFunctions::Execute(const CefString& name, CefRefPtr<CefV8Value>,
                               const CefV8ValueList& arguments,
                               CefRefPtr<CefV8Value>& retval,
                               CefString& exception) {
  retval = CefV8Value::CreateUndefined();
  return owner_->Run(name.ToString(), arguments, exception);
}

}  // namespace

CefRefPtr<CefRenderProcessHandler> CreateRenderProcessHandler() {
  return new UiRenderer();
}

}  // namespace birch::engine
