#!/usr/bin/env python3
"""Read kernel memory counters for explicit PIDs; never inspect browser content.

Usage: python3 tools/memory-sample.py main=123 content=456 gpu=789
       python3 tools/memory-sample.py --group 123
Outputs JSON lines. No URLs, titles, command arguments, or profile reads.
Group mode discovers WebKit executables in the main PID's two coalitions.
Footprints are process accounting charges, not an exact per-tab allocation.
"""
import ctypes
import errno
import json
import subprocess
import sys
import time


class Usage(ctypes.Structure):
    # SDK sys/resource.h: rusage_info_v0, stable since macOS 10.9.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "idle_wakeups", "interrupt_wakeups",
            "pageins", "wired", "resident", "footprint", "start", "exit")]


def coalition(lib, pid):
    # Diagnostic-only private query from Apple's xnu/bsd/sys/proc_info_private.h.
    # Two coalition types plus three reserved uint64s. Refuse mismatched ABI.
    ids = (ctypes.c_uint64 * 5)()
    size = ctypes.sizeof(ids)
    if lib.proc_pidinfo(pid, 20, 0, ctypes.byref(ids), size) != size:
        raise OSError(ctypes.get_errno(), "coalition unavailable")
    return tuple(ids[:2])


def main():
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    targets = []
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--group" and args[1].isdecimal() and int(args[1]) > 0:
        pid = int(args[1])
        group = coalition(lib, pid)
        if not all(group):
            raise SystemExit("Missing coalition identifiers; use explicit PIDs")
        targets.append(("main", pid))
        # comm is executable path, not argv or the page-derived process display name.
        listing = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
        roles = {"com.apple.WebKit.WebContent": "content", "com.apple.WebKit.GPU": "gpu",
                 "com.apple.WebKit.Networking": "network"}
        for line in listing.splitlines():
            candidate, path = line.strip().split(None, 1)
            name = path.rsplit("/", 1)[-1]
            role = next((role for prefix, role in roles.items() if name == prefix or name.startswith(prefix + ".")), None)
            if role:
                try:
                    if coalition(lib, int(candidate)) == group:
                        targets.append((role, int(candidate)))
                except OSError:
                    pass  # Process exited or query denied; no guessed attribution.
        args = []
    for arg in args:
        role, sep, pid = arg.partition("=")
        if not sep or role not in {"main", "content", "gpu", "network", "extension"} or not pid.isdecimal() or int(pid) <= 0:
            raise SystemExit("Expected role=positive-pid; roles: main content gpu network extension")
        targets.append((role, int(pid)))
    if not targets:
        raise SystemExit(__doc__)
    for role, pid in targets:
        usage = Usage()
        result = {"unix_s": round(time.time(), 3), "role": role, "pid": pid}
        if lib.proc_pid_rusage(pid, 0, ctypes.byref(usage)):
            code = ctypes.get_errno()
            result.update(error=errno.errorcode.get(code, str(code)))
        else:
            result.update(footprint_bytes=usage.footprint, resident_bytes=usage.resident,
                          start_abstime=usage.start)
        print(json.dumps(result))


if __name__ == "__main__":
    main()
