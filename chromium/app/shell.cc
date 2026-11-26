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
  engine::SetBrowserClosedListener([this] { MaybeQuit(); });
  std::vector<core::WindowSession> sessions = store_->RestoreWindows();
  for (const auto& session : sessions) {
    ui::WindowContext ctx;
    ctx.store = store_.get(); ctx.session = session;
    ctx.profile = engine::Profile::Normal(); ctx.settings = &settings_; ctx.host = this;
    CefRefPtr<ui::MainWindow> w = new ui::MainWindow(ctx);
    windows_.push_back(w); w->Open();
  }
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
  if (!window->is_private()) {
    SnapshotOpenWindows(window);
    core::SaveState(profile_dir_, store_->state());
  }
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
