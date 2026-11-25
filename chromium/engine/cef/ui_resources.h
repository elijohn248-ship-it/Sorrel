// Birch's own UI pages (chromium/ui/web/), compiled into the app by
// tools/embed_ui.py. Only engine/cef/ui_scheme.cc reads them.
#ifndef BIRCH_ENGINE_CEF_UI_RESOURCES_H_
#define BIRCH_ENGINE_CEF_UI_RESOURCES_H_

#include <cstddef>
#include <string>

namespace birch::engine::ui_resources {

struct Resource {
  const char* path;  // relative to ui/web/, e.g. "sidebar/index.html"
  const unsigned char* data;
  size_t size;
  const char* mime;
};

// nullptr when there is no such file.
const Resource* Find(const std::string& path);
size_t Count();

}  // namespace birch::engine::ui_resources

#endif  // BIRCH_ENGINE_CEF_UI_RESOURCES_H_
