#include "ui/main_window.h"
#include <algorithm>
#include <functional>
#include <cmath>
#include <chrono>
#include "include/cef_task.h"
#include "ui/sidebar/pointer.h"
#include "core/json.h"

namespace birch::ui {
CefSize MainWindow::GetPreferredSize(CefRefPtr<CefView> view) {
  if(sidebar_spacer_ && view->IsSame(sidebar_spacer_))
    return CefSize(sidebar_mode_=="pinned" ? std::clamp(static_cast<int>(ctx_.store->state().sidebar_width),180,480):0,1);
  return CefWindowDelegate::GetPreferredSize(view);
}
void MainWindow::OnLayoutChanged(CefRefPtr<CefView> view, const CefRect&) {
  if (window_ && view->IsSame(window_)) LayoutSidebar();
}
void MainWindow::LayoutSidebar() {
  if (!window_ || !sidebar_spacer_ || !sidebar_overlay_) return;
  int width = std::clamp(static_cast<int>(ctx_.store->state().sidebar_width),180,480);
  int edge = std::clamp(static_cast<int>(ctx_.settings->sidebarHoverEdgeWidth),2,80);
  int reserved = sidebar_mode_ == "pinned" ? width : 0;
  sidebar_spacer_->InvalidateLayout();
  sidebar_spacer_->SetVisible(reserved > 0);
  sidebar_overlay_->SetBounds(CefRect(0,0,sidebar_mode_ == "hidden" ? edge : width,
                                     window_->GetBounds().height));
}
void MainWindow::SelectSpace(const std::string& id) {
  if (!ctx_.store->FindSpace(id) || destroyed_) return;
  ctx_.session.current_space_id = id;
  for (auto& kv : pages_) if (auto view = kv.second.page->view()) view->SetVisible(false);
  if (auto sel = selected_id()) {
    const auto* owner=ctx_.store->SpaceOf(*sel);
    if(ctx_.store->IsFavorite(*sel) || (owner && owner->id==id)) SelectTab(*sel);
    else ctx_.session.SetSelected(id,std::nullopt);
  }
  ctx_.host->StoreChanged(this); Refresh();
}
void MainWindow::SidebarAction(const core::ui_channel::Message& m) {
  if (destroyed_) return;
  const auto current = ctx_.store->CurrentSpace(ctx_.session).id;
  if (m.action == "space.select") { SelectSpace(m.id); return; }
  if (m.action == "space.create") {
    SelectSpace(ctx_.store->AddSpace(m.text.empty() ? "New Space" : m.text));
  } else if (m.action == "space.move") {
    ctx_.store->MoveSpace(m.id,m.index);
  } else if (m.action == "space.edit") {
    const auto* space = ctx_.store->FindSpace(m.id);
    core::Json params;
    if (!space || !core::ParseJson(m.extra,&params) || !params.is_object()) return;
    core::Theme theme = space->theme;
    auto number = [&](const char* key, double fallback, double lo, double hi) {
      return params.contains(key) && params[key].is_number() ?
        std::clamp(params[key].get<double>(),lo,hi) : fallback;
    };
    if (params.contains("colors")) {
      if (!params["colors"].is_array() || params["colors"].empty() || params["colors"].size()>3) return;
      std::vector<std::string> colors;
      for (const auto& color: params["colors"]) {
        if (!color.is_string()) return;
        auto c = color.get<std::string>();
        if (c.size()!=7 || c[0]!='#' || c.find_first_not_of("0123456789abcdefABCDEF",1)!=std::string::npos) return;
        colors.push_back(c);
      }
      theme.colors=colors;
    }
    theme.angle=number("angle",theme.angle,0,360);
    theme.intensity=number("intensity",theme.intensity,0,1);
    theme.grain=number("grain",theme.grain.value_or(.35),0,1);
    theme.brightness=number("brightness",theme.brightness.value_or(0),0,1);
    std::string icon=space->icon;
    if (params.contains("icon") && params["icon"].is_string()) icon=params["icon"].get<std::string>();
    if (icon.size()>64 || m.text.size()>256) return;
    // A changed login identity must never keep pages in the old context.
    if (params.contains("separateLogins") && params["separateLogins"].is_boolean() &&
        params["separateLogins"].get<bool>() != space->profile_id.has_value()) {
      std::function<bool(const core::Item&)> live=[&](const core::Item& item) {
        if(ctx_.host->HasLiveTab(item.id)) return true;
        for(const auto& child:item.children) if(live(child)) return true;
        return false;
      };
      for(const auto& item:space->pinned) if(live(item)) return;
      for(const auto& item:space->today) if(live(item)) return;
      ctx_.store->SetSeparateLogins(m.id,params["separateLogins"].get<bool>());
    }
    ctx_.store->EditSpace(m.id,m.text,icon,theme);
  } else if (m.action == "folder.create") {
    ctx_.store->AddFolder(current,m.text.empty()?"New Folder":m.text,m.target);
  } else if (m.action == "folder.toggle") {
    const auto* item=ctx_.store->FindItem(m.id);
    if (item && item->is_folder) ctx_.store->SetFolderExpanded(m.id,!item->expanded);
  } else if (m.action == "item.move") {
    // Moving an open page between storage identities must close it first.
    // Reject while any normal window owns it; the user can sleep it then move.
    // Preserve live pages for reorder within one storage identity. Cross-store
    // moves require all descendant pages asleep, including other windows.
    const auto* source=ctx_.store->SpaceOf(m.id);
    const auto* target=ctx_.store->FindSpace(m.extra.empty()?current:m.extra);
    auto source_profile=source?source->profile_id:std::nullopt;
    auto target_profile=m.target=="favorites"?std::nullopt:(target?target->profile_id:std::nullopt);
    if (source_profile!=target_profile) {
      std::function<bool(const core::Item&)> live=[&](const core::Item& item) {
        if (ctx_.host->HasLiveTab(item.id)) return true;
        for(const auto& child:item.children) if(live(child)) return true;
        return false;
      };
      const auto* item=ctx_.store->FindItem(m.id);
      if (item && live(*item)) return;
    }
    core::SidebarDestination dest;
    dest.space_id=m.extra.empty()?current:m.extra;
    if (m.target=="favorites") dest.section=core::SidebarSection::kFavorites;
    else if (m.target=="pinned") dest.section=core::SidebarSection::kPinned;
    else if (m.target=="today") dest.section=core::SidebarSection::kToday;
    else { dest.section=core::SidebarSection::kFolder; dest.folder_id=m.target; }
    ctx_.store->MoveItem(m.id,dest,m.index);
  } else if (m.action == "archive.now") {
    MaintainTabs(true,false);
  } else if (m.action == "tabs.sleepNow") {
    MaintainTabs(false,true);
  } else if (m.action == "sidebar.hold") {
    sidebar_hold_ = m.value == 1;
    sidebar_outside_since_=0;return;
  } else if (m.action == "sidebar.settings") {
    if(ctx_.is_private) return;
    core::Json values;
    if(!core::ParseJson(m.extra,&values) || !values.is_object() || values.size()!=4) return;
    for(const char* key:{"sidebarHoverEdgeWidth","sidebarOvershootReach","sidebarHideDelay","sidebarAnimationDuration"})
      if(!values.contains(key) || !values[key].is_number() || !std::isfinite(values[key].get<double>())) return;
    double edge=values["sidebarHoverEdgeWidth"], reach=values["sidebarOvershootReach"],
      delay=values["sidebarHideDelay"], speed=values["sidebarAnimationDuration"];
    if(edge<2 || edge>80 || reach<0 || reach>300 || delay<0 || delay>2 || speed<0 || speed>1) return;
    ctx_.host->UpdateSidebarSettings(edge,reach,delay,speed);
  } else if (m.action == "sidebar.mode") {
    if (m.text!="pinned" && m.text!="hidden" && m.text!="peeking") return;
    const bool was_collapsed=ctx_.store->state().sidebar_collapsed;
    sidebar_mode_=m.text;
    if(m.text!="peeking") ctx_.store->SetSidebarCollapsed(m.text=="hidden");
    LayoutSidebar(); window_->Layout();
    WatchSidebar();Refresh();
    if(was_collapsed!=ctx_.store->state().sidebar_collapsed) ctx_.host->StoreChanged(this);
    return;
  }
  SynchronizeSidebar();ctx_.host->StoreChanged(this); Refresh();
}
}  // namespace birch::ui

