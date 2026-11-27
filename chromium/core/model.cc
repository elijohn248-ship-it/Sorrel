#include "core/model.h"

#include "core/codec.h"
#include "core/site.h"

namespace birch::core {

const std::vector<Theme>& Theme::Presets() {
  static const std::vector<Theme> kPresets = [] {
    auto t = [](std::vector<std::string> colors, double angle,
                double intensity, std::optional<double> grain = std::nullopt) {
      Theme theme;
      theme.colors = std::move(colors);
      theme.angle = angle;
      theme.intensity = intensity;
      theme.grain = grain;
      return theme;
    };
    return std::vector<Theme>{
        t({"#8978F9", "#6CBAD9"}, 315, 0.8),
        t({"#34E895"}, 300, 0.8),
        t({"#FE6F3E"}, 320, 0.8),
        t({"#F1535A"}, 320, 0.8, 0.65),
        t({"#6CBAD9"}, 300, 0.85),
        t({"#E8F978", "#8978F9"}, 315, 0.85),
        t({"#F8D558", "#658AFA"}, 315, 0.85),
        t({"#DEDA31"}, 300, 0.78),
        t({"#2B3A67", "#51407A"}, 315, 0.95),
        t({"#F2EAE4", "#E2F1F1"}, 315, 1),
    };
  }();
  return kPresets;
}

std::vector<double> SplitLayout::Normalized(size_t count) const {
  if (count == 0) {
    return {};
  }
  bool usable = fractions.size() == count;
  double total = 0;
  for (double f : fractions) {
    usable = usable && f > 0;
    total += f;
  }
  if (!usable) {
    return std::vector<double>(count, 1.0 / static_cast<double>(count));
  }
  std::vector<double> out;
  for (double f : fractions) {
    out.push_back(f / total);
  }
  return out;
}

std::string Item::DisplayTitle() const {
  if (IsSplit()) {
    std::string joined;
    for (size_t i = 0; i < children.size(); ++i) {
      joined += (i ? " | " : "") + children[i].DisplayTitle();
    }
    return joined;
  }
  if (custom_title && !custom_title->empty()) {
    return *custom_title;
  }
  if (!title.empty()) {
    return title;
  }
  if (is_folder) {
    return "Folder";
  }
  if (std::optional<std::string> h = Host()) {
    return *h;
  }
  return "New Tab";
}

std::optional<std::string> Item::Host() const {
  if (!url) {
    return std::nullopt;
  }
  return UrlHost(*url);
}

Item Item::NewTab(const std::string& url, const std::string& title) {
  Item item;
  item.id = NewUuid();
  item.url = url;
  item.title = title;
  item.last_active = NowSeconds();
  return item;
}

namespace bundled_page {

namespace {
const char* const kOldPrefixes[] = {"sorrel://", "drift://"};
}

bool IsBundled(const std::string& address) {
  if (StartsWith(address, kPrefix)) {
    return true;
  }
  for (const char* old : kOldPrefixes) {
    if (StartsWith(address, old)) {
      return true;
    }
  }
  return false;
}

std::string Current(const std::string& address) {
  for (const char* old : kOldPrefixes) {
    std::string p = old;
    if (StartsWith(address, p)) {
      return kPrefix + address.substr(p.size());
    }
  }
  return address;
}

std::string Saved(const std::string& address) {
  std::string out = Current(address);
  if (StartsWith(out, kPrefix) && out.size() > sizeof(kPrefix) &&
      out.back() == '/' &&
      out.find('/', sizeof(kPrefix) - 1) == out.size() - 1) {
    out.pop_back();
  }
  return out;
}

bool PlainNameAllowed(const std::string& name) {
  if (name.empty()) {
    return false;
  }
  for (char c : name) {
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) {
      return false;
    }
  }
  return true;
}

}  // namespace bundled_page

}  // namespace birch::core
