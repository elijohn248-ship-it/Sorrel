#!/usr/bin/env python3
"""Runs the Chromium edition's app tests against local fixtures (CI).

Every launch gets a fresh scratch BIRCH_HOME under the system temp folder;
nothing touches a real profile. Logs hold fixture hosts, counts and
Chromium diagnostics only. Writes <out>/summary.md and <out>/results.json and
exits 1 when a required check fails.

  python3 -I run_tests.py --app <birch executable> --platform windows|linux \
      --out <dir> [--only shell,restore,...] [--zip <Windows zip to smoke-test>]

Checks: shell (tabs, sidebar, address box, shortcuts, state.json), restore,
corrupt (unreadable state.json), private (storage isolation + nothing on
disk), download (Downloads folder, Mark of the Web, private origin removed),
perm, tls, netlog (+ a positive control), sandbox (process tokens/seccomp, and
sandbox-disabling switches stripped), zip (the CI artifact unpacked fresh).
"""
import argparse
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import netlog_check  # noqa: E402  (same folder; -I keeps cwd out of the path)

FIXTURES = os.path.join(HERE, "..", "fixtures")
CHECK = re.compile(r"^([\w-]+): (.*) expected=(.*) got=(.*) -> (PASS|FAIL)$")

A = None
WORK = ""
RESULTS = {}
REQUIRED_FAIL = []
SERVER_LOG = None
PORTS = {}


