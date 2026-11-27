// App-level checks for sidebar layout/order, isolated spaces and relaunch.
// These scenarios use only a fresh BIRCH_HOME and the local fixture server.
#include "tests/hooks/hooks.h"

#include "app/shell.h"
#include "core/codec.h"
#include "platform/platform.h"
#include "ui/main_window.h"

namespace birch::tests {

namespace {

struct SidebarIds {
  std::string home;
  std::string home_tab;
  std::string lab;
  std::string folder;
  std::string favorite;
  std::string isolated;
  std::string pinned;
};

void Action(const std::string& action, const std::string& id = {},
            const std::string& target = {}, const std::string& text = {},
            const std::string& extra = {}) {
  core::ui_channel::Message message;
  message.kind = core::ui_channel::Kind::kSidebarAction;
  message.name = "sidebar.action";
  message.action = action;
  message.id = id;
  message.target = target;
  message.text = text;
  message.extra = extra;
  Main()->SidebarAction(message);
}

bool SelectedAndSettled(const std::string& id) {
  return !id.empty() && Main()->selected_id() == id && Settled(SelectedPage(Main()));
}

void ClickSpace(const std::string& id, const std::string& key) {
  SidebarClick(Main(), key, "#spaces button[data-space=\"" + id + "\"]");
}

void Check(const std::string& description, bool ok) {
  Expect("sidebar", description, "yes", YesNo(ok));
}

constexpr char kReadSharedCookie[] =
    "document.cookie.split('; ').includes('birchSpaceFixture=shared')";
constexpr char kReadLabCookie[] =
    "document.cookie.split('; ').includes('birchSpaceFixture=lab')";

}  // namespace

BIRCH_TEST_SCENARIO(sidebar) {
  const auto ids = std::make_shared<SidebarIds>();
  const std::string page1 = Site("a") + "/page1.html";
  const std::string page2 = Site("a") + "/page2.html";

  Then("capture initial space", [ids] {
    ids->home = Main()->session().current_space_id;
    ids->favorite = Main()->selected_id().value_or("");
  });
  LoadStep("load shared profile in Home", Main, page1, [page1](const std::string& url) {
    return url == page1;
  });
  EvalStep("write shared login fixture", Main, "shared-cookie",
           "(document.cookie='birchSpaceFixture=shared; Path=/; SameSite=Lax',"
           "document.cookie.split('; ').includes('birchSpaceFixture=shared'))");
  Then("promote the shared tab to a favorite", [ids] {
    Expect("sidebar", "shared fixture cookie set", "true", Value("shared-cookie"));
    Action("item.move", ids->favorite, "favorites");
    Check("favorite added to shared section", Main()->store().IsFavorite(ids->favorite));
  });

  Do("create Home's own tab",
     [ids, page2] { ids->home_tab = Main()->NewTab(page2, true); },
     [ids] { return SelectedAndSettled(ids->home_tab); });

  Then("create and customize an isolated space", [ids] {
    Action("space.create", {}, {}, "Lab");
    ids->lab = Main()->session().current_space_id;
    Action("space.edit", ids->lab, {}, "Lab",
           R"({"icon":"🧪","colors":["#4265AD","#8CB5E4"],"angle":220,"grain":0.35,"brightness":0.4,"separateLogins":true})");
    Action("space.move", ids->lab);
    Action("folder.create", {}, {}, "Experiments");
    const auto* lab = Main()->store().FindSpace(ids->lab);
    Check("space gets its own login profile", lab && lab->profile_id.has_value());
    Check("space moved before Home", Main()->store().state().spaces.front().id == ids->lab);
    Check("space theme updated", lab && lab->theme.angle == 220);
    if (lab && !lab->pinned.empty()) {
      ids->folder = lab->pinned.front().id;
    }
    Check("folder created in Lab", !ids->folder.empty());
  });

  Do("load the same site in Lab",
     [ids, page1] { ids->isolated = Main()->NewTab(page1, true); },
     [ids] { return SelectedAndSettled(ids->isolated); });
  EvalStep("read shared cookie from the isolated profile", Main, "lab-before",
           kReadSharedCookie);
  EvalStep("write isolated login fixture", Main, "lab-cookie",
           "(document.cookie='birchSpaceFixture=lab; Path=/; SameSite=Lax',"
           "document.cookie.split('; ').includes('birchSpaceFixture=lab'))");
  Then("verify isolated cookie context", [] {
    Expect("sidebar", "isolated page cannot see Home cookie", "false",
           Value("lab-before"));
    Expect("sidebar", "isolated profile can store its own cookie", "true",
           Value("lab-cookie"));
  });

  Do("open a second tab in Lab",
     [ids, page2] { ids->pinned = Main()->NewTab(page2, true); },
     [ids] { return SelectedAndSettled(ids->pinned); });
  EvalStep("read isolated cookie from the second tab", Main, "lab-second",
           kReadLabCookie);
  Then("pin the second tab in the folder", [ids] {
    Expect("sidebar", "tabs within Lab share the isolated cookie", "true",
           Value("lab-second"));
    Action("item.move", ids->pinned, ids->folder);
    const auto* folder = Main()->store().FindItem(ids->folder);
    Check("pinned tab moved inside the folder", folder &&
          folder->children.size() == 1 && folder->children.front().id == ids->pinned);
  });
  SidebarMatchesStep("sidebar", "favorite, pinned folder and today order", Main);
  SidebarEvalStep("read the DOM's sidebar ordering", Main, "lab-order",
                  "Array.from(document.querySelectorAll('#tabs li.tab:not(.leaving)'),"
                  "row=>row.dataset.section).join('|')");
  Then("verify the DOM section order", [] {
    Expect("sidebar", "favorite precedes pinned and today", "favorites|pinned|today",
           Value("lab-order"));
  });

  Then("sleep backgound tabs", [ids] {
    Main()->SleepTabs(core::SleepTrigger::kManual);
    Check("visible page stays live", Main()->PageFor(ids->pinned) != nullptr);
    Check("background tab releases its page", Main()->PageFor(ids->isolated) == nullptr);
    Check("sleeping tab keeps its sidebar item", Main()->store().FindItem(ids->isolated));
  });

  Do("open the shared favorite while on Lab",
     [ids] { SidebarClick(Main(), "favorite-click", RowSelector(ids->favorite)); },
     [ids] { return SelectedAndSettled(ids->favorite); });
  EvalStep("read favorite profile cookie", Main, "favorite-shared", kReadSharedCookie);
  EvalStep("check favorite has no isolated cookie", Main, "favorite-isolated",
           kReadLabCookie);
  Then("verify favorite uses the shared profile after waking", [ids] {
    Expect("sidebar", "favorite still sees Home cookie", "true", Value("favorite-shared"));
    Expect("sidebar", "favorite cannot see Lab cookie", "false", Value("favorite-isolated"));
    Main()->SelectTab(ids->pinned);
  });

  Do("click Home's space icon", [ids] { ClickSpace(ids->home, "home-click"); },
     [ids] {
       return Main()->session().current_space_id == ids->home &&
              SelectedAndSettled(ids->home_tab);
     });
  SidebarMatchesStep("sidebar", "Home has only its own tabs and shared favorite", Main);
  Do("click Lab's space icon", [ids] { ClickSpace(ids->lab, "lab-click"); },
     [ids] {
       return Main()->session().current_space_id == ids->lab &&
              SelectedAndSettled(ids->pinned);
     });
  Then("verify last tab selection for each space", [ids] {
    Check("Home selection remembered", Main()->session().SelectedIn(ids->home) == ids->home_tab);
    Check("Lab selection remembered", Main()->session().SelectedIn(ids->lab) == ids->pinned);
  });

  Then("archive stale today tabs", [ids, page1] {
    auto& store = Main()->store();
    const std::string archived = store.AddTab(ids->lab, page1, "Stale fixture");
    const auto old = core::NowSeconds() - 48 * 3600;
    store.Touch(archived, old);
    store.Touch(ids->pinned, old);
    store.Touch(ids->home_tab, old);
    Action("archive.now");
    Check("stale today tab leaves the store", !store.FindItem(archived));
    Check("pinned tab and other space's selection stay",
          store.FindItem(ids->pinned) && store.FindItem(ids->home_tab));

    std::string text;
    std::string error;
    std::vector<core::ArchivedTab> archive;
    const auto file = core::JoinPath(app::Shell::Get().profile_dir(), "archive.json");
    Check("archive.json records the stale tab's original space",
          core::ReadFileUtf8Path(file, &text) &&
              core::DecodeArchive(text, &archive, &error) && archive.size() == 1 &&
              archive.front().space_id == ids->lab && archive.front().url == page1);
  });

  const std::string hold = platform::Env("BIRCH_HOLD");
  if (!hold.empty()) {
    Then("show sidebar for screenshot", [] { platform::Log("sidebar: hold"); });
    Sleep(std::stoi(hold) * 1000);
  }

  Do("collapse the folder through the UI", [ids] {
    SidebarClick(Main(), "folder-click", "#tabs li.folder[data-item=\"" + ids->folder + "\"]");
  }, [ids] {
    const auto* folder = Main()->store().FindItem(ids->folder);
    return folder && !folder->expanded;
  });
  SidebarMatchesStep("sidebar", "folder collapsed", Main);
  Then("space shortcut commands and sidebar modes", [ids] {
    Main()->RunCommand("space.next");
    Check("next-space command selects Home",Main()->session().current_space_id==ids->home);
    Main()->RunCommand("space.previous");
    Check("previous-space command selects Lab",Main()->session().current_space_id==ids->lab);
    Main()->RunCommand("sidebar.toggle");
    Check("hide mode persists",Main()->store().state().sidebar_collapsed);
    Action("sidebar.mode", {}, {}, "peeking");
    Check("hover peek keeps hidden preference",Main()->store().state().sidebar_collapsed);
    Main()->RunCommand("sidebar.toggle");
    Check("pin mode restores sidebar preference",!Main()->store().state().sidebar_collapsed);
    core::ui_channel::Message message;message.action="sidebar.settings";
    message.extra=R"({"sidebarHoverEdgeWidth":18,"sidebarOvershootReach":70,"sidebarHideDelay":0.24,"sidebarAnimationDuration":0.3})";
    Main()->SidebarAction(message);
    Check("sidebar settings applied",app::Shell::Get().settings().sidebarHoverEdgeWidth==18 &&
      app::Shell::Get().settings().sidebarHideDelay==.24);
  });
  SidebarEvalStep("read the color and grain blends by sidebar mode", Main,
                  "theme-blend", R"js((() => {
    const mode = document.body.dataset.mode;
    const surface = document.getElementById('sidebar-surface');
    const grain = document.getElementById('grain');
    const gutter = 'calc(100% - 8px)';
    document.body.dataset.mode = 'pinned';
    const pinned = getComputedStyle(surface).backgroundImage.includes(gutter) &&
                   getComputedStyle(grain).maskImage.includes(gutter);
    document.body.dataset.mode = 'peeking';
    const floatingBackground = getComputedStyle(surface).backgroundImage;
    const floating = floatingBackground.match(/linear-gradient\(/g)?.length === 1 &&
                     getComputedStyle(grain).maskImage === 'none';
    document.body.dataset.mode = mode;
    return [pinned, floating].join('|');
  })())js");
  Then("verify space colors reach the sidebar gutter", [] {
    Expect("sidebar", "blend limited to the pinned gutter and absent while peeking",
           "true|true", Value("theme-blend"));
  });
  const auto second=std::make_shared<CefRefPtr<ui::MainWindow>>();
  Do("open a second normal window",[second] {*second=app::Shell::Get().OpenNormal();},
     [second] {return *second && (*second)->sidebar_page() && (*second)->sidebar_page()->ready();});
  Do("second window selects Home independently",[second,ids] {
    (*second)->SelectSpace(ids->home);(*second)->SelectTab(ids->home_tab);
  },[second,ids] {return (*second)->selected_id()==ids->home_tab && Settled(SelectedPage(second->get()));});
  Then("window selections stay independent",[second,ids] {
    Check("two normal windows are alive",app::Shell::Get().windows().size()==2);
    Check("windows keep different spaces",Main()->session().current_space_id==ids->lab &&
      (*second)->session().current_space_id==ids->home);
  });
  Then("save the sidebar profile", [] {
    app::Shell::Get().SaveNow();
    const auto& state=Main()->store().state();
    Check("both window sessions saved",state.windows && state.windows->size()==2);
  });
}

BIRCH_TEST_SCENARIO(sidebarrestore) {
  Then("check restored sidebar structures and session", [] {
    const auto& spaces = Main()->store().state().spaces;
    const auto windows=app::Shell::Get().windows();
    Check("both normal windows restored",windows.size()==2);
    if(windows.size()==2) Check("window spaces restored independently",
      windows[0]->session().current_space_id!=windows[1]->session().current_space_id);
    Check("space order restored", spaces.size() == 2 &&
          spaces[0].name == "Lab" && spaces[1].name == "Home");
    if (spaces.size() != 2) {
      return;
    }
    const core::Space& lab = spaces[0];
    const core::Space& home = spaces[1];
    Check("renamed theme and isolated profile restored", lab.profile_id &&
          lab.theme.colors == std::vector<std::string>{"#4265AD", "#8CB5E4"} &&
          lab.theme.brightness == 0.4);
    Check("folder contents and collapsed state restored", lab.pinned.size() == 1 &&
          lab.pinned.front().title == "Experiments" && !lab.pinned.front().expanded &&
          lab.pinned.front().children.size() == 1 &&
          lab.pinned.front().children.front().pinned_url == Site("a") + "/page2.html");
    Check("favorite restored outside both spaces", Main()->store().state().favorites.size() == 1 &&
          Main()->store().state().favorites.front().pinned_url == Site("a") + "/page1.html");
    Check("active window restores Lab and its tab", Main()->session().current_space_id == lab.id &&
          Main()->selected_id() && SelectedPage(Main())->committed_url() == Site("a") + "/page2.html");
    Check("Home's selection restored independently", home.today.size() == 1 &&
          Main()->session().SelectedIn(home.id) == home.today.front().id);
  });
  SidebarMatchesStep("sidebar", "restored session", Main);
}

}  // namespace birch::tests
