// Engine-independent tab sleep and archive policy (spec/tab-lifecycle.md).
#ifndef BIRCH_CORE_LIFECYCLE_H_
#define BIRCH_CORE_LIFECYCLE_H_

#include <cstdint>
#include <string>

namespace birch::core {

enum class SleepTrigger {
  kMaintenance,
  kNormalPressure,
  kWarningPressure,
  kCriticalPressure,
  kManual,
};

struct SleepPageState {
  bool has_page = false;
  bool on_screen = false;
  bool playing_media = false;
  bool in_picture_in_picture = false;
  bool capturing_camera = false;
  bool capturing_microphone = false;
  bool loading = false;
  std::string url;
};

bool ShouldSleep(const SleepPageState& page, int64_t last_active,
                 int64_t now_seconds, double minutes, SleepTrigger trigger);
bool IsWebAddress(const std::string& url);
bool IsPastIdleLimit(int64_t last_active, int64_t now_seconds, double seconds);

}  // namespace birch::core

#endif  // BIRCH_CORE_LIFECYCLE_H_
