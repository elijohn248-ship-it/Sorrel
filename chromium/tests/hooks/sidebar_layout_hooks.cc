// Native Chromium sidebar layout and pointer tests with a scratch profile.
#include "tests/hooks/hooks.h"

#include <cstdlib>
#include <string>

#include "include/views/cef_display.h"

#include "platform/platform.h"
#include "ui/main_window.h"

#if defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <X11/Xlib.h>
#endif

namespace birch::tests {
namespace {

constexpr char kArea[] = "sidebarlayout";
constexpr int kTabCount = 36;

CefRect ClientBounds() {
  return Main()->cef_window()->GetClientAreaBoundsInScreen();
}

bool MovePointer(int client_x, int client_y) {
  const auto bounds = ClientBounds();
  const auto point = CefDisplay::ConvertScreenPointToPixels(
      CefPoint(bounds.x + client_x, bounds.y + client_y));
#if defined(_WIN32)
  return SetCursorPos(point.x, point.y) != FALSE;
#elif defined(__linux__)
  const char* name = std::getenv("DISPLAY");
  Display* display = name && name[0] == ':' ? XOpenDisplay(name) : nullptr;
  if (!display) {
    return false;
  }
  const int requested = XWarpPointer(display, None, DefaultRootWindow(display),
                                     0, 0, 0, 0, point.x, point.y);
  XSync(display, False);
  XCloseDisplay(display);
  return requested != 0;
#endif
}

void MoveToPage() {
  const auto bounds = ClientBounds();
  Expect(kArea, "move the real cursor onto the page", "yes",
         YesNo(MovePointer(bounds.width * 3 / 4, bounds.height / 2)));
}

void CheckMode(const std::string& label, const std::string& mode) {
  SidebarEvalStep(label, Main, label, R"JS(
    new Promise(resolve => {
      const start = performance.now();
      function read() {
        const mode = document.body.dataset.mode;
        if (mode === ')JS" + mode + R"JS(' || performance.now() - start > 2500) {
          resolve(mode || 'missing');
        } else {
          setTimeout(read, 40);
        }
      }
      read();
    })
  )JS");
  Then("verify " + label, [label, mode] {
    Expect(kArea, label, mode, Value(label));
  });
}

void CheckLayout(const std::string& label, bool require_overflow) {
  SidebarEvalStep(label, Main, label, R"JS(
    new Promise(resolve => {
      const start = performance.now();
      function read() {
        const tabs = document.querySelector('#tabs');
        if (tabs.querySelectorAll('li.tab').length < 36 &&
            performance.now() - start < 2500) {
          setTimeout(read, 40);
          return;
        }
        const button = document.querySelector('#new-space');
        const bounds = button.getBoundingClientRect();
        const footer = document.querySelector('footer').getBoundingClientRect();
        const hit = document.elementFromPoint(
          bounds.left + bounds.width / 2, bounds.top + bounds.height / 2);
        const fits = footer.top >= 0 && footer.bottom <= innerHeight + 1 &&
          tabs.getBoundingClientRect().bottom <= footer.top + 1 &&
          button.contains(hit);
        resolve([innerHeight, Math.round(footer.bottom),
          fits ? 'fits' : 'clipped', tabs.scrollHeight > tabs.clientHeight
            ? 'scrolls' : 'no overflow'].join('|'));
      }
      read();
    })
  )JS");
  Then("verify " + label, [label, require_overflow] {
    const auto result = Value(label);
    const auto separator = result.find('|');
    Expect(kArea, label + " viewport height", std::to_string(ClientBounds().height),
           result.substr(0, separator));
    Expect(kArea, label + " footer controls within viewport", "yes",
           YesNo(result.find("|fits|") != std::string::npos));
    if (require_overflow) {
      Expect(kArea, label + " overflowing tab list scrolls", "yes",
             YesNo(EndsWith(result, "|scrolls")));
    }
  });
}

}  // namespace

BIRCH_TEST_SCENARIO(sidebarlayout) {
  Then("add background tabs without starting extra renderers", [] {
    for (int i = 0; i < kTabCount; ++i) {
      Main()->NewTab("birch://welcome", false);
    }
  });

  auto before_resize = std::make_shared<int>();
  Do("make the browser window short",
     [before_resize] {
       *before_resize = ClientBounds().height;
       Main()->cef_window()->SetSize(CefSize(900, 480));
     },
     [before_resize] { return ClientBounds().height < *before_resize; }, 5000);
  Sleep(300);  // Let the renderer apply the native viewport resize.
  CheckLayout("short window", true);
  Then("mark the short-window screenshot", [] {
    platform::Log("sidebarlayout: short screenshot");
  });
  Sleep(3500);

  Do("make the browser window taller",
     [before_resize] {
       *before_resize = ClientBounds().height;
       Main()->cef_window()->SetSize(CefSize(900, 700));
     },
     [before_resize] { return ClientBounds().height > *before_resize; }, 5000);
  Sleep(300);
  CheckLayout("taller window", true);

  Do("enter native fullscreen", [] { Main()->cef_window()->SetFullscreen(true); },
     [] { return Main()->cef_window()->IsFullscreen(); }, 5000);
  Sleep(350);
  CheckMode("pinned sidebar stays pinned in fullscreen", "pinned");
  CheckLayout("fullscreen", false);
  Then("mark the fullscreen screenshot", [] {
    platform::Log("sidebarlayout: fullscreen screenshot");
  });
  Sleep(3500);

  Do("exit native fullscreen", [] { Main()->cef_window()->SetFullscreen(false); },
     [] { return !Main()->cef_window()->IsFullscreen(); }, 5000);
  Sleep(350);
  CheckLayout("window after fullscreen", true);

  Then("park the cursor away from the sidebar", MoveToPage);
  SidebarClickStep("hide the pinned sidebar", Main, "hide", "#sidebar-mode");
  CheckMode("sidebar hides after toggle", "hidden");
  Then("move the cursor onto the window edge", [] {
    Expect(kArea, "move the real cursor to the reveal strip", "yes",
           YesNo(MovePointer(3, ClientBounds().height / 2)));
  });
  CheckMode("pointer reveals the sidebar", "peeking");

  Then("move the cursor inside the overlay", [] {
    Expect(kArea, "move the real cursor inside the overlay", "yes",
           YesNo(MovePointer(100, ClientBounds().height / 2)));
  });
  Sleep(450);
  CheckMode("sidebar stays open under the pointer", "peeking");
  CheckLayout("hover overlay", true);

  SidebarClickStep("open a dialog while peeking", Main, "open-dialog", "#new-folder");
  SidebarEvalStep("read the folder dialog state", Main, "folder-dialog",
                  "document.querySelector('#folder-editor').open");
  Then("verify the dialog opened", [] {
    Expect(kArea, "folder dialog opened", "true", Value("folder-dialog"));
  });
  Then("leave the overlay with the dialog open", MoveToPage);
  Sleep(450);
  CheckMode("open dialog holds the revealed sidebar", "peeking");
  SidebarClickStep("close the dialog", Main, "close-dialog", "#cancel-folder");
  CheckMode("sidebar hides when dialog closes off the overlay", "hidden");

  Then("return to the window edge", [] {
    Expect(kArea, "return the cursor to the reveal strip", "yes",
           YesNo(MovePointer(3, ClientBounds().height / 2)));
  });
  CheckMode("edge can reveal the sidebar again", "peeking");
  Then("return to the selected page", MoveToPage);
  CheckMode("sidebar dismisses when pointer returns to the page", "hidden");
}

}  // namespace birch::tests
