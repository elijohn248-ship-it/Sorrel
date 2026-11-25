// Small engine-free helpers shared by core/: ASCII string utilities, UUIDs,
// ISO 8601 dates and files addressed by UTF-8 paths. See spec/saved-data.md ▸
// Common encoding rules.
#ifndef BIRCH_CORE_CODEC_H_
#define BIRCH_CORE_CODEC_H_

#include <cstdint>
#include <string>
#include <vector>

namespace birch::core {

// ---- strings (ASCII only; UTF-8 bytes >= 0x80 are left alone) ---------------
std::string ToLowerAscii(std::string s);
bool StartsWith(const std::string& s, const std::string& prefix);
bool EndsWith(const std::string& s, const std::string& suffix);
bool StartsWithNoCase(const std::string& s, const std::string& prefix);
// Removes leading/trailing spaces and tabs (Swift's .whitespaces for ASCII).
std::string TrimSpaces(const std::string& s);
std::vector<std::string> Split(const std::string& s, char sep);

// ---- UUIDs: written uppercase, read in either case ---------------------------
// True when |in| is 8-4-4-4-12 hex digits; |upper| gets the uppercase form.
bool ParseUuid(const std::string& in, std::string* upper);
// A random (version 4) UUID, uppercase.
std::string NewUuid();

// ---- dates: whole seconds since 1970-01-01T00:00:00Z ---------------------------
// Accepts "YYYY-MM-DDTHH:MM:SS" + optional ".fraction" + "Z" or "±HH:MM" /
// "±HHMM". Fractions are dropped (rounded toward the past), as the Mac does.
bool ParseIso8601(const std::string& in, int64_t* seconds);
// "2026-11-20T09:30:00Z"
std::string FormatIso8601(int64_t seconds);
int64_t NowSeconds();

// ---- files, addressed by UTF-8 paths on every OS -------------------------------
std::string JoinPath(const std::string& dir, const std::string& name);
bool FileExists(const std::string& path);
bool ReadFileUtf8Path(const std::string& path, std::string* data);
// Writes to "<path>.tmp" and renames it over |path|, so a crash never leaves
// a half-written file.
bool WriteFileAtomic(const std::string& path, const std::string& data);
bool AppendFileUtf8Path(const std::string& path, const std::string& data);
bool CopyFileUtf8Path(const std::string& from, const std::string& to);
bool MakeDirectories(const std::string& path);
// File and folder names directly inside |dir| (empty when unreadable).
std::vector<std::string> ListDirectory(const std::string& dir);

}  // namespace birch::core

#endif  // BIRCH_CORE_CODEC_H_
