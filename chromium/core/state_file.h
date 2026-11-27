// state.json: decoding and encoding exactly as spec/saved-data.md ▸
// state.json describes (fixtures: state-decode, state-derived), plus the
// launch rule (unreadable file -> backup + fresh profile) and atomic saving.
#ifndef BIRCH_CORE_STATE_FILE_H_
#define BIRCH_CORE_STATE_FILE_H_

#include <string>
#include <vector>

#include "core/model.h"

namespace birch::core {

inline constexpr const char kStateFileName[] = "state.json";

// Decodes state.json text. Every non-optional key is required; one bad value
// fails the whole file (|error| says what and where, in the Mac's words:
// "keyNotFound <key> at <path>", "typeMismatch <Type> at <path>",
// "dataCorrupted at <path>").
bool DecodeAppState(const std::string& text, AppState* out, std::string* error);
// Pretty-printed JSON; optional values that are absent are left out.
std::string EncodeAppState(const AppState& state);
// Single items, for tests and future import code.
bool DecodeItem(const std::string& json_text, Item* out, std::string* error);

// A fresh profile: one space "Home" (🏠, theme preset 0) with the welcome page
// open and selected; no favorites.
AppState SeedState();

struct LaunchState {
  AppState state;
  bool used_file = false;    // false: seeded a fresh profile
  bool file_existed = false;
  std::string backup_path;   // set when an unreadable file was kept aside
  std::string decode_error;
};
// Reads <profile_dir>/state.json. A file that fails to decode, or decodes
// with no spaces, is copied to state.unreadable-<unix seconds>.json and a
// fresh profile is used; a file is never silently discarded.
LaunchState LoadStateOnLaunch(const std::string& profile_dir);
bool SaveState(const std::string& profile_dir, const AppState& state);

}  // namespace birch::core

#endif  // BIRCH_CORE_STATE_FILE_H_
