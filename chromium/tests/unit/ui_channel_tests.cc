// core/ui_channel against hand-written good and bad messages (no CEF). The
// app-level checks (who may send, process separation, navigation) are the
// BIRCH_TEST=channel scenario in tests/hooks/channel_hooks.cc.
//   birch_ui_channel_tests   -> "ui-channel: <what> expected=… got=… -> PASS|FAIL"
#include <cstdio>
#include <string>

#include "core/json.h"
#include "core/ui_channel.h"

namespace {

using birch::core::ui_channel::Parse;

int g_checks = 0, g_failed = 0;

void Check(const std::string& what, const std::string& expected,
           const std::string& got) {
  ++g_checks;
  bool ok = expected == got;
  if (!ok) {
    ++g_failed;
  }
  std::printf("ui-channel: %s expected=%s got=%s -> %s\n", what.c_str(),
              expected.c_str(), got.c_str(), ok ? "PASS" : "FAIL");
}

std::string Verdict(const std::string& name, const std::string& args) {
  return Parse(name, args).message ? "accepted" : "refused";
}

const char kId[] = "\"0F8FAD5B-D9CB-469F-A165-70867728950E\"";

}  // namespace

int main() {
  using birch::core::Json;
  namespace uc = birch::core::ui_channel;
  std::string id = kId;

  // Every listed name with its proper arguments is accepted.
  Check("update auto", "accepted", Verdict("update.automatic", "{\"enabled\":true}"));
  Check("update auto type", "refused", Verdict("update.automatic", "{\"enabled\":1}"));
  Check("update.check", "accepted", Verdict("update.check", "{}"));
  Check("update.install", "accepted", Verdict("update.install", "{}"));
  Check("update arbitrary path", "refused", Verdict("update.install", "{\"path\":\"/tmp/a.deb\"}"));
  Check("ui.ready", "accepted", Verdict("ui.ready", "{}"));
  Check("tab.select", "accepted", Verdict("tab.select", "{\"id\":" + id + "}"));
  Check("tab.close", "accepted", Verdict("tab.close", "{\"id\":" + id + "}"));
  Check("tab.new", "accepted", Verdict("tab.new", "{}"));
  Check("nav.back", "accepted", Verdict("nav.back", "{}"));
  Check("nav.forward", "accepted", Verdict("nav.forward", "{}"));
  Check("nav.reload", "accepted", Verdict("nav.reload", "{}"));
  Check("address.submit", "accepted",
        Verdict("address.submit", "{\"text\":\"example.com\"}"));
  Check("address.cancel", "accepted", Verdict("address.cancel", "{}"));
  Check("address.blur", "accepted", Verdict("address.blur", "{}"));
  Check("commandbar.query", "accepted", Verdict("commandbar.query", "{\"text\":\"cats\"}"));
  Check("commandbar.query empty text", "accepted", Verdict("commandbar.query", "{\"text\":\"\"}"));
  Check("commandbar.query control characters", "refused", Verdict("commandbar.query", "{\"text\":\"a\\u0007\"}"));
  Check("commandbar.query too long", "refused", Verdict("commandbar.query", "{\"text\":\"" + std::string(5000, 'a') + "\"}"));
  Check("commandbar.query extra key", "refused", Verdict("commandbar.query", "{\"text\":\"a\",\"path\":\"/etc\"}"));
  Check("commandbar.submit", "accepted", Verdict("commandbar.submit", "{\"text\":\"!w cats\"}"));
  Check("commandbar.submit number", "refused", Verdict("commandbar.submit", "{\"text\":3}"));
  Check("commandbar.pick", "accepted", Verdict("commandbar.pick", "{\"key\":\"tab:1\"}"));
  Check("commandbar.pick missing key", "refused", Verdict("commandbar.pick", "{}"));
  Check("commandbar.cancel", "accepted", Verdict("commandbar.cancel", "{}"));
  Check("commandbar.cancel with args", "refused", Verdict("commandbar.cancel", "{\"x\":1}"));
  Check("switcher.release", "accepted", Verdict("switcher.release", "{}"));
  Check("switcher.cancel", "accepted", Verdict("switcher.cancel", "{}"));
  Check("switcher.pick", "accepted", Verdict("switcher.pick", "{\"id\":" + id + "}"));
  Check("switcher.pick not an id", "refused", Verdict("switcher.pick", "{\"id\":\"../x\"}"));
  Check("names listed", "21", std::to_string(uc::Names().size()));
  {
    uc::ParseResult r =
        Parse("tab.select", "{\"id\":\"0f8fad5b-d9cb-469f-a165-70867728950e\"}");
    Check("id is uppercased", "0F8FAD5B-D9CB-469F-A165-70867728950E",
          r.message ? r.message->id : "refused");
  }

  // Unknown or malformed names.
  Check("unknown name", "refused", Verdict("file.read", "{\"path\":\"/etc/passwd\"}"));
  Check("eval-like name", "refused", Verdict("eval", "{}"));
  Check("empty name", "refused", Verdict("", "{}"));
  Check("name with upper case", "refused", Verdict("Tab.new", "{}"));
  Check("name with odd characters", "refused", Verdict("tab.new\n", "{}"));
  Check("over-long name", "refused", Verdict(std::string(64, 'a'), "{}"));

  // Malformed arguments.
  Check("not JSON", "refused", Verdict("tab.new", "{"));
  Check("array instead of object", "refused", Verdict("tab.new", "[]"));
  Check("string instead of object", "refused", Verdict("tab.new", "\"x\""));
  Check("null", "refused", Verdict("tab.new", "null"));
  Check("extra key", "refused", Verdict("tab.new", "{\"x\":1}"));
  Check("missing key", "refused", Verdict("tab.select", "{}"));
  Check("id as number", "refused", Verdict("tab.select", "{\"id\":42}"));
  Check("id not a UUID", "refused", Verdict("tab.select", "{\"id\":\"../../x\"}"));
  Check("id with extra text", "refused",
        Verdict("tab.select", "{\"id\":\"0F8FAD5B-D9CB-469F-A165-70867728950E0\"}"));
  Check("id plus extra key", "refused",
        Verdict("tab.close", "{\"id\":" + id + ",\"also\":" + id + "}"));
  Check("text as object", "refused",
        Verdict("address.submit", "{\"text\":{\"a\":1}}"));
  Check("text too long", "refused",
        Verdict("address.submit", "{\"text\":\"" + std::string(5000, 'a') + "\"}"));
  Check("text with a newline", "refused",
        Verdict("address.submit", "{\"text\":\"a\\nb\"}"));
  Check("text with NUL", "refused",
        Verdict("address.submit", "{\"text\":\"a\\u0000b\"}"));
  Check("invalid UTF-8", "refused",
        Verdict("address.submit", "{\"text\":\"\xC3\x28\"}"));
  Check("arguments over 16 KiB", "refused",
        Verdict("address.submit",
                "{\"text\":\"a\"," + std::string(17000, ' ') + "}"));
  Check("text at the limit", "accepted",
        Verdict("address.submit", "{\"text\":\"" + std::string(4096, 'a') + "\"}"));

  {
    Json a={{"action","space.select"},{"id","x"},{"target",""},{"index",0},
            {"text",""},{"extra",""},{"value",0}};
    Check("sidebar typed action","accepted",Verdict("sidebar.action",a.dump()));
    a["action"]="script.execute";
    Check("sidebar unknown action","refused",Verdict("sidebar.action",a.dump()));
    a["action"]="space.select";a["index"]=-1;
    Check("sidebar negative index","refused",Verdict("sidebar.action",a.dump()));
    a["index"]=0;a["value"]="number";
    Check("sidebar wrong number type","refused",Verdict("sidebar.action",a.dump()));
    a["value"]=0;a["injected"]=true;
    Check("sidebar extra key","refused",Verdict("sidebar.action",a.dump()));
    a.erase("injected");a["text"]="a\n";
    Check("sidebar control text","refused",Verdict("sidebar.action",a.dump()));
  }

  // App -> UI: page-controlled text stays a JSON string value.
  {
    uc::SidebarState s;
    birch::core::SidebarRow row;
    row.item_id = "0F8FAD5B-D9CB-469F-A165-70867728950E";
    row.target_id = row.item_id;
    row.title = "</script><img src=x onerror=alert(1)>\"'`${x}";
    s.rows.push_back(row);
    s.colors = {"#FFAA00", "javascript:alert(1)"};
    std::string json = uc::SidebarStateJson(s);
    Json parsed;
    bool ok = birch::core::ParseJson(json, &parsed);
    Check("state is JSON", "yes", ok ? "yes" : "no");
    Check("hostile title round-trips as text", "yes",
          ok && parsed["rows"][0]["title"] == row.title ? "yes" : "no");
    Check("only #RRGGBB colours pass", "1",
          ok ? std::to_string(parsed["space"]["colors"].size()) : "x");
  }
  Check("surround colour", "#F9DFAF", uc::SurroundColor({"#FFAA00"}, false));
  Check("surround colour (private)", "#26232E", uc::SurroundColor({}, true));
  Check("JSON quote", "\"a\\\"b\\\\c\"", uc::JsonQuote("a\"b\\c"));

  std::printf("ui-channel: summary checks=%d failed=%d\n", g_checks, g_failed);
  return g_failed == 0 ? 0 : 1;
}
