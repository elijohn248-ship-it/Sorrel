#include "core/codec.h"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>
#include <system_error>

namespace birch::core {

namespace {

namespace fs = std::filesystem;

fs::path PathFromUtf8(const std::string& s) {
#if defined(__cpp_char8_t)
  return fs::path(std::u8string(s.begin(), s.end()));
#else
  return fs::u8path(s);
#endif
}

bool IsHex(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
         (c >= 'A' && c <= 'F');
}

bool Digits(const std::string& s, size_t pos, size_t count, int* out) {
  if (pos + count > s.size()) {
    return false;
  }
  int v = 0;
  for (size_t i = pos; i < pos + count; ++i) {
    if (s[i] < '0' || s[i] > '9') {
      return false;
    }
    v = v * 10 + (s[i] - '0');
  }
  *out = v;
  return true;
}

// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's
// days_from_civil).
int64_t DaysFromCivil(int64_t y, unsigned m, unsigned d) {
  y -= m <= 2 ? 1 : 0;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned mp = m > 2 ? m - 3 : m + 9;
  const unsigned doy = (153 * mp + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + static_cast<int64_t>(doe) - 719468;
}

void CivilFromDays(int64_t z, int64_t* y, unsigned* m, unsigned* d) {
  z += 719468;
  const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const unsigned doe = static_cast<unsigned>(z - era * 146097);
  const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int64_t yy = static_cast<int64_t>(yoe) + era * 400;
  const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const unsigned mp = (5 * doy + 2) / 153;
  *d = doy - (153 * mp + 2) / 5 + 1;
  *m = mp < 10 ? mp + 3 : mp - 9;
  *y = yy + (*m <= 2 ? 1 : 0);
}

bool IsLeap(int y) {
  return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

int DaysInMonth(int y, int m) {
  static const int kDays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return m == 2 && IsLeap(y) ? 29 : kDays[m - 1];
}

}  // namespace

std::string ToLowerAscii(std::string s) {
  for (char& c : s) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return s;
}

bool StartsWith(const std::string& s, const std::string& prefix) {
  return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool EndsWith(const std::string& s, const std::string& suffix) {
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool StartsWithNoCase(const std::string& s, const std::string& prefix) {
  return s.size() >= prefix.size() &&
         ToLowerAscii(s.substr(0, prefix.size())) == ToLowerAscii(prefix);
}

std::string TrimSpaces(const std::string& s) {
  size_t b = 0;
  size_t e = s.size();
  while (b < e && (s[b] == ' ' || s[b] == '\t')) {
    ++b;
  }
  while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t')) {
    --e;
  }
  return s.substr(b, e - b);
}

std::vector<std::string> Split(const std::string& s, char sep) {
  std::vector<std::string> out;
  size_t start = 0;
  while (true) {
    size_t pos = s.find(sep, start);
    if (pos == std::string::npos) {
      out.push_back(s.substr(start));
      return out;
    }
    out.push_back(s.substr(start, pos - start));
    start = pos + 1;
  }
}

bool ParseUuid(const std::string& in, std::string* upper) {
  if (in.size() != 36) {
    return false;
  }
  std::string out = in;
  for (size_t i = 0; i < in.size(); ++i) {
    bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? in[i] != '-' : !IsHex(in[i])) {
      return false;
    }
    if (in[i] >= 'a' && in[i] <= 'f') {
      out[i] = static_cast<char>(in[i] - 'a' + 'A');
    }
  }
  *upper = out;
  return true;
}

std::string NewUuid() {
  std::random_device rd;
  unsigned char b[16];
  for (size_t i = 0; i < 16; i += 4) {
    uint32_t r = rd();
    for (size_t j = 0; j < 4; ++j) {
      b[i + j] = static_cast<unsigned char>((r >> (8 * j)) & 0xFF);
    }
  }
  b[6] = static_cast<unsigned char>((b[6] & 0x0F) | 0x40);  // version 4
  b[8] = static_cast<unsigned char>((b[8] & 0x3F) | 0x80);  // RFC 4122 variant
  static const char kHex[] = "0123456789ABCDEF";
  std::string out;
  for (size_t i = 0; i < 16; ++i) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      out += '-';
    }
    out += kHex[b[i] >> 4];
    out += kHex[b[i] & 0x0F];
  }
  return out;
}

bool ParseIso8601(const std::string& s, int64_t* seconds) {
  int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
  if (!Digits(s, 0, 4, &y) || s.size() < 19 || s[4] != '-' ||
      !Digits(s, 5, 2, &mo) || s[7] != '-' || !Digits(s, 8, 2, &d) ||
      (s[10] != 'T' && s[10] != 't') || !Digits(s, 11, 2, &h) ||
      s[13] != ':' || !Digits(s, 14, 2, &mi) || s[16] != ':' ||
      !Digits(s, 17, 2, &se)) {
    return false;
  }
  if (mo < 1 || mo > 12 || d < 1 || d > DaysInMonth(y, mo) || h > 23 ||
      mi > 59 || se > 59) {
    return false;
  }
  size_t i = 19;
  if (i < s.size() && s[i] == '.') {
    ++i;
    size_t digits = 0;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') {
      ++i;
      ++digits;
    }
    if (digits == 0) {
      return false;
    }
  }
  int offset = 0;
  if (i < s.size() && (s[i] == 'Z' || s[i] == 'z')) {
    ++i;
  } else if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
    int sign = s[i] == '-' ? -1 : 1;
    int oh = 0, om = 0;
    ++i;
    if (!Digits(s, i, 2, &oh)) {
      return false;
    }
    i += 2;
    if (i < s.size() && s[i] == ':') {
      ++i;
    }
    if (!Digits(s, i, 2, &om)) {
      return false;
    }
    i += 2;
    if (oh > 23 || om > 59) {
      return false;
    }
    offset = sign * (oh * 3600 + om * 60);
  } else {
    return false;  // a time zone is required
  }
  if (i != s.size()) {
    return false;
  }
  int64_t days = DaysFromCivil(y, static_cast<unsigned>(mo),
                               static_cast<unsigned>(d));
  *seconds = days * 86400 + h * 3600 + mi * 60 + se - offset;
  return true;
}

