#include "ui/main_window.h"
#include "include/cef_task.h"
#include "core/codec.h"
#include "core/archive_history.h"
#include "platform/platform.h"
#include <algorithm>
#include <functional>

namespace birch::ui {
namespace {
class MaintenanceTask : public CefTask {
 public:
  explicit MaintenanceTask(std::function<void()> fn):fn_(std::move(fn)) {}
  void Execute() override { fn_(); }
 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(MaintenanceTask);
};
bool Contains(const core::Item& item,const std::string& id) {
  if(item.id==id) return true;
  for(const auto& child:item.children) if(Contains(child,id)) return true;
  return false;
}
void Leaves(const core::Item& item,std::set<std::string>& ids) {
  if(item.IsTab()) ids.insert(item.id);
  else for(const auto& child:item.children) Leaves(child,ids);
}
}
std::set<std::string> MainWindow::VisibleTabs() const {
  std::set<std::string> ids;
  auto selected=selected_id();
  if(!selected) return ids;
  ids.insert(*selected);
  const auto& space=ctx_.store->CurrentSpace(ctx_.session);
  std::function<void(const std::vector<core::Item>&)> visit=[&](const auto& items) {
    for(const auto& item:items) {
      if(item.IsSplit() && Contains(item,*selected)) Leaves(item,ids);
      else visit(item.children);
    }
  };
  visit(space.pinned);visit(space.today);
  return ids;
}
void MainWindow::SleepTabs(core::SleepTrigger trigger) {
  auto protected_ids=ctx_.host->ProtectedTabs(false);
  std::vector<std::string> sleep;
  for(const auto& kv:pages_) {
    const auto* item=ctx_.store->FindItem(kv.first);
    if(!item) continue;
    core::SleepPageState state;
    state.has_page=true;state.on_screen=protected_ids.count(kv.first)>0;
    state.loading=kv.second.page->IsLoading();
    state.playing_media=!kv.second.page->SafeToSleep();
    state.url=kv.second.page->committed_url();
    if(core::ShouldSleep(state,item->last_active,core::NowSeconds(),
                         ctx_.settings->sleepTabsAfterMinutes,trigger)) sleep.push_back(kv.first);
  }
  for(const auto& id:sleep) SleepPage(id);
  Refresh();
}
void MainWindow::MaintainTabs(bool manual_archive,bool manual_sleep) {
  if(destroyed_ || closing_window_) return;
  SleepTabs(manual_sleep?core::SleepTrigger::kManual:core::SleepTrigger::kMaintenance);
  if(ctx_.is_private) return;
  double hours=ctx_.settings->archiveAfterHours;
  if(manual_archive && hours<=0) hours=24;
  std::vector<std::string> removed;
  auto records=ctx_.store->ArchiveStale(core::NowSeconds(),hours,
                                       ctx_.host->ProtectedTabs(),&removed);
  for(const auto& id:removed) ctx_.host->EvictTab(id);
  if(!records.empty()) {
    const auto path=core::JoinPath(platform::ProfileDir(),"archive.json");
    std::string text,error; std::vector<core::ArchivedTab> archive;
    if(core::ReadFileUtf8Path(path,&text)) core::DecodeArchive(text,&archive,&error);
    archive.insert(archive.begin(),records.begin(),records.end());
    if(archive.size()>500) archive.resize(500);
    core::WriteFileAtomic(path,core::EncodeArchive(archive));
  }
  if(!removed.empty()) {ctx_.host->StoreChanged(this);Refresh();}
}
void MainWindow::ScheduleMaintenance(int64_t delay_ms) {
  CefRefPtr<MainWindow> self(this);
  CefPostDelayedTask(TID_UI,new MaintenanceTask([self] {
    if(self->destroyed_ || self->closing_window_) return;
    self->MaintainTabs();self->ScheduleMaintenance(300000);
  }),delay_ms);
}
} // namespace birch::ui