namespace birch::ui {
void MainWindow::SynchronizeSidebar() {
  if(destroyed_ || closing_window_) return;
  const auto selections=ctx_.session.selections;
  for(const auto& pair:selections) {
    const auto* owner=ctx_.store->SpaceOf(pair.second);
    if(!ctx_.store->FindSpace(pair.first) ||
       (!ctx_.store->IsFavorite(pair.second) && (!owner || owner->id!=pair.first)))
      ctx_.session.SetSelected(pair.first,std::nullopt);
  }
  if(!selected_id()) for(auto& pair:pages_) if(auto view=pair.second.page->view()) view->SetVisible(false);
  LayoutSidebar();if(window_) window_->Layout();Refresh();
}
}

namespace birch::ui {
namespace {
class HoverTask : public CefTask {
 public:
  explicit HoverTask(std::function<void()> fn):fn_(std::move(fn)) {}
  void Execute() override { fn_(); }
 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(HoverTask);
};
}
void MainWindow::WatchSidebar() {
  if(sidebar_watch_ || !window_ || closing_window_ || destroyed_ || sidebar_mode_=="pinned") return;
  sidebar_watch_=true;
  CefPostDelayedTask(TID_UI,new HoverTask([self=CefRefPtr<MainWindow>(this)] {
    self->sidebar_watch_=false;
    if(!self->window_ || self->closing_window_ || self->destroyed_ || self->sidebar_mode_=="pinned") return;
    auto cursor=SidebarCursor();
    const auto bounds=self->window_->GetBoundsInScreen();
    const auto& settings=*self->ctx_.settings;
    bool allowed=settings.sidebarHoverWhenInactive || self->window_->IsActive();
    if(cursor && allowed && !self->window_->IsMinimized()) {
      int x=cursor->x-bounds.x,y=cursor->y-bounds.y;
      double reach=std::clamp(settings.sidebarOvershootReach,0.0,300.0);
      bool beside=y>=-1 && y<=bounds.height+1;
      bool reveal=beside && x>=-reach && x<=settings.sidebarHoverEdgeWidth;
      bool inside=beside && x>=-std::max(1.0,reach) &&
        x<=self->ctx_.store->state().sidebar_width+settings.sidebarExitTolerance;
      core::ui_channel::Message message;message.action="sidebar.mode";
      if(self->sidebar_mode_=="hidden" && reveal) {
        message.text="peeking";self->SidebarAction(message);
      } else if(self->sidebar_mode_=="peeking") {
        int64_t now=std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count();
        if(inside || self->sidebar_hold_) self->sidebar_outside_since_=0;
        else if(self->sidebar_outside_since_==0) self->sidebar_outside_since_=now;
        else if(now-self->sidebar_outside_since_>=settings.sidebarHideDelay*1000) {
          message.text="hidden";self->sidebar_outside_since_=0;self->SidebarAction(message);
        }
      }
    }
    self->WatchSidebar();
  }),40);
}
}
