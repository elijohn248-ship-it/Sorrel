#include "app/shell.h"

#include <algorithm>

#include "include/cef_app.h"
#include "include/cef_task.h"

#include "core/codec.h"
#include "core/state_file.h"
#include "engine/engine.h"
#include "platform/platform.h"
#include "tests/hooks/hooks.h"

namespace birch::app {

namespace {

class FnTask : public CefTask {
 public:
  explicit FnTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(FnTask);
};

void Post(std::function<void()> fn, int64_t delay_ms) {
  CefPostDelayedTask(TID_UI, new FnTask(std::move(fn)), delay_ms);
}

constexpr int64_t kSaveDelayMs = 800;  // as the Mac's Store debouncer

}  // namespace

Shell& Shell::Get() {
  static Shell shell;
  return shell;
}

void Shell::Load(const std::string& profile_dir) {
  profile_dir_ = profile_dir;
  core::MakeDirectories(profile_dir_);
  core::SettingsLoad s = core::LoadSettings(profile_dir_);
  settings_ = s.loaded;
  platform::Log("profile: settings decoded=" +
                std::string(s.decoded ? "yes" : "no") +
                " rewritten=" + (s.file_rewritten ? "yes" : "no"));
  core::LaunchState launch = core::LoadStateOnLaunch(profile_dir_);
  platform::Log("profile: state used_file=" +
                std::string(launch.used_file ? "yes" : "no") +
                " backup=" + (launch.backup_path.empty() ? "no" : "yes") +
                " spaces=" + std::to_string(launch.state.spaces.size()));
  store_ = std::make_unique<core::Store>(launch.state);
  if (!launch.used_file) {
    core::SaveState(profile_dir_, store_->state());
  }
}

void Shell::OnEngineReady() {
  updater_=std::make_unique<ui::UpdateHost>([this] {
    for(const auto& window:windows_) window->RefreshUpdate();
  });
  engine::SetBrowserClosedListener([this] { MaybeQuit(); });
  std::vector<core::WindowSession> sessions = store_->RestoreWindows();
  for (const auto& session : sessions) {
    ui::WindowContext ctx;
    ctx.store = store_.get(); ctx.session = session;
    ctx.profile = engine::Profile::Normal(); ctx.settings = &settings_; ctx.host = this;
    CefRefPtr<ui::MainWindow> w = new ui::MainWindow(ctx);
    windows_.push_back(w); w->Open();
  }
  if(platform::EnvOn("BIRCH_INTERACTIVE_TEST")) ScheduleUpdateCheck(30000);
  if (platform::IsTestRun()) {
    tests::StartTests();
  }
}

void Shell::OnRelaunch() {
  if (ui::MainWindow* w = main_window()) {
    w->Activate();
  }
}

ui::MainWindow* Shell::main_window() const {
  for (const auto& w : windows_) {
    if (!w->is_private() && !w->destroyed()) {
      return w.get();
    }
  }
  return nullptr;
}

std::vector<ui::MainWindow*> Shell::windows() const {
  std::vector<ui::MainWindow*> out;
  for (const auto& w : windows_) {
    out.push_back(w.get());
  }
  return out;
}

ui::MainWindow* Shell::OpenPrivate() {
  if (quitting_) {
    return nullptr;
  }
  core::Space space;
  space.id = core::NewUuid();
  space.name = "Private";
  core::AppState state;
  state.current_space_id = space.id;
  state.spaces.push_back(space);
  private_stores_.push_back(std::make_unique<core::Store>(state));
  ui::WindowContext ctx;
  ctx.store = private_stores_.back().get();
  ctx.session.id = core::NewUuid();
  ctx.session.current_space_id = space.id;
  ctx.profile = engine::Profile::NewPrivate();
  ctx.settings = &settings_;
  ctx.is_private = true;
  ctx.host = this;
  CefRefPtr<ui::MainWindow> w = new ui::MainWindow(ctx);
  windows_.push_back(w);
  w->Open();
  return w.get();
}

void Shell::StoreChanged(ui::MainWindow* window) {
  for (const auto& other:windows_) if (other.get()!=window && !other->destroyed() &&
      other->is_private()==window->is_private() && &other->store()==&window->store())
    other->SynchronizeSidebar();
  if (window->is_private() || save_pending_) {
    return;  // private windows are never saved
  }
  save_pending_ = true;
  Post(
      [this] {
        save_pending_ = false;
        SaveNow();
      },
      kSaveDelayMs);
}

void Shell::SnapshotOpenWindows(ui::MainWindow* closing) {
  std::vector<core::WindowSession> open;
  const core::WindowSession* focused = nullptr;
  for (const auto& w : windows_) {
    if (w->is_private() || (w->destroyed() && w.get() != closing)) {
      continue;
    }
    open.push_back(w->session());
  }
  if (open.empty()) {
    return;  // keep the last snapshot (the window that closed last)
  }
  focused = &open.front();
  store_->SnapshotWindows(open, *focused);
}

void Shell::SaveNow() {
  if (!store_) {
    return;
  }
  SnapshotOpenWindows(nullptr);
  bool ok = core::SaveState(profile_dir_, store_->state());
  store_->ClearDirty();
  platform::Log(std::string("profile: saved state.json ok=") +
                (ok ? "yes" : "no"));
}

void Shell::WindowClosing(ui::MainWindow* window) {
  if (window->is_private() || quitting_) return;
  std::vector<core::WindowSession> remaining;
  for(const auto& other:windows_) if(other.get()!=window && !other->is_private() && !other->destroyed())
    remaining.push_back(other->session());
  if(remaining.empty()) SnapshotOpenWindows(window);
  else store_->SnapshotWindows(remaining,remaining.front());
  core::SaveState(profile_dir_,store_->state());
}

void Shell::WindowDestroyed(ui::MainWindow* window) {
  bool was_private = window->is_private();
  core::Store* private_store = was_private ? &window->store() : nullptr;
  windows_.erase(std::remove_if(windows_.begin(), windows_.end(),
                                [window](const CefRefPtr<ui::MainWindow>& w) {
                                  return w.get() == window;
                                }),
                 windows_.end());
  if (private_store) {
    // Post: the window object may still be finishing its own callbacks.
    Post(
        [this, private_store] {
          private_stores_.erase(
              std::remove_if(private_stores_.begin(), private_stores_.end(),
                             [private_store](const std::unique_ptr<core::Store>& s) {
                               return s.get() == private_store;
                             }),
              private_stores_.end());
        },
        0);
  }
  platform::Log(std::string("app: window closed private=") +
                (was_private ? "yes" : "no") +
                " open=" + std::to_string(windows_.size()));
  if (!main_window() && !quitting_) {
    // The last normal window closed: Birch quits (private windows too).
    Quit("last window closed");
  }
  MaybeQuit();
}

void Shell::Quit(const std::string& why) {
  if (quitting_) {
    return;
  }
  if(UpdateInstalling()) return;
  if(updater_) updater_->CancelCheck();
  SaveNow();  // Freeze all normal-window selections before native teardown.
  quitting_ = true;
  platform::Log("app: shutdown (" + why + ")");
  std::vector<CefRefPtr<ui::MainWindow>> windows = windows_;
  for (auto& w : windows) {
    w->Close();
  }
  Post(
      [this] {
        if (!quit_posted_) {
          platform::Log("app: shutdown forced after 15 s (live browsers=" +
                        std::to_string(engine::LiveBrowserCount()) + ")");
          quit_posted_ = true;
          CefQuitMessageLoop();
        }
      },
      15000);
  MaybeQuit();
}

void Shell::MaybeQuit() {
  if (quitting_ && !quit_posted_ && windows_.empty() &&
      engine::LiveBrowserCount() <= 0) {
    quit_posted_ = true;
    platform::Log("app: all browsers closed");
    CefQuitMessageLoop();
  }
}

void Shell::FinalSave() {
  if (store_) {
    core::SaveState(profile_dir_, store_->state());
  }
}

}  // namespace birch::app

