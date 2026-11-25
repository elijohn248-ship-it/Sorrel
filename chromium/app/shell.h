// The application: loads the profile (settings.json, state.json), opens
// windows when CEF is ready, saves state (debounced, and on quit), and quits
// when the last window has closed. Owner: shared (wave 2); keep it thin.
#ifndef BIRCH_APP_SHELL_H_
#define BIRCH_APP_SHELL_H_

#include <memory>
#include <string>
#include <vector>

#include "core/settings.h"
#include "core/store.h"
#include "ui/main_window.h"

namespace birch::app {

class Shell : public ui::WindowHost {
 public:
  static Shell& Get();

  // Before CEF starts: reads the profile folder.
  void Load(const std::string& profile_dir);
  // CEF is ready (UI thread): restore windows, start test hooks.
  void OnEngineReady();
  // Birch was started again with this profile.
  void OnRelaunch();
  // Closes every window; the message loop ends once all pages are gone.
  void Quit(const std::string& why);
  // After the message loop: the final save.
  void FinalSave();

  const std::string& profile_dir() const { return profile_dir_; }
  const core::Settings& settings() const { return settings_; }
  core::Store& store() { return *store_; }
  // The first normal window (nullptr when none is open).
  ui::MainWindow* main_window() const;
  ui::MainWindow* OpenPrivate();
  std::vector<ui::MainWindow*> windows() const;
  bool quitting() const { return quitting_; }

  // Writes state.json now (normal windows only).
  void SaveNow();

  // ui::WindowHost
  void StoreChanged(ui::MainWindow* window) override;
  void OpenPrivateWindow() override { OpenPrivate(); }
  void WindowClosing(ui::MainWindow* window) override;
  void WindowDestroyed(ui::MainWindow* window) override;

 private:
  void SnapshotOpenWindows(ui::MainWindow* closing);
  void MaybeQuit();

  std::string profile_dir_;
  core::Settings settings_;
  std::unique_ptr<core::Store> store_;
  // Private windows each have their own store, never saved.
  std::vector<std::unique_ptr<core::Store>> private_stores_;
  std::vector<CefRefPtr<ui::MainWindow>> windows_;
  bool save_pending_ = false;
  bool quitting_ = false;
  bool quit_posted_ = false;
};

}  // namespace birch::app

#endif  // BIRCH_APP_SHELL_H_
