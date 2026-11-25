// The wave-2 sidebar: plain native CEF Views controls listing the current
// space's tabs (favorites, pinned with folders, a separator, today's tabs),
// with a close button per tab and "+ New Tab". It draws rows from
// core::Store::SidebarRows; it never touches pages.
//
// Owner: wave-3 agent 5 (cx-spaces-sidebar), who may replace this view
// entirely: with native views (as here) or, only after the owner approves a
// UI-only channel (AGENTS.md rule 4), an HTML sidebar. Either way MainWindow
// talks to it only through Rebuild()/SetWidth() and WindowActions.
#ifndef BIRCH_UI_SIDEBAR_SIDEBAR_VIEW_H_
#define BIRCH_UI_SIDEBAR_SIDEBAR_VIEW_H_

#include <map>
#include <string>
#include <vector>

#include "include/views/cef_button_delegate.h"
#include "include/views/cef_label_button.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_panel_delegate.h"
#include "include/views/cef_scroll_view.h"

#include "core/store.h"
#include "ui/window_actions.h"

namespace birch::ui {

class SidebarView : public CefPanelDelegate, public CefButtonDelegate {
 public:
  SidebarView(WindowActions* actions, int width, bool is_private);

  // The whole sidebar; |header| (the toolbar) goes on top.
  CefRefPtr<CefPanel> panel() const { return root_; }
  void SetHeader(CefRefPtr<CefView> header);

  // Redraws the rows of |space| with |selected_id| highlighted.
  void Rebuild(const std::string& space_title,
               const std::vector<core::SidebarRow>& rows,
               const std::string& selected_id);

  // For tests: the titles of the rows that are tabs, in order.
  std::vector<std::string> RowTitles() const { return row_titles_; }

  // CefViewDelegate
  CefSize GetPreferredSize(CefRefPtr<CefView> view) override;
  void OnLayoutChanged(CefRefPtr<CefView> view,
                       const CefRect& new_bounds) override;
  // CefButtonDelegate
  void OnButtonPressed(CefRefPtr<CefButton> button) override;

 private:
  void SizeList();

  WindowActions* actions_;
  int width_;
  CefRefPtr<CefPanel> root_;
  CefRefPtr<CefLabelButton> space_label_;
  CefRefPtr<CefScrollView> scroll_;
  CefRefPtr<CefPanel> list_;
  CefRefPtr<CefLabelButton> new_tab_;
  // Button id -> (select target, or close target).
  std::map<int, std::string> select_ids_, close_ids_;
  std::vector<std::string> row_titles_;
  int next_id_ = 1000;
  IMPLEMENT_REFCOUNTING(SidebarView);
};

}  // namespace birch::ui

#endif  // BIRCH_UI_SIDEBAR_SIDEBAR_VIEW_H_
