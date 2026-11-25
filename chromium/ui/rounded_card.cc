#include "ui/rounded_card.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "include/views/cef_panel_delegate.h"

namespace birch::ui {
namespace {
constexpr int kRadius = 12;

CefRefPtr<CefImage> Corner(cef_color_t color, int corner) {
  auto image = CefImage::CreateImage();
  for (int scale : {1, 2}) {
    int side = kRadius * scale;
    std::vector<unsigned char> rgba(static_cast<size_t>(side * side * 4));
    for (int y = 0; y < side; ++y) {
      for (int x = 0; x < side; ++x) {
        double dx = (corner & 1) ? x + 0.5 : side - x - 0.5;
        double dy = (corner & 2) ? y + 0.5 : side - y - 0.5;
        double alpha = std::clamp(std::hypot(dx, dy) - side + 0.5, 0.0, 1.0);
        size_t i = static_cast<size_t>((y * side + x) * 4);
        rgba[i] = static_cast<unsigned char>(CefColorGetR(color));
        rgba[i + 1] = static_cast<unsigned char>(CefColorGetG(color));
        rgba[i + 2] = static_cast<unsigned char>(CefColorGetB(color));
        rgba[i + 3] = static_cast<unsigned char>(std::lround(255 * alpha));
      }
    }
    image->AddBitmap(static_cast<float>(scale), side, side,
                     CEF_COLOR_TYPE_RGBA_8888, CEF_ALPHA_TYPE_POSTMULTIPLIED,
                     rgba.data(), rgba.size());
  }
  return image;
}
}  // namespace

class RoundedCard::Delegate : public CefPanelDelegate {
 public:
  explicit Delegate(RoundedCard* owner) : owner_(owner) {}
  void Detach() { owner_ = nullptr; }
  void OnLayoutChanged(CefRefPtr<CefView>, const CefRect&) override {
    if (owner_) owner_->Layout();
  }
 private:
  RoundedCard* owner_;
  IMPLEMENT_REFCOUNTING(Delegate);
};

RoundedCard::RoundedCard() : delegate_(new Delegate(this)) {
  panel_ = CefPanel::CreatePanel(delegate_);
  panel_->SetToFillLayout();
}

RoundedCard::~RoundedCard() {
  delegate_->Detach();
  for (auto& overlay : overlays_) {
    if (overlay && overlay->IsValid()) overlay->Destroy();
  }
}

void RoundedCard::Attach(CefRefPtr<CefWindow> window) {
  for (size_t i = 0; i < masks_.size(); ++i) {
    // CEF's image-bearing view is a LabelButton. Keep these decorative views
    // disabled, unfocusable and non-activating; they execute no actions.
    masks_[i] = CefLabelButton::CreateLabelButton(nullptr, "");
    masks_[i]->SetEnabled(false);
    masks_[i]->SetFocusable(false);
    masks_[i]->SetInkDropEnabled(false);
    masks_[i]->SetMinimumSize(CefSize(kRadius, kRadius));
    masks_[i]->SetMaximumSize(CefSize(kRadius, kRadius));
    masks_[i]->SetBackgroundColor(CefColorSetARGB(0, 0, 0, 0));
    overlays_[i] = window->AddOverlayView(masks_[i], CEF_DOCKING_MODE_CUSTOM,
                                         false);
  }
  Layout();
}

void RoundedCard::SetColor(cef_color_t color) {
  for (size_t i = 0; i < masks_.size(); ++i) {
    if (masks_[i]) {
      masks_[i]->SetImage(CEF_BUTTON_STATE_DISABLED,
                          Corner(color, static_cast<int>(i)));
    }
  }
}

void RoundedCard::Layout() {
  CefPoint origin(0, 0);
  CefSize size = panel_->GetSize();
  bool show = size.width >= 2 * kRadius && size.height >= 2 * kRadius &&
              panel_->ConvertPointToWindow(origin);
  for (size_t i = 0; i < overlays_.size(); ++i) {
    if (!overlays_[i] || !overlays_[i]->IsValid()) continue;
    if (show) {
      int x = origin.x + ((i & 1) ? size.width - kRadius : 0);
      int y = origin.y + ((i & 2) ? size.height - kRadius : 0);
      overlays_[i]->SetBounds(CefRect(x, y, kRadius, kRadius));
    }
    overlays_[i]->SetVisible(show);
  }
}
}  // namespace birch::ui
