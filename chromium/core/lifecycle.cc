#include "core/lifecycle.h"

#include <algorithm>

#include "core/codec.h"

namespace birch::core {

bool ShouldSleep(const SleepPageState& page, int64_t last_active,
                 int64_t now_seconds, double minutes, SleepTrigger trigger) {
  if (!page.has_page || page.on_screen || page.playing_media ||
      page.in_picture_in_picture || page.capturing_camera ||
      page.capturing_microphone || page.loading ||
      (!page.url.empty() && !IsWebAddress(page.url))) {
    return false;
  }

  switch (trigger) {
    case SleepTrigger::kManual:
      return true;
    case SleepTrigger::kNormalPressure:
      return false;
    case SleepTrigger::kWarningPressure:
      minutes = std::min(minutes, 5.0);
      break;
    case SleepTrigger::kCriticalPressure:
      minutes = std::min(minutes, 1.0);
      break;
    case SleepTrigger::kMaintenance:
      break;
  }
  return IsPastIdleLimit(last_active, now_seconds, minutes * 60);
}

bool IsWebAddress(const std::string& url) {
  return StartsWithNoCase(url, "http:") || StartsWithNoCase(url, "https:");
}

bool IsPastIdleLimit(int64_t last_active, int64_t now_seconds, double seconds) {
  return seconds > 0 &&
         static_cast<double>(last_active) < static_cast<double>(now_seconds) - seconds;
}

}  // namespace birch::core
