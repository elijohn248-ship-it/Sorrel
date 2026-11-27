// Spec fixtures for the command bar's pure parts (wave 3, agent 6): resolver,
// bangs, keybindings and tab-recency. Each Run* turns a fixture's cases into
// (expected, got) pairs for spec_runner.cc to report.
#ifndef BIRCH_TESTS_SPEC_COMMANDBAR_SPEC_H_
#define BIRCH_TESTS_SPEC_COMMANDBAR_SPEC_H_

#include <string>
#include <vector>

#include "core/json.h"

namespace birch::core::spec {

struct CaseOut {
  std::string name;
  Json expected, got;
  bool informative = false;
  std::string note;
};

// |fixtures_dir| = spec/fixtures; the bundled bangs are ../../Resources/bangs.json.
void SetFixturesDir(const std::string& fixtures_dir);
std::vector<CaseOut> RunResolver(const Json& doc);
std::vector<CaseOut> RunBangs(const Json& doc);
std::vector<CaseOut> RunKeybindings(const Json& doc);
std::vector<CaseOut> RunTabRecency(const Json& doc);

}  // namespace birch::core::spec

#endif  // BIRCH_TESTS_SPEC_COMMANDBAR_SPEC_H_