std::string FormatIso8601(int64_t seconds) {
  int64_t days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400;
  int64_t rem = seconds - days * 86400;
  int64_t y = 0;
  unsigned m = 0, d = 0;
  CivilFromDays(days, &y, &m, &d);
  char buf[128];  // roomy enough for GCC's worst-case format check
  std::snprintf(buf, sizeof(buf), "%04lld-%02u-%02uT%02lld:%02lld:%02lldZ",
                static_cast<long long>(y), m, d,
                static_cast<long long>(rem / 3600),
                static_cast<long long>((rem / 60) % 60),
                static_cast<long long>(rem % 60));
  return buf;
}

int64_t NowSeconds() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string JoinPath(const std::string& dir, const std::string& name) {
  if (dir.empty()) {
    return name;
  }
  char last = dir.back();
  if (last == '/' || last == '\\') {
    return dir + name;
  }
#if defined(_WIN32)
  return dir + "\\" + name;
#else
  return dir + "/" + name;
#endif
}

bool FileExists(const std::string& path) {
  std::error_code ec;
  return fs::exists(PathFromUtf8(path), ec);
}

bool ReadFileUtf8Path(const std::string& path, std::string* data) {
  std::ifstream in(PathFromUtf8(path), std::ios::binary);
  if (!in) {
    return false;
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  *data = ss.str();
  return !in.bad();
}

bool WriteFileAtomic(const std::string& path, const std::string& data) {
  fs::path target = PathFromUtf8(path);
  fs::path tmp = PathFromUtf8(path + ".tmp");
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    if (!out) {
      return false;
    }
    out.write(data.data(), static_cast<std::streamsize>(data.size()));
    out.flush();
    if (!out) {
      return false;
    }
  }
  std::error_code ec;
  fs::rename(tmp, target, ec);  // replaces an existing file on every OS
  if (ec) {
    fs::remove(tmp, ec);
    return false;
  }
  return true;
}

bool AppendFileUtf8Path(const std::string& path, const std::string& data) {
  std::ofstream out(PathFromUtf8(path), std::ios::binary | std::ios::app);
  if (!out) {
    return false;
  }
  out.write(data.data(), static_cast<std::streamsize>(data.size()));
  return static_cast<bool>(out);
}

bool CopyFileUtf8Path(const std::string& from, const std::string& to) {
  std::error_code ec;
  return fs::copy_file(PathFromUtf8(from), PathFromUtf8(to),
                       fs::copy_options::overwrite_existing, ec);
}

bool MakeDirectories(const std::string& path) {
  std::error_code ec;
  fs::create_directories(PathFromUtf8(path), ec);
  return !ec || fs::is_directory(PathFromUtf8(path), ec);
}

std::vector<std::string> ListDirectory(const std::string& dir) {
  std::vector<std::string> out;
  std::error_code ec;
  fs::directory_iterator it(PathFromUtf8(dir), ec);
  for (; !ec && it != fs::directory_iterator(); it.increment(ec)) {
#if defined(__cpp_char8_t)
    std::u8string name = it->path().filename().u8string();
    out.emplace_back(name.begin(), name.end());
#else
    out.push_back(it->path().filename().u8string());
#endif
  }
  return out;
}

}  // namespace birch::core
