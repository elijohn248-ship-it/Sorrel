// UI-only checks: no real update server or installer is contacted in CI.
#include "tests/hooks/hooks.h"
#include "app/shell.h"
#include "core/ui_channel.h"
#include "engine/ui_page.h"
#include "platform/platform.h"
#include "ui/main_window.h"
namespace birch::tests {
BIRCH_TEST_SCENARIO(updateui) {
  Then("show an available update card", [] {
    Main()->sidebar_page()->Send("update.state",
      R"({"supported":true,"status":"available","message":"A newer Linux test build is available.","version":"0.0.0+test.42","canInstall":true,"automatic":false,"busy":false})");
  });
  SidebarEvalStep("read update controls",Main,"update-card",
    "[!document.getElementById('test-update').hidden,document.getElementById('update-install').hidden,document.getElementById('update-version').textContent].join('|')");
  Then("available update controls are usable", [] {
    Expect("updateui","available card","true|false|0.0.0+test.42",Value("update-card"));
  });
  auto accepted=std::make_shared<int>(0);
  Then("snapshot accepted messages",[accepted] {*accepted=engine::UiStats().accepted;});
  SidebarClickStep("click mocked update install",Main,"update-click","#update-install");
  Then("UI cannot grant installation by displaying a card",[accepted] {
    Expect("updateui","typed install reached browser process","yes",YesNo(engine::UiStats().accepted>*accepted));
    Expect("updateui","no verified app-side update means no installation","no",YesNo(app::Shell::Get().UpdateInstalling()));
    Main()->sidebar_page()->Send("update.state",
      R"({"supported":true,"status":"installing","message":"Waiting for the system installer","canInstall":true,"busy":true})");
  });
  SidebarEvalStep("read disabled install controls",Main,"update-busy",
    "document.getElementById('update-check').disabled+'|'+document.getElementById('update-install').disabled");
  Then("busy controls cannot start a second operation", [] {
    Expect("updateui","busy controls disabled","true|true",Value("update-busy"));
    Main()->RefreshUpdate();
    platform::Log("updateui: hold");
  });
  Sleep(3000);
}
}
