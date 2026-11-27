#pragma once
#include <functional>
#include <memory>
#include <string>
#include "core/json.h"
namespace birch::ui {
// One updater per application. Linux helper verifies all security decisions;
// the UI supplies only check/install verbs, never URLs, keys or file paths.
class UpdateHost {
 public:
  explicit UpdateHost(std::function<void()> changed);
  ~UpdateHost();
  void Check();
  void Install();
  void CancelCheck();
  bool installing() const { return busy_ && operation_=="install"; }
  std::string Status() const { return status_.dump(); }
 private:
  struct Job;
  struct Life { UpdateHost* owner; };
  void Start(const std::string& operation);
  void Poll();
  std::function<void()> changed_;
  std::shared_ptr<Job> job_;
  std::shared_ptr<Life> life_;
  core::Json status_;
  std::string operation_, helper_;
  bool supported_=false,busy_=false;
};
}
