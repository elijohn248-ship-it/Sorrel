// Downloads: saved straight into the Downloads folder (no dialog), under a
// free, safe file name. Chromium itself writes Windows' Mark of the Web
// (Zone.Identifier, ZoneId=3) and Linux's origin attributes; for a private
// window's download Birch then removes the source and referrer addresses and
// keeps only "from the Internet", so nothing on disk records where a private
// download came from. Owner: wave-3 agent 8 (downloads list and Library).
#include "include/cef_download_handler.h"

#include "core/codec.h"
#include "engine/cef/internal.h"
#include "engine/engine.h"
#include "platform/platform.h"

namespace birch::engine {

namespace {

std::function<void(const DownloadEvent&)>& Listener() {
  static std::function<void(const DownloadEvent&)> listener;
  return listener;
}

// Keeps letters (any script), digits and . - _ ( ) space; anything that could
// form a path, a device name or a hidden file is replaced.
std::string SafeFileName(const std::string& suggested) {
  std::string out;
  for (unsigned char c : suggested) {
    bool ok = c >= 0x80 || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' ||
              c == ' ' || c == '(' || c == ')';
    out += ok ? static_cast<char>(c) : '_';
  }
  while (!out.empty() && (out.back() == '.' || out.back() == ' ')) {
    out.pop_back();  // Windows drops trailing dots and spaces
  }
  if (out.empty() || out[0] == '.') {
    out = "download" + out;
  }
  // Reserved Windows device names (CON, NUL, COM1, …) get a prefix.
  std::string stem = core::ToLowerAscii(out.substr(0, out.find('.')));
  for (const char* dev : {"con", "prn", "aux", "nul", "com1", "com2", "com3",
                          "com4", "com5", "com6", "com7", "com8", "com9",
                          "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
                          "lpt7", "lpt8", "lpt9"}) {
    if (stem == dev) {
      out = "_" + out;
      break;
    }
  }
  return out.substr(0, 200);
}

std::string Compact(const std::string& mark) {
  std::string out;
  for (char c : mark) {
    out += c == '\r' ? ' ' : (c == '\n' ? '|' : c);
  }
  return out;
}

}  // namespace

void SetDownloadListener(std::function<void(const DownloadEvent&)> listener) {
  Listener() = std::move(listener);
}

bool HandleBeforeDownload(CefRefPtr<CefBrowser>, bool is_private,
                          CefRefPtr<CefDownloadItem> item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) {
  std::string dir = platform::DownloadsDir();
  core::MakeDirectories(dir);
  std::string path =
      platform::UniqueFilePath(dir, SafeFileName(suggested_name.ToString()));
  platform::Log("download: start id=" + std::to_string(item->GetId()) +
                (is_private ? " private" : " normal") +
                " file=" + path.substr(dir.size()));
  callback->Continue(path, /*show_dialog=*/false);
  return true;
}

void HandleDownloadUpdated(bool is_private, CefRefPtr<CefDownloadItem> item) {
  bool complete = item->IsComplete();
  bool failed = item->IsCanceled() || item->IsInterrupted();
  if (!complete && !failed) {
    return;
  }
  DownloadEvent ev;
  ev.id = item->GetId();
  ev.path = item->GetFullPath().ToString();
  ev.complete = complete;
  ev.failed = failed && !complete;
  ev.is_private = is_private;
  ev.bytes = item->GetReceivedBytes();
  if (complete) {
    std::string mark = platform::ReadDownloadMark(ev.path);
#if defined(_WIN32)
    ev.mark_written_by_chromium = mark.find("ZoneId=3") != std::string::npos;
#else
    ev.mark_written_by_chromium = !mark.empty();
#endif
    platform::Log("motw: chromium-wrote=" +
                  std::string(ev.mark_written_by_chromium ? "yes" : "no") +
                  " stream=" + Compact(mark));
#if defined(_WIN32)
    if (!ev.mark_written_by_chromium && !is_private) {
      // Fallback: a download must never lose its Internet-zone mark.
      bool ok = platform::StripDownloadOrigin(ev.path);
      platform::Log(std::string("motw: fallback mark written=") +
                    (ok ? "yes" : "no"));
    }
#endif
    if (is_private) {
      bool ok = platform::StripDownloadOrigin(ev.path);
      platform::Log(std::string("motw: private origin stripped=") +
                    (ok ? "yes" : "no"));
    }
    ev.mark = platform::ReadDownloadMark(ev.path);
  }
  platform::Log("download: " + std::string(complete ? "complete" : "failed") +
                " id=" + std::to_string(ev.id) +
                " bytes=" + std::to_string(ev.bytes) +
                " mark=" + Compact(ev.mark));
  if (Listener()) {
    Listener()(ev);
  }
}

}  // namespace birch::engine