namespace birch::app {
std::set<std::string> Shell::ProtectedTabs(bool archive) const {
  std::set<std::string> ids;
  for (const auto& window: windows_) {
    auto visible = window->VisibleTabs(); ids.insert(visible.begin(),visible.end());
    if(archive) for (const auto& pair: window->session().selections) ids.insert(pair.second);
  }
  return ids;
}
bool Shell::FocusExistingTab(ui::MainWindow* source,const std::string& id) {
  if (source->is_private()) return false;
  for (const auto& window: windows_) if (window.get()!=source && !window->is_private() &&
      !window->destroyed() && window->VisibleTabs().count(id)) {
    window->Activate(); return true;
  }
  return false;
}
bool Shell::HasLiveTab(const std::string& id) const {
  for (const auto& window: windows_) if (window->PageFor(id)) return true;
  return false;
}
} // namespace birch::app

namespace birch::app {
void Shell::EvictTab(const std::string& id) {
  for(const auto& window:windows_) window->SleepPage(id);
}
}

namespace birch::app {
ui::MainWindow* Shell::OpenNormal() {
  if(quitting_) return nullptr;
  ui::WindowContext ctx;
  ctx.store=store_.get();ctx.session.id=core::NewUuid();
  ctx.session.current_space_id=store_->state().spaces.front().id;
  ctx.profile=engine::Profile::Normal();ctx.settings=&settings_;ctx.host=this;
  CefRefPtr<ui::MainWindow> window=new ui::MainWindow(ctx);
  windows_.push_back(window);window->Open();return window.get();
}
void Shell::UpdateSidebarSettings(double edge,double overshoot,double delay,double speed) {
  settings_.sidebarHoverEdgeWidth=edge;settings_.sidebarOvershootReach=overshoot;
  settings_.sidebarHideDelay=delay;settings_.sidebarAnimationDuration=speed;
  core::SaveSettings(profile_dir_,settings_);
  for(const auto& window:windows_) if(!window->destroyed()) window->SynchronizeSidebar();
}
}

namespace birch::app {
void Shell::SetAutomaticUpdateChecks(bool enabled) {
  settings_.checkForUpdates=enabled;core::SaveSettings(profile_dir_,settings_);
  for(const auto& window:windows_) window->RefreshUpdate();
}
void Shell::ScheduleUpdateCheck(int64_t delay_ms) {
  Post([this] {
    if(quitting_) return;
    if(settings_.checkForUpdates && updater_) updater_->Check();
    ScheduleUpdateCheck(1800000);
  },delay_ms);
}
}
