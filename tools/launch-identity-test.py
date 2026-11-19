#!/usr/bin/env python3
"""Check macOS launch attribution with SorrelTest only, without Screen Time access."""

import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parent.parent
APP = REPO / "build/SorrelTest.app"
EXE = APP / "Contents/MacOS/Sorrel"
REFUSAL = "Direct executable launches inherit the launching app's macOS identity and are refused."


def check(name, passed):
    print(f"launch-test: {name} expected=true got={str(passed).lower()}", flush=True)
    if not passed:
        raise RuntimeError(name)


def running_tests():
    output = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    return [int(parts[0]) for line in output.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == str(EXE)]


def run(mode):
    scratch = Path(tempfile.mkdtemp(prefix="sorrel-test.", dir="/private/tmp"))
    profile = scratch / "p1"
    profile.mkdir()
    env = {
        "SORREL_HOME": str(profile),
        "SORREL_SNAPSHOT": str(scratch / "shot.png"),
        "SORREL_DELAY": "8" if mode == "services" else "3",
        "SORREL_OPEN": "birch://welcome",
        "SORREL_LAUNCHTEST": "direct" if mode == "direct" else "guard",
    }
    if mode == "services":
        env["SORREL_WINDOWTEST"] = "1"
    log_path = scratch / "test.log"
    clean_environment = {key: value for key, value in os.environ.items()
                         if not key.startswith("SORREL_")}
    child = None
    test_pid = None
    try:
        with log_path.open("w") as log:
            if mode == "services":
                args = ["/usr/bin/open", "-n", "-g", "-W", "--stderr", str(log_path)]
                for key, value in env.items():
                    args.extend(["--env", f"{key}={value}"])
                child = subprocess.Popen(args + [str(APP)], env=clean_environment,
                                         stdout=log, stderr=log)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and child.poll() is None:
                    matches = running_tests()
                    if matches:
                        test_pid = matches[0]
                        break
                    time.sleep(0.1)
                check("Launch Services starts the exact test bundle", test_pid is not None)
                # External read-only diagnostic; never linked into the browser.
                responsibility = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
                responsibility.argtypes = [ctypes.c_int]
                responsibility.restype = ctypes.c_int
                check("Launch Services process is responsible for itself",
                      responsibility(test_pid) == test_pid)
            else:
                child = subprocess.Popen([str(EXE)], env=dict(clean_environment, **env),
                                         stdout=log, stderr=log)
                test_pid = child.pid
            result = child.wait(timeout=30)
        output = log_path.read_text()
        if mode == "guard":
            check("direct browser startup is refused", result == 2 and REFUSAL in output)
            check("refusal precedes profile writes", not any(profile.iterdir()))
            check("refusal precedes window creation", not (scratch / "shot.png").exists())
        else:
            check(f"{mode} exits normally", result == 0)
            expected_services = mode == "services"
            check(f"{mode} detects launch metadata",
                  f"launch: services expected={str(expected_services).lower()} got={str(expected_services).lower()}" in output)
            check(f"{mode} retains sandbox", "launch: sandbox expected=true got=true" in output)
            check(f"{mode} uses scratch profile", "launch: scratch profile expected=true got=true" in output)
            check(f"{mode} produces a window snapshot", (scratch / "shot.png").is_file())
            if mode == "services":
                checks = [line for line in output.splitlines() if line.startswith("windows:")]
                check("all 22 window regressions pass", len(checks) == 22 and
                      all("expected=true got=true" in line for line in checks))
        check(f"{mode} leaves no test process", test_pid not in running_tests())
    finally:
        # Kill only this run's test PID if a timeout/assertion interrupted it.
        if test_pid in running_tests():
            os.kill(test_pid, 15)
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
    print(f"launch-test: {mode} scratch={scratch}", flush=True)


if __name__ == "__main__":
    check("test bundle exists", EXE.is_file())
    check("no previous test instance is running", not running_tests())
    for mode in ("direct", "guard", "services"):
        run(mode)
