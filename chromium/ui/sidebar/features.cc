#include "ui/main_window.h"
#include <algorithm>
#include <functional>
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
  } else if (m.action == "sidebar.mode") {
    if (m.text!="pinned" && m.text!="hidden" && m.text!="peeking") return;
    sidebar_mode_=m.text;
    if(m.text!="peeking") ctx_.store->SetSidebarCollapsed(m.text=="hidden");
    LayoutSidebar(); window_->Layout();
  }
  ctx_.host->StoreChanged(this); Refresh();
}
}  // namespace birch::ui
