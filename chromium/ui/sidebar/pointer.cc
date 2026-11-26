#include "ui/sidebar/pointer.h"
#include "include/views/cef_display.h"
#if defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <X11/Xlib.h>
#include <cstdlib>
#endif
namespace birch::ui {
std::optional<CefPoint> SidebarCursor() {
#if defined(_WIN32)
  POINT point;
  if(!GetCursorPos(&point)) return std::nullopt;
  return CefDisplay::ConvertScreenPointFromPixels(CefPoint(point.x,point.y));
#elif defined(__linux__)
  // Only the local X11/XWayland display. Never connect to a remote display.
  static Display* display=[]()->Display* {
    const char* name=std::getenv("DISPLAY");
    return name && name[0]==':' ? XOpenDisplay(name) : nullptr;
  }();
  if(!display) return std::nullopt; // Native Wayland falls back to UI events.
  Window root,child;int x,y,wx,wy;unsigned mask;
  if(!XQueryPointer(display,DefaultRootWindow(display),&root,&child,&x,&y,&wx,&wy,&mask))
    return std::nullopt;
  return CefDisplay::ConvertScreenPointFromPixels(CefPoint(x,y));
#else
  return std::nullopt;
#endif
}
}
