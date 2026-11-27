#ifndef BIRCH_CORE_COMMANDS_H_
#define BIRCH_CORE_COMMANDS_H_

#include <vector>

namespace birch::core {

struct CommandInfo {
  const char* id;
  const char* title;
};

// All 87 command ids and titles of spec/keybindings.md, in the Mac's order.
const std::vector<CommandInfo>& AllCommands();

}  // namespace birch::core

#endif  // BIRCH_CORE_COMMANDS_H_
