// Native screen cursor in CEF DIP coordinates. No page data or persistence.
#pragma once
#include <optional>
#include "include/internal/cef_types_wrappers.h"
namespace birch::ui { std::optional<CefPoint> SidebarCursor(); }
