// Native corner masks over the page card. No scripts or extra browser views.
#ifndef BIRCH_UI_ROUNDED_CARD_H_
#define BIRCH_UI_ROUNDED_CARD_H_

#include <array>

#include "include/views/cef_label_button.h"
#include "include/views/cef_overlay_controller.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_window.h"

namespace birch::ui {

class RoundedCard {
 public:
  RoundedCard();
  ~RoundedCard();
  CefRefPtr<CefPanel> view() const { return panel_; }
  void Attach(CefRefPtr<CefWindow> window);
  void SetColor(cef_color_t color);
  void Layout();

 private:
  class Delegate;
  CefRefPtr<Delegate> delegate_;
  CefRefPtr<CefPanel> panel_;
  std::array<CefRefPtr<CefLabelButton>, 4> masks_;
  std::array<CefRefPtr<CefOverlayController>, 4> overlays_;
};

}  // namespace birch::ui
#endif
