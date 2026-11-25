#include "ui/sidebar/sidebar_view.h"

#include "include/views/cef_box_layout.h"

namespace birch::ui {

namespace {

constexpr int kNewTabId = 1;
constexpr cef_color_t kSelected = CefColorSetARGB(0x26, 0x50, 0x40, 0xC0);
constexpr cef_color_t kClear = CefColorSetARGB(0, 0, 0, 0);

std::string Indent(int depth) {
  std::string s;
  for (int i = 0; i < depth; ++i) {
    s += "    ";
  }
  return s;
}

}  // namespace

SidebarView::SidebarView(WindowActions* actions, int width, bool is_private)
    : actions_(actions), width_(width) {
  root_ = CefPanel::CreatePanel(static_cast<CefPanelDelegate*>(this));
  CefBoxLayoutSettings column;
  column.horizontal = false;
  column.between_child_spacing = 6;
  column.inside_border_insets = {8, 8, 8, 8};
  CefRefPtr<CefBoxLayout> layout = root_->SetToBoxLayout(column);

  space_label_ = CefLabelButton::CreateLabelButton(this, is_private ? "Private" : "");
  space_label_->SetEnabled(false);
  space_label_->SetHorizontalAlignment(CEF_HORIZONTAL_ALIGNMENT_LEFT);

  scroll_ = CefScrollView::CreateScrollView(
      static_cast<CefPanelDelegate*>(this));
  list_ = CefPanel::CreatePanel(nullptr);
  CefBoxLayoutSettings rows;
  rows.horizontal = false;
  rows.between_child_spacing = 1;
  list_->SetToBoxLayout(rows);
  scroll_->SetContentView(list_);

  new_tab_ = CefLabelButton::CreateLabelButton(this, "+  New Tab");
  new_tab_->SetID(kNewTabId);
  new_tab_->SetHorizontalAlignment(CEF_HORIZONTAL_ALIGNMENT_LEFT);
  new_tab_->SetAccessibleName("New Tab");

  root_->AddChildView(space_label_);
  root_->AddChildView(scroll_);
  root_->AddChildView(new_tab_);
  layout->SetFlexForView(scroll_, 1);
}

void SidebarView::SetHeader(CefRefPtr<CefView> header) {
  root_->AddChildViewAt(header, 0);
}

void SidebarView::Rebuild(const std::string& space_title,
                          const std::vector<core::SidebarRow>& rows,
                          const std::string& selected_id) {
  if (!space_title.empty()) {
    space_label_->SetText(space_title);
  }
  list_->RemoveAllChildViews();
  select_ids_.clear();
  close_ids_.clear();
  row_titles_.clear();
  for (const core::SidebarRow& r : rows) {
    if (r.kind == core::SidebarRow::Kind::kSeparator) {
      CefRefPtr<CefPanel> sep = CefPanel::CreatePanel(nullptr);
      sep->SetToBoxLayout(CefBoxLayoutSettings());
      CefRefPtr<CefLabelButton> line =
          CefLabelButton::CreateLabelButton(this, "");
      line->SetEnabled(false);
      sep->AddChildView(line);
      list_->AddChildView(sep);
      continue;
    }
    CefRefPtr<CefPanel> row = CefPanel::CreatePanel(nullptr);
    CefBoxLayoutSettings h;
    h.horizontal = true;
    CefRefPtr<CefBoxLayout> hl = row->SetToBoxLayout(h);
    std::string prefix = Indent(r.depth);
    if (r.kind == core::SidebarRow::Kind::kFolder) {
      prefix += "\xE2\x96\xB8 ";  // ▸
    } else if (r.kind == core::SidebarRow::Kind::kFavorite) {
      prefix += "\xE2\x98\x85 ";  // ★
    }
    CefRefPtr<CefLabelButton> title =
        CefLabelButton::CreateLabelButton(this, prefix + r.title);
    title->SetHorizontalAlignment(CEF_HORIZONTAL_ALIGNMENT_LEFT);
    title->SetAccessibleName(r.title);
    title->SetTooltipText(r.title);
    row->AddChildView(title);
    hl->SetFlexForView(title, 1);
    if (!r.target_id.empty()) {
      int id = next_id_++;
      title->SetID(id);
      select_ids_[id] = r.target_id;
      row_titles_.push_back(r.title);
      bool closable = r.kind == core::SidebarRow::Kind::kToday ||
                      r.kind == core::SidebarRow::Kind::kSplit;
      if (closable) {
        CefRefPtr<CefLabelButton> close =
            CefLabelButton::CreateLabelButton(this, "\xC3\x97");  // ×
        int cid = next_id_++;
        close->SetID(cid);
        close->SetAccessibleName("Close " + r.title);
        close->SetTooltipText("Close Tab");
        close_ids_[cid] = r.target_id;
        row->AddChildView(close);
      }
    } else {
      title->SetEnabled(false);
    }
    bool selected = !selected_id.empty() && r.target_id == selected_id;
    row->SetBackgroundColor(selected ? kSelected : kClear);
    list_->AddChildView(row);
  }
  SizeList();
}

void SidebarView::SizeList() {
  int width = scroll_->GetBounds().width - scroll_->GetVerticalScrollbarWidth();
  if (width <= 0) {
    width = width_ - 16;
  }
  CefSize preferred = list_->GetPreferredSize();
  list_->SetSize(CefSize(width, preferred.height));
  list_->Layout();
}

CefSize SidebarView::GetPreferredSize(CefRefPtr<CefView> view) {
  if (view->IsSame(root_)) {
    return CefSize(width_, 0);
  }
  return CefSize();  // everything else: its own preferred size
}

void SidebarView::OnLayoutChanged(CefRefPtr<CefView> view, const CefRect&) {
  if (view->IsSame(scroll_)) {
    SizeList();
  }
}

void SidebarView::OnButtonPressed(CefRefPtr<CefButton> button) {
  int id = button->GetID();
  if (id == kNewTabId) {
    actions_->StartNewTab();
    return;
  }
  auto close = close_ids_.find(id);
  if (close != close_ids_.end()) {
    std::string target = close->second;
    actions_->CloseTab(target);
    return;
  }
  auto select = select_ids_.find(id);
  if (select != select_ids_.end()) {
    std::string target = select->second;
    actions_->SelectTab(target);
  }
}

}  // namespace birch::ui