def record(name, status, evidence, required=True):
    entry = RESULTS.setdefault(name, {"status": status, "evidence": []})
    order = {"FAIL": 3, "NOT TESTED": 2, "INFO": 1, "PASS": 0}
    if order[status] > order[entry["status"]]:
        entry["status"] = status
    entry["evidence"] += evidence if isinstance(evidence, list) else [evidence]
    if status == "FAIL" and required:
        REQUIRED_FAIL.append(name)
    print(f"[{name}] {status}: " + "; ".join(
        evidence if isinstance(evidence, list) else [evidence])[:3000], flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def openssl():
    found = shutil.which("openssl")
    if found:
        return found
    git = r"C:\Program Files\Git\usr\bin\openssl.exe"
    if os.path.exists(git):
        return git
    sys.exit("tests: openssl not found")


def start_server(work):
    global SERVER_LOG
    cert, key = os.path.join(work, "bad.crt"), os.path.join(work, "bad.key")
    subprocess.run([openssl(), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-days", "2", "-subj", "/CN=bad.birch.test",
                    "-addext", "subjectAltName=DNS:bad.birch.test",
                    "-keyout", key, "-out", cert], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PORTS["http"], PORTS["https"] = free_port(), free_port()
    SERVER_LOG = os.path.join(work, "server-requests.jsonl")
    proc = subprocess.Popen([sys.executable, "-I", os.path.join(FIXTURES, "server.py"),
                             "--http-port", str(PORTS["http"]),
                             "--https-port", str(PORTS["https"]),
                             "--cert", cert, "--key", key, "--log", SERVER_LOG],
                            stdout=subprocess.PIPE, text=True)
    assert "ready" in proc.stdout.readline()
    return proc


def server_requests():
    if not os.path.exists(SERVER_LOG):
        return []
    with open(SERVER_LOG, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def kill_tree(proc):
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def new_home():
    scratch = tempfile.mkdtemp(prefix="birch-test.")
    home = os.path.join(scratch, "profile")
    os.makedirs(home)
    return scratch, home


def run_app(name, env_extra, timeout, marker=None, during=None, app=None,
            args=(), home=None, scratch=None):
    """One launch with a fresh scratch profile (or |home| prepared by the
    caller). Returns a dict with the log lines, checks and exit status."""
    if home is None:
        scratch, home = new_home()
    log = os.path.join(scratch, "app.log")
    env = dict(os.environ)
    env.update({"BIRCH_HOME": home, "BIRCH_LOG": log, "BIRCH_SHOW": "1",
                "BIRCH_CEF_LOG": os.path.join(scratch, "cef.log"),
                "BIRCH_HTTP_PORT": str(PORTS["http"]),
                "BIRCH_HTTPS_PORT": str(PORTS["https"]),
                "BIRCH_DELAY": str(max(30, timeout - 25))})
    env.update(env_extra)
    stdout = open(os.path.join(scratch, "stdout.txt"), "wb")
    kwargs = {"start_new_session": True} if os.name != "nt" else {}
    started = time.time()
    proc = subprocess.Popen([app or A.app, *args], env=env, stdout=stdout,
                            stderr=subprocess.STDOUT, cwd=scratch, **kwargs)
    during_result, timed_out = None, False
    try:
        if marker:
            while time.time() - started < timeout:
                if os.path.exists(log) and marker in open(
                        log, encoding="utf-8", errors="replace").read():
                    time.sleep(2)
                    during_result = during(proc)
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.5)
        proc.wait(timeout=max(5, timeout - (time.time() - started)))
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_tree(proc)
        proc.wait()
    stdout.close()
    lines = []
    if os.path.exists(log):
        with open(log, encoding="utf-8", errors="replace") as f:
            lines = [line.rstrip("\n") for line in f]
    dest = os.path.join(A.out, "logs")
    os.makedirs(dest, exist_ok=True)
    if os.path.exists(log):
        shutil.copy(log, os.path.join(dest, f"{name}.log"))
    cef_log = os.path.join(scratch, "cef.log")
    if os.path.exists(cef_log):
        with open(cef_log, encoding="utf-8", errors="replace") as f:
            tail = f.readlines()[-300:]
        with open(os.path.join(dest, f"{name}.cef.log"), "w", encoding="utf-8") as f:
            f.writelines(tail)
    checks = [m.groups() for m in (CHECK.match(line) for line in lines) if m]
    elapsed = round(time.time() - started, 1)
    print(f"run {name}: exit={proc.returncode} timed_out={timed_out} {elapsed}s "
          f"checks={len(checks)} failed={sum(1 for c in checks if c[4] == 'FAIL')}",
          flush=True)
    return {"lines": lines, "checks": checks, "exit": proc.returncode,
            "timed_out": timed_out, "scratch": scratch, "home": home,
            "during": during_result, "clean_exit": "app: exited" in lines}


def check_lines(run, areas=None):
    return [f"{a}: {w} expected={e} got={g} -> {r}"
            for a, w, e, g, r in run["checks"] if areas is None or a in areas]


def grep(run, prefix, limit=40):
    return [line for line in run["lines"] if line.startswith(prefix)][:limit]


def passed(run, need_checks=True):
    fails = [c for c in run["checks"] if c[4] == "FAIL"]
    summary = [line for line in run["lines"] if line.startswith("summary:")]
    return ((bool(run["checks"]) or not need_checks) and not fails and not run["timed_out"]
            and bool(summary) and summary[-1].endswith("failed=0")
            and run["clean_exit"])


def scan(root, needles):
    """Files under |root| containing any needle (ASCII or UTF-16LE)."""
    pats = []
    for n in needles:
        pats += [n.encode(), n.encode("utf-16-le")]
    hits, files = [], 0
    for d, _, fs in os.walk(root):
        for fn in fs:
            p = os.path.join(d, fn)
            try:
                if os.path.getsize(p) > 200 * 1024 * 1024:
                    continue
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            files += 1
            if any(pat in data for pat in pats):
                hits.append(os.path.relpath(p, root))
    return sorted(hits), files


# ---- screenshots (CI only; the window is shown there) -----------------------------

def screenshot(path):
    try:
        if A.platform == "windows":
            ps = ("Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
                  "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;"
                  "$m=New-Object System.Drawing.Bitmap $b.Width,$b.Height;"
                  "$g=[System.Drawing.Graphics]::FromImage($m);"
                  "$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
                  f"$m.Save('{path}')")
            subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                           capture_output=True, timeout=30)
        elif shutil.which("import"):
            subprocess.run(["import", "-window", "root", path],
                           capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.exists(path)


# ---- checks -------------------------------------------------------------------------------

def test_shell():
    shot = os.path.abspath(os.path.join(A.out, f"window-{A.platform}.png"))
    run = run_app("shell", {"BIRCH_TEST": "shell", "BIRCH_HOLD": "5"}, 180,
                  marker="shell: hold", during=lambda _p: screenshot(shot))
    ev = check_lines(run) + grep(run, "crash:") + grep(run, "popup:") + [
        f"screenshot taken: {run['during']}",
        f"exit={run['exit']} clean={run['clean_exit']}"]
    record("shell: tabs, sidebar, address box, shortcuts, state.json",
           "PASS" if passed(run) else "FAIL", ev)
    return run


def test_restore(shell_run):
    state = os.path.join(shell_run["home"], "state.json")
    if not os.path.exists(state):
        record("restore after relaunch", "FAIL", "shell run left no state.json")
        return
    scratch, home = new_home()
    shutil.copy(state, os.path.join(home, "state.json"))
    run = run_app("restore", {"BIRCH_TEST": "restore", "BIRCH_EXPECT_ROWS": "1",
                              "BIRCH_EXPECT_SUFFIX": "/page2.html"}, 120,
                  home=home, scratch=scratch)
    record("restore after relaunch (fresh profile, copied state.json)",
           "PASS" if passed(run) else "FAIL",
           check_lines(run) + [f"exit={run['exit']} clean={run['clean_exit']}"])


def test_corrupt():
    scratch, home = new_home()
    with open(os.path.join(home, "state.json"), "w") as f:
        f.write("not json")
    run = run_app("corrupt", {"BIRCH_TEST": "corrupt"}, 120, home=home, scratch=scratch)
    record("unreadable state.json: fresh profile + backup",
           "PASS" if passed(run) else "FAIL",
           check_lines(run) + [f"exit={run['exit']} clean={run['clean_exit']}"])


def test_private():
    nonce = secrets.token_hex(6)
    t0 = time.time()
    run = run_app("private", {"BIRCH_TEST": "private", "BIRCH_PERSIST": "1",
                              "BIRCH_NONCE": nonce}, 180)
    priv = ["private.birch.test", f"birchprivate_{nonce}", f"birchprivshared_{nonce}"]
    priv_hits, files = scan(run["home"], priv)
    norm_hits, _ = scan(run["home"], ["normal.birch.test", f"birchnormal_{nonce}"])
    tmp_hits = []
    tmp = tempfile.gettempdir()
    for d, _, fs in os.walk(tmp):
        if d.startswith(run["scratch"]) or d.startswith(WORK):
            continue
        for fn in fs:
            p = os.path.join(d, fn)
            try:
                if os.path.getmtime(p) < t0 or os.path.getsize(p) > 50 * 1024 * 1024:
                    continue
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if any(m.encode() in data for m in priv):
                tmp_hits.append(os.path.relpath(p, tmp))
    ev = check_lines(run) + [
        f"profile after exit: {files} files; top level: {', '.join(sorted(os.listdir(run['home'])))}",
        f"files with private-window markers: {len(priv_hits)} {priv_hits[:10]}",
        f"files with normal-window markers (scanner works): {len(norm_hits)} {norm_hits[:6]}",
        f"temp files written during the run with private markers: {len(tmp_hits)} {tmp_hits[:5]}",
        f"exit={run['exit']} clean={run['clean_exit']}"]
    ok = passed(run) and not priv_hits and norm_hits and not tmp_hits
    record("private window: separate storage, nothing on disk after close",
           "PASS" if ok else "FAIL", ev)


def test_download():
    scratch, home = new_home()
    downloads = os.path.join(scratch, "Downloads")
    run = run_app("download", {"BIRCH_TEST": "download", "BIRCH_DOWNLOADS": downloads},
                  150, home=home, scratch=scratch)
    files = sorted(os.listdir(downloads)) if os.path.isdir(downloads) else []
    marks = []
    if A.platform == "windows":
        for f in files:
            try:
                with open(os.path.join(downloads, f) + ":Zone.Identifier",
                          encoding="utf-8", errors="replace") as z:
                    marks.append(f"{f}: " + z.read().replace("\r", "").replace("\n", " | "))
            except OSError as e:
                marks.append(f"{f}: no Zone.Identifier ({e.__class__.__name__})")
    else:
        for f in files:
            try:
                names = os.listxattr(os.path.join(downloads, f))
            except OSError:
                names = []
            marks.append(f"{f}: xattrs {names}")
    hits, _ = scan(home, ["pdl.birch.test", "birch-private.bin"])
    ev = check_lines(run) + grep(run, "motw:") + [
        f"files in the scratch Downloads folder: {files}"] + marks + [
        f"profile files naming the private download: {hits}"]
    ok = passed(run) and len(files) == 2 and not hits
    if A.platform == "windows":
        normal = [m for m in marks if m.startswith("birch-test.bin")]
        private = [m for m in marks if m.startswith("birch-private.bin")]
        ok = ok and normal and "ZoneId=3" in normal[0] and "HostUrl" in normal[0]
        ok = ok and private and "ZoneId=3" in private[0] and "HostUrl" not in private[0]
    record("downloads: Downloads folder, Mark of the Web, private origin removed",
           "PASS" if ok else "FAIL", ev)


def test_perm():
    run = run_app("perm", {"BIRCH_TEST": "perm", "BIRCH_FAKE_MEDIA": "1"}, 120)
    record("permissions refused by default", "PASS" if passed(run) else "FAIL",
           check_lines(run) + grep(run, "perm:"))


def test_tls():
    before = len(server_requests())
    run = run_app("tls", {"BIRCH_TEST": "tls"}, 120)
    secret = [r for r in server_requests()[before:] if r["path"] == "/tls/secret.html"]
    ok = passed(run) and not secret
    record("bad certificate never loads", "PASS" if ok else "FAIL",
           check_lines(run) + grep(run, "tls:") + grep(run, "load:") +
           [f"HTTPS fixture requests for the page: {len(secret)}"])


def test_netlog():
    d = tempfile.mkdtemp(prefix="birch-netlog.")
    netlog = os.path.join(d, "netlog.json")
    run = run_app("netlog", {"BIRCH_TEST": "netlog", "BIRCH_PERSIST": "1",
                             "BIRCH_NETLOG": netlog, "BIRCH_HOLD": str(A.netlog_hold)},
                  A.netlog_hold + 150)
    if not os.path.exists(netlog):
        record("NetLog: only the fixture server contacted", "FAIL", "no NetLog written")
        return
    r = netlog_check.analyze(netlog)
    ev = [f"NetLog {os.path.getsize(netlog)} bytes, idle {A.netlog_hold} s after browsing",
          "hosts requested: " + ", ".join(r["requested"]),
          "addresses contacted: " + ", ".join(r["contacted"]),
          "route probes (no packet sent): " + (", ".join(r["route_probes"]) or "none"),
          "OS proxy auto-detect (wpad) lookup: " + ("yes" if r["wpad"] else "no"),
          "non-fixture requests/connections: " +
          (json.dumps(r["offenders"], sort_keys=True) if r["offenders"] else "none")]
    ok = passed(run, need_checks=False) and not r["offenders"]
    record("NetLog: only the fixture server contacted", "PASS" if ok else "FAIL", ev)
    shutil.copy(netlog, os.path.join(A.out, f"netlog-{A.platform}.json"))

    # Positive control: a deliberate lookup of a non-fixture host must be caught.
    d2 = tempfile.mkdtemp(prefix="birch-netlog.")
    control = os.path.join(d2, "netlog.json")
    crun = run_app("netlog-control", {"BIRCH_TEST": "netlogcontrol",
                                      "BIRCH_NETLOG": control}, 90)
    caught = False
    if os.path.exists(control):
        cr = netlog_check.analyze(control)
        caught = "control.example" in cr["offenders"]
    record("NetLog check catches a non-fixture host (positive control)",
           "PASS" if caught and crun["clean_exit"] else "FAIL",
           [f"control.example flagged: {caught}", f"exit={crun['exit']}"])


# ---- sandbox ------------------------------------------------------------------------------

def win_processes(app):
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq '%s' } | "
          "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
          % app.replace("'", "''"))
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True).stdout.strip()
    data = json.loads(out) if out else []
    return data if isinstance(data, list) else [data]


