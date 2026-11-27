#include <algorithm>
#include <cstdio>

#include "core/codec.h"
#include "core/lifecycle.h"
#include "core/state_file.h"
#include "core/store.h"

namespace {

using namespace birch::core;

int checks = 0;
int failed = 0;

void Check(const char* what, bool ok) {
  ++checks;
  if (!ok) {
    ++failed;
  }
  std::printf("sidebar-store: %s expected=true got=%s -> %s\n", what,
              ok ? "true" : "false", ok ? "PASS" : "FAIL");
}

void SidebarEditing() {
  Store store(SeedState());
  const std::string home = store.state().current_space_id;
  const std::string lab = store.AddSpace("Research", "🔬");
  const std::string folder = store.AddFolder(lab, "Projects");
  const std::string nested = store.AddFolder(lab, "Current", folder);
  const SidebarDestination favorites{SidebarSection::kFavorites, {}, {}};
  const SidebarDestination pinned{SidebarSection::kPinned, lab, {}};
  const SidebarDestination today{SidebarSection::kToday, lab, {}};
  const SidebarDestination in_folder{SidebarSection::kFolder, lab, folder};
  const SidebarDestination in_nested{SidebarSection::kFolder, lab, nested};

  Check("new space uses next theme and leaves window selection independent",
        store.FindSpace(lab)->theme.colors == Theme::Presets()[1].colors &&
        store.RestoreWindows().front().current_space_id == home);
  Check("edit and reorder space", store.EditSpace(lab, "Lab", "🧪") &&
        store.MoveSpace(lab, 0) && store.state().spaces.front().id == lab &&
        store.FindSpace(lab)->name == "Lab" && store.FindSpace(lab)->icon == "🧪");
  Check("separate login generates a profile", store.SetSeparateLogins(lab, true) &&
        store.FindSpace(lab)->profile_id.has_value());
  const auto profile = store.FindSpace(lab)->profile_id;
  Check("separate login keeps its profile on repeated enable",
        store.SetSeparateLogins(lab, true) && store.FindSpace(lab)->profile_id == profile);
  Check("shared login clears the space profile", store.SetSeparateLogins(lab, false) &&
        !store.FindSpace(lab)->profile_id);
  Check("a space without a folder cannot be a nested destination",
        store.AddFolder(home, "Wrong space", folder).empty());

  store.ClearDirty();
  Check("cycle, self-parent and wrong section are refused without editing",
        !store.MoveItem(folder, in_nested) && !store.MoveItem(folder, in_folder) &&
        !store.MoveItem(folder, favorites) && !store.MoveItem(folder, today) &&
        !store.dirty());

  const std::string tab = store.AddTab(lab, "https://start.example/", "Start");
  const std::string other = store.AddTab(lab, "https://other.example/", "Other");
  Check("reorder uses the final index",
        store.MoveItem(other, today, 1) && store.FindSpace(lab)->today.front().id == tab);
  Check("pin records the current URL",
        store.MoveItem(tab, pinned, 0) && store.IsPinned(tab) &&
        store.FindItem(tab)->pinned_url == "https://start.example/");
  store.UpdatePage(tab, "https://next.example/", "Next");
  Check("moving to a folder preserves the pinned URL",
        store.MoveItem(tab, in_nested) &&
        store.FindItem(tab)->pinned_url == "https://start.example/");

  const auto rows = store.SidebarRows(lab);
  const auto row = std::find_if(rows.begin(), rows.end(), [&](const SidebarRow& entry) {
    return entry.item_id == tab;
  });
  Check("nested row exposes its parent, depth and sibling index",
        row != rows.end() && row->parent_id == nested && row->depth == 2 &&
        row->index == 0 && row->section == "pinned");
  Check("collapsed folder hides descendants in sidebar",
        store.SetFolderExpanded(nested, false) &&
        store.SidebarRows(lab).size() + 1 == rows.size());
  Check("favorite is shared and keeps the pin address",
        store.MoveItem(tab, favorites) && store.IsFavorite(tab) &&
        store.SidebarRows(home).front().item_id == tab &&
        store.FindItem(tab)->pinned_url == "https://start.example/");
  Check("close restores the pinned address",
        store.CloseTab(tab) == Store::CloseResult::kKeptPinned &&
        store.FindItem(tab)->url == "https://start.example/");

  WindowSession window = store.RestoreWindows().front();
  window.SetSelected(home, tab);
  store.SnapshotWindows({window}, window);
  Check("moving favorite to a different space clears stale saved selections",
        store.MoveItem(tab, in_folder) &&
        !store.RestoreWindows().front().SelectedIn(home) &&
        !store.FindSpace(home)->selected_id);
  Check("unpin clears the pinned address",
        store.MoveItem(tab, today, 0) && !store.FindItem(tab)->pinned_url);

  window.current_space_id = lab;
  window.SetSelected(home, std::nullopt);
  window.SetSelected(lab, tab);
  store.SnapshotWindows({window}, window);
  AppState reopened;
  std::string error;
  Check("store state round trips",
        DecodeAppState(EncodeAppState(store.state()), &reopened, &error));
  Store restored(std::move(reopened));
  const auto windows = restored.RestoreWindows();
  Check("reopened state retains order, expansion, theme and selection",
        restored.state().spaces.size() == 2 && restored.state().spaces.front().id == lab &&
        restored.FindSpace(lab)->today.front().id == tab &&
        restored.FindSpace(lab)->theme.colors == Theme::Presets()[1].colors &&
        restored.FindItem(nested) && !restored.FindItem(nested)->expanded &&
        windows.front().current_space_id == lab && windows.front().SelectedIn(lab) == tab);
}

void SplitEditingAndArchive() {
  AppState state = SeedState();
  Space& space = state.spaces.front();
  space.today.clear();
  constexpr int64_t now = 1'800'000'000;
  const auto tab = [](const std::string& url) {
    Item item = Item::NewTab(url, url);
    item.last_active = now - 25 * 3600;
    return item;
  };
  const Item first = tab("https://first.example/");
  const Item second = tab("https://second.example/");
  const Item bundled = tab("birch://welcome");
  const Item protected_tab = tab("https://protected.example/");
  Item split;
  split.id = NewUuid();
  split.split = SplitLayout{false, {0.5, 0.5}};
  split.children = {first, second};
  space.today = {split, bundled, protected_tab};
  const std::string id = space.id;
  Store store(std::move(state));

  Check("pinning a split pane pins the full split",
        store.MoveItem(first.id, {SidebarSection::kPinned, id, {}}) &&
        store.IsPinned(split.id) && store.FindItem(second.id)->pinned_url == second.url);
  Check("favoriting a pane dissolves its two-pane split and preserves sibling",
        store.MoveItem(first.id, {SidebarSection::kFavorites, {}, {}}) &&
        store.IsFavorite(first.id) && !store.FindItem(split.id) && store.IsPinned(second.id));

  std::vector<std::string> removed;
  Check("Never setting removes no tabs", store.ArchiveStale(now, 0, {}, &removed).empty() &&
        removed.empty() && store.FindItem(bundled.id));
  Check("archive removes bundled pages without a record and protects selections",
        store.ArchiveStale(now, 24, {protected_tab.id}, &removed).empty() &&
        removed == std::vector<std::string>{bundled.id} && store.FindItem(protected_tab.id) &&
        store.FindItem(first.id) && store.FindItem(second.id));
  const auto archive = store.ArchiveStale(now, 24, {}, &removed);
  Check("archive records the original space and time",
        archive.size() == 1 && archive.front().url == protected_tab.url &&
        archive.front().space_id == id && archive.front().date == now &&
        removed == std::vector<std::string>{protected_tab.id});
}

void SleepGuards() {
  SleepPageState page;
  constexpr int64_t now = 1000;
  const auto sleep = [&](SleepTrigger trigger, double minutes, int64_t idle) {
    return ShouldSleep(page, now - idle, now, minutes, trigger);
  };
  Check("unloaded tab cannot sleep", !sleep(SleepTrigger::kManual, 0, 0));
  page.has_page = true;
  Check("manual sleep ignores age and never setting", sleep(SleepTrigger::kManual, 0, 0));
  Check("normal pressure does not sleep tabs", !sleep(SleepTrigger::kNormalPressure, 1, 600));
  Check("warning uses five minutes, strictly past the cutoff",
        !sleep(SleepTrigger::kWarningPressure, 120, 300) &&
        sleep(SleepTrigger::kWarningPressure, 120, 301));
  Check("critical uses the smaller configured interval",
        !sleep(SleepTrigger::kCriticalPressure, 0.25, 15) &&
        sleep(SleepTrigger::kCriticalPressure, 0.25, 16));
  for (const auto& [description, field] :
      {std::pair{"visible page", &SleepPageState::on_screen},
       std::pair{"playing media", &SleepPageState::playing_media},
       std::pair{"picture in picture", &SleepPageState::in_picture_in_picture},
       std::pair{"camera capture", &SleepPageState::capturing_camera},
       std::pair{"microphone capture", &SleepPageState::capturing_microphone},
       std::pair{"loading", &SleepPageState::loading}}) {
    page.*field = true;
    Check(description, !sleep(SleepTrigger::kManual, 0, 0));
    page.*field = false;
  }
  page.url = "chrome-extension://abc/index.html";
  Check("extension page does not sleep", !sleep(SleepTrigger::kManual, 0, 0));
  page.url = "birch://welcome";
  Check("bundled page does not sleep", !sleep(SleepTrigger::kManual, 0, 0));
  page.url = "https://example.test/";
  Check("web page sleeps", sleep(SleepTrigger::kManual, 0, 0));
}

}  // namespace

int main() {
  SidebarEditing();
  SplitEditingAndArchive();
  SleepGuards();
  std::printf("sidebar-store: %d/%d passed\n", checks - failed, checks);
  return failed == 0 ? 0 : 1;
}