def win_token(pid):
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    adv = ctypes.WinDLL("advapi32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    adv.GetSidSubAuthorityCount.restype = ctypes.c_void_p
    adv.GetSidSubAuthority.restype = ctypes.c_void_p
    adv.GetSidSubAuthority.argtypes = [ctypes.c_void_p, wintypes.DWORD]
    adv.GetSidSubAuthorityCount.argtypes = [ctypes.c_void_p]
    info = {}
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return {"error": f"OpenProcess {ctypes.get_last_error()}"}
    in_job = wintypes.BOOL()
    if k32.IsProcessInJob(h, None, ctypes.byref(in_job)):
        info["job"] = bool(in_job.value)
    tok = wintypes.HANDLE()
    if not adv.OpenProcessToken(h, 0x0008, ctypes.byref(tok)):
        k32.CloseHandle(h)
        info["token"] = "unreadable"
        return info

    def query(cls):
        size = wintypes.DWORD()
        adv.GetTokenInformation(tok, cls, None, 0, ctypes.byref(size))
        buf = ctypes.create_string_buffer(max(size.value, 4))
        if not adv.GetTokenInformation(tok, cls, buf, size, ctypes.byref(size)):
            return None
        return buf

    buf = query(25)  # TokenIntegrityLevel
    if buf is not None:
        psid = ctypes.cast(buf, ctypes.POINTER(ctypes.c_void_p))[0]
        count = ctypes.cast(adv.GetSidSubAuthorityCount(psid), ctypes.POINTER(ctypes.c_ubyte))[0]
        rid = ctypes.cast(adv.GetSidSubAuthority(psid, count - 1),
                          ctypes.POINTER(ctypes.c_ulong))[0]
        info["integrity"] = {0: "untrusted", 0x1000: "low", 0x2000: "medium",
                             0x3000: "high", 0x4000: "system"}.get(rid, hex(rid))
    buf = query(29)  # TokenIsAppContainer
    if buf is not None:
        info["appcontainer"] = bool(ctypes.cast(buf, ctypes.POINTER(ctypes.c_ulong))[0])
    info["restricted"] = bool(adv.IsTokenRestricted(tok))
    k32.CloseHandle(tok)
    k32.CloseHandle(h)
    return info


def ptype(cmd):
    m = re.search(r"--type=([\w-]+)", cmd or "")
    t = m.group(1) if m else "browser"
    s = re.search(r"--utility-sub-type=([\w.]+)", cmd or "")
    return t + (f"({s.group(1).split('.')[-1]})" if s else "")


def inspect_windows(app):
    rows = []
    for p in win_processes(app):
        cmd = p.get("CommandLine") or ""
        rows.append({"type": ptype(cmd), "pid": p["ProcessId"],
                     "disabling_switch": bool(re.search(
                         r"--(no-sandbox|disable-gpu-sandbox|no-zygote-sandbox|single-process)\b", cmd)),
                     **win_token(p["ProcessId"])})
    return rows


def session_of(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[3])
    except (OSError, ValueError, IndexError):
        return -1


def inspect_linux(proc):
    rows = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or session_of(pid) != proc.pid:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if not argv or not argv[0]:
            continue
        cmd = " ".join(a.decode(errors="replace") for a in argv)
        seccomp = "?"
        try:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("Seccomp:"):
                        seccomp = line.split()[1]
        except OSError:
            pass
        rows.append({"type": ptype(cmd), "pid": int(pid), "seccomp": seccomp,
                     # Chromium's own unsandboxed helper zygote always carries
                     # --no-zygote-sandbox (it hosts the GPU and network
                     # processes, as in Chrome); only the switches a caller
                     # could pass to weaken the sandbox count here.
                     "disabling_switch": bool(re.search(
                         r"--(no-sandbox|disable-gpu-sandbox|disable-setuid-sandbox|single-process)\b", cmd))})
    return rows


def sandbox_verdict(rows):
    renderers = [r for r in rows if r["type"] == "renderer"]
    # The browser process's own command line is what the harness passed; what
    # matters is that no child process was started with such a switch.
    flagged = any(r["disabling_switch"] for r in rows if r["type"] != "browser")
    if A.platform == "windows":
        def confined(r):
            return r.get("integrity") in ("untrusted", "low") and (
                r.get("restricted") or r.get("appcontainer"))
        net = [r for r in rows if r["type"] == "utility(NetworkService)"]
        ok = (renderers and all(confined(r) for r in renderers) and not flagged
              and all(r.get("appcontainer") or r.get("integrity") in ("untrusted", "low")
                      for r in net))
    else:
        ok = renderers and all(r["seccomp"] == "2" for r in renderers) and not flagged
    return bool(ok), renderers


def test_sandbox():
    inspect = (lambda _p: inspect_windows(A.app)) if A.platform == "windows" else inspect_linux
    # Launched WITH sandbox-disabling switches: Birch must strip them (or
    # refuse to start) and every renderer must still be sandboxed.
    bad = ["--no-sandbox", "--disable-gpu-sandbox", "--single-process"]
    run = run_app("sandbox", {"BIRCH_TEST": "sandbox", "BIRCH_HOLD": "20"}, 160,
                  marker="sandbox: hold", during=inspect, args=bad)
    stripped = [line for line in run["lines"] if line.startswith("sandbox: removed forbidden switch")]
    refused = run["exit"] == 3 and any("refusing" in line for line in run["lines"])
    ev = [f"launched with {' '.join(bad)}: stripped={len(stripped)} refused={refused}"] + stripped
    if refused:
        run = run_app("sandbox-plain", {"BIRCH_TEST": "sandbox", "BIRCH_HOLD": "20"}, 160,
                      marker="sandbox: hold", during=inspect)
    rows = run["during"] or []
    ok, renderers = sandbox_verdict(rows)
    ev += [json.dumps(r, sort_keys=True) for r in rows]
    ev += grep(run, "sandboxpage", 40) + grep(run, "sandbox:")
    ev.append(f"renderers={len(renderers)} processes={len(rows)}")
    ok = ok and (refused or len(stripped) >= 2) and passed(run, need_checks=False)
    record("sandbox on for every renderer; disabling switches stripped",
           "PASS" if ok else "FAIL", ev)


# ---- the Windows zip, unpacked fresh (no build-time ACLs) ----------------------------------

def test_zip():
    if not A.zip or A.platform != "windows":
        return
    dest = tempfile.mkdtemp(prefix="birch-zip.")
    with zipfile.ZipFile(A.zip) as z:
        z.extractall(dest)
    exes = [os.path.join(d, f) for d, _, fs in os.walk(dest) for f in fs if f == "birch.exe"]
    if len(exes) != 1:
        record("Windows zip: unpacked and run", "FAIL", f"birch.exe found {len(exes)} times")
        return
    app = exes[0]
    sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
    import set_exe_icon  # noqa: E402
    icons = set_exe_icon.existing(app)
    groups = [n for t, n, _ in icons if t == set_exe_icon.RT_GROUP_ICON]
    shot = os.path.abspath(os.path.join(A.out, "zip-window-windows.png"))
    run = run_app("zip-smoke", {"BIRCH_TEST": "smoke", "BIRCH_HOLD": "4"}, 120, app=app,
                  marker="smoke: hold", during=lambda _p: screenshot(shot))
    acl = grep(run, "sandbox: app folder")
    ev = check_lines(run) + acl + [
        f"icon groups in birch.exe: {groups}",
        f"top-level files: {sorted(os.listdir(os.path.dirname(app)))[:40]}",
        f"exit={run['exit']} clean={run['clean_exit']}"]
    ok = passed(run) and groups == [1] and any(line.endswith("added") for line in acl)
    record("Windows zip: unpacked fresh, runs, loads pages, Birch icon",
           "PASS" if ok else "FAIL", ev)


def main():
    global A, WORK
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--platform", required=True, choices=["windows", "linux"])
    p.add_argument("--out", required=True)
    p.add_argument("--only", default="")
    p.add_argument("--zip", default="")
    p.add_argument("--netlog-hold", type=int, default=75)
    A = p.parse_args()
    A.app = os.path.abspath(A.app)
    os.makedirs(A.out, exist_ok=True)
    WORK = tempfile.mkdtemp(prefix="birch-fixtures.")
    server = start_server(WORK)
    only = set(filter(None, A.only.split(",")))
    want = lambda n: not only or n in only  # noqa: E731
    try:
        shell_run = test_shell() if want("shell") else None
        if want("restore") and shell_run:
            test_restore(shell_run)
        if want("corrupt"):
            test_corrupt()
        if want("private"):
            test_private()
        if want("download"):
            test_download()
        if want("perm"):
            test_perm()
        if want("tls"):
            test_tls()
        if want("netlog"):
            test_netlog()
        if want("sandbox"):
            test_sandbox()
        if want("zip"):
            test_zip()
    finally:
        server.terminate()
    with open(os.path.join(A.out, "results.json"), "w") as f:
        json.dump(RESULTS, f, indent=1)
    with open(os.path.join(A.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(f"# Birch (Chromium) app tests on {A.platform}\n\n")
        for name, r in RESULTS.items():
            f.write(f"## {name}: {r['status']}\n\n")
            for e in r["evidence"]:
                f.write(f"- `{e}`\n")
            f.write("\n")
    print("\nSUMMARY " + json.dumps({k: v["status"] for k, v in RESULTS.items()}))
    if REQUIRED_FAIL:
        print("required failures: " + ", ".join(REQUIRED_FAIL))
        sys.exit(1)


if __name__ == "__main__":
    main()
