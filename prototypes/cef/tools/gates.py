#!/usr/bin/env python3
"""Runs the Birch CEF prototype gates against local fixtures (CI only).

Every launch gets a fresh scratch BIRCH_HOME under the system temp folder.
Logs contain fixture hosts, counts and Chromium diagnostics only, never real
browsing data. Writes <out>/summary.md and <out>/gates.json; exits 1 when a
required check fails.

  python3 -I gates.py --app <birch_cef executable> --platform windows|linux \
      --media <dir> --ubol <dir> --out <dir> [--only tabs,storage,...]
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
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "..", "fixtures")
CHECK = re.compile(r"^([\w-]+): (.*) expected=(.*) got=(.*) -> (PASS|FAIL)$")

A = None
WORK = ""
RESULTS = {}      # gate -> {"status": ..., "evidence": [...]}
REQUIRED_FAIL = []
SERVER_LOG = None
PORTS = {}


def gate(name, status, evidence, required=True):
    entry = RESULTS.setdefault(name, {"status": status, "evidence": []})
    order = {"FAIL": 3, "NOT TESTED": 2, "INFO": 1, "PASS": 0}
    if order[status] > order[entry["status"]]:
        entry["status"] = status
    entry["evidence"] += evidence if isinstance(evidence, list) else [evidence]
    if status == "FAIL" and required:
        REQUIRED_FAIL.append(name)
    print(f"[{name}] {status}: " + "; ".join(
        evidence if isinstance(evidence, list) else [evidence])[:2000], flush=True)


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
    sys.exit("gates: openssl not found")


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
                             "--cert", cert, "--key", key, "--media", A.media or "",
                             "--log", SERVER_LOG], stdout=subprocess.PIPE, text=True)
    assert "ready" in proc.stdout.readline()
    return proc


def server_requests():
    if not os.path.exists(SERVER_LOG):
        return []
    with open(SERVER_LOG, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def kill_tree(proc):
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run_app(name, env_extra, timeout, marker=None, during=None):
    """One launch with a fresh scratch profile. Returns a dict."""
    scratch = tempfile.mkdtemp(prefix="birch-test.")
    home = os.path.join(scratch, "profile")
    os.makedirs(home)
    log = os.path.join(scratch, "app.log")
    env = dict(os.environ)
    env.update({"BIRCH_HOME": home, "BIRCH_LOG": log,
                "BIRCH_CEF_LOG": os.path.join(scratch, "cef.log"),
                "BIRCH_HTTP_PORT": str(PORTS["http"]),
                "BIRCH_HTTPS_PORT": str(PORTS["https"]),
                "BIRCH_DELAY": str(max(30, timeout - 25))})
    env.update(env_extra)
    stdout = open(os.path.join(scratch, "stdout.txt"), "wb")
    kwargs = {"start_new_session": True} if os.name != "nt" else {}
    started = time.time()
    proc = subprocess.Popen([A.app], env=env, stdout=stdout, stderr=subprocess.STDOUT,
                            cwd=scratch, **kwargs)
    during_result = None
    timed_out = False
    try:
        if marker:
            while time.time() - started < timeout:
                if os.path.exists(log) and marker in open(log, encoding="utf-8",
                                                          errors="replace").read():
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
            lines = [l.rstrip("\n") for l in f]
    # Keep logs as CI evidence (fixture hosts and counts only).
    dest = os.path.join(A.out, "logs")
    os.makedirs(dest, exist_ok=True)
    shutil.copy(log, os.path.join(dest, f"{name}.log")) if os.path.exists(log) else None
    cef_log = os.path.join(scratch, "cef.log")
    if os.path.exists(cef_log):
        with open(cef_log, encoding="utf-8", errors="replace") as f:
            tail = f.readlines()[-300:]
        with open(os.path.join(dest, f"{name}.cef.log"), "w", encoding="utf-8") as f:
            f.writelines(tail)
    checks = [CHECK.match(l) for l in lines]
    checks = [m.groups() for m in checks if m]
    elapsed = round(time.time() - started, 1)
    print(f"run {name}: exit={proc.returncode} timed_out={timed_out} {elapsed}s "
          f"checks={len(checks)} failed={sum(1 for c in checks if c[4] == 'FAIL')}",
          flush=True)
    return {"lines": lines, "checks": checks, "exit": proc.returncode,
            "timed_out": timed_out, "scratch": scratch, "home": home,
            "during": during_result, "clean_exit": "app: exited" in lines}


def check_lines(run, prefixes=None):
    out = []
    for area, what, exp, got, res in run["checks"]:
        if prefixes is None or area in prefixes:
            out.append(f"{area}: {what} expected={exp} got={got} -> {res}")
    return out


def verdict_from_checks(run, need_summary=True):
    fails = [c for c in run["checks"] if c[4] == "FAIL"]
    ok = run["checks"] and not fails and not run["timed_out"]
    if need_summary:
        ok = ok and any(l.startswith("summary:") for l in run["lines"])
    return "PASS" if ok else "FAIL"


def grep(run, prefix, limit=40):
    return [l for l in run["lines"] if l.startswith(prefix)][:limit]


# ---- gate 1 -----------------------------------------------------------------

def gate_tabs(label):
    run = run_app(f"tabs-{label}", {"BIRCH_TEST": "tabs",
                                    "BIRCH_SNAPSHOT": os.path.join(A.out, f"tabs-{label}.png")},
                  150)
    gate(f"1 tabs ({label})", verdict_from_checks(run),
         check_lines(run) + grep(run, "crash:") + [f"exit={run['exit']} clean={run['clean_exit']}"])


# ---- gate 2 -----------------------------------------------------------------

def scan(root, needles):
    """Files under root containing any needle (ASCII or UTF-16LE)."""
    pats = []
    for n in needles:
        pats += [n.encode(), n.encode("utf-16-le")]
    hits, files, total = {}, 0, 0
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
            total += len(data)
            for pat in pats:
                if pat in data:
                    hits.setdefault(os.path.relpath(p, root), True)
    return sorted(hits), files, total


def gate_storage(label):
    nonce = secrets.token_hex(6)
    t0 = time.time()
    run = run_app(f"storage-{label}", {"BIRCH_TEST": "storage", "BIRCH_PERSIST": "1",
                                       "BIRCH_NONCE": nonce}, 150)
    priv_marks = ["private.birch.test", f"birchprivate_{nonce}", f"birchprivshared_{nonce}"]
    priv_hits, files, size = scan(run["home"], priv_marks)
    norm_hits, _, _ = scan(run["home"], ["normal.birch.test", f"birchnormal_{nonce}"])
    # Anything else written to the system temp folder during the run.
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
            if any(m.encode() in data for m in priv_marks):
                tmp_hits.append(os.path.relpath(p, tmp))
    top = sorted(os.listdir(run["home"]))
    ev = check_lines(run) + [
        f"profile after exit: {files} files, {size} bytes; top level: {', '.join(top)}",
        f"files containing private-window markers: {len(priv_hits)} {priv_hits[:10]}",
        f"files containing normal-window markers (scanner sanity): {len(norm_hits)} {norm_hits[:6]}",
        f"files elsewhere in the temp folder written during the run with private markers: {len(tmp_hits)} {tmp_hits[:5]}",
        f"exit={run['exit']} clean={run['clean_exit']}"]
    ok = (verdict_from_checks(run) == "PASS" and not priv_hits and norm_hits
          and not tmp_hits and run["clean_exit"])
    gate(f"2 storage ({label})", "PASS" if ok else "FAIL", ev)


# ---- gate 3 -----------------------------------------------------------------

def gate_download():
    run = run_app("download", {"BIRCH_TEST": "download"}, 120)
    dl_dir = os.path.join(run["home"], "Downloads")
    files = sorted(os.listdir(dl_dir)) if os.path.isdir(dl_dir) else []
    ev = check_lines(run) + grep(run, "motw:") + grep(run, "download:")
    marks = []
    for f in files:
        p = os.path.join(dl_dir, f)
        try:
            with open(p + ":Zone.Identifier", encoding="utf-8", errors="replace") as z:
                marks.append(f"{f}: " + z.read().replace("\r", "").replace("\n", " | "))
        except OSError as e:
            marks.append(f"{f}: no Zone.Identifier ({e.__class__.__name__})")
    ev += [f"files in scratch Downloads: {files}"] + marks
    by_chromium = [l for l in run["lines"] if l == "motw: written-by-chromium=yes"]
    ok = (verdict_from_checks(run) == "PASS" and len(files) == 2
          and all("ZoneId=3" in m for m in marks))
    ev.append(f"mark written by Chromium itself for {len(by_chromium)} of {len(files)} downloads")
    gate("3 download + Mark of the Web", "PASS" if ok else "FAIL", ev)


# ---- gates 4 / 11 sandbox ---------------------------------------------------

def win_processes():
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq '%s' } | "
          "Select-Object ProcessId,ParentProcessId,CommandLine | ConvertTo-Json -Compress"
          % A.app.replace("'", "''"))
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
        info["token"] = f"unreadable ({ctypes.get_last_error()})"
        k32.CloseHandle(h)
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


def inspect_windows(_proc):
    rows = []
    for p in win_processes():
        cmd = p.get("CommandLine") or ""
        rows.append({"type": ptype(cmd), "pid": p["ProcessId"],
                     "no_sandbox_flag": "--no-sandbox" in cmd,
                     **win_token(p["ProcessId"])})
    return rows


def linux_userns(pid):
    try:
        return os.readlink(f"/proc/{pid}/ns/user")
    except OSError:
        return "unreadable"


def session_of(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[3])
    except (OSError, ValueError, IndexError):
        return -1


def inspect_linux(proc):
    """Every process in the app's own session (the app is started with
    start_new_session=True, so its session id is its pid)."""
    rows = []
    me = linux_userns(os.getpid())
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if session_of(pid) != proc.pid or not argv or not argv[0]:
            continue
        cmd = " ".join(a.decode(errors="replace") for a in argv)
        seccomp = "?"
        try:
            with open(f"/proc/{pid}/status") as f:
                for l in f:
                    if l.startswith("Seccomp:"):
                        seccomp = l.split()[1]
        except OSError:
            pass
        ns = linux_userns(pid)
        rows.append({"type": ptype(cmd), "pid": int(pid), "seccomp": seccomp,
                     "userns": "own" if ns not in (me, "unreadable") else
                               ("same" if ns == me else ns),
                     "no_sandbox_flag": "--no-sandbox" in cmd})
    return rows


def gate_sandbox(label):
    inspect = inspect_windows if A.platform == "windows" else inspect_linux
    run = run_app(f"sandbox-{label}", {"BIRCH_TEST": "sandbox", "BIRCH_HOLD": "20"}, 150,
                  marker="sandbox: hold", during=inspect)
    rows = run["during"] or []
    ev = [json.dumps(r, sort_keys=True) for r in rows]
    page = [l for l in run["lines"] if l.startswith("sandboxpage")]
    ev += page[:60] + grep(run, "sandbox:")
    renderers = [r for r in rows if r["type"] == "renderer"]
    gpus = [r for r in rows if r["type"] == "gpu-process"]
    any_flag = any(r["no_sandbox_flag"] for r in rows)
    if A.platform == "windows":
        def confined(r):
            return (r.get("integrity") in ("untrusted", "low") and
                    (r.get("restricted") or r.get("appcontainer")))
        ok = renderers and all(confined(r) for r in renderers) and not any_flag
        gpu_note = ("GPU: " + ", ".join(json.dumps(r, sort_keys=True) for r in gpus)
                    if gpus else "GPU: no separate GPU process seen")
        ev.append(gpu_note)
    else:
        ok = renderers and all(r["seccomp"] == "2" for r in renderers) and not any_flag
    ev.append(f"renderers={len(renderers)} processes={len(rows)} no-sandbox flag present={any_flag}")
    gate(f"4/11 sandbox ({label})", "PASS" if ok else "FAIL", ev)


# ---- gate 5 -----------------------------------------------------------------

ALLOWED = re.compile(r"(^|\.)birch\.test$|^127\.0\.0\.1$|^localhost$|^::1$")
REQUEST_KEYS = ("url", "original_url", "new_location", "host", "hostname",
                "destination", "qname", "origin")


def host_of(v):
    v = v.strip()
    if "://" in v:
        return (urlsplit(v.split(" ")[0]).hostname or "").lower()
    h = v.split(" ")[0]
    if h.startswith("["):
        return h[1:h.index("]")].lower() if "]" in h else h.lower()
    if h.count(":") == 1:
        h = h.split(":")[0]
    return h.lower()


def netlog_hosts(path):
    """Hosts Chromium tried to reach, and addresses it actually connected to
    or sent packets to. Resolver results and DNS configuration are ignored."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    try:
        data = json.loads(text)
    except ValueError:
        data = json.loads(text.rstrip().rstrip(",") + "]}")
    names = {v: k for k, v in data["constants"]["logEventTypes"].items()}
    requested, contacted = {}, {}
    udp_connect, udp_sent = {}, set()
    for ev in data.get("events", []):
        t = names.get(ev.get("type"), "")
        p = ev.get("params") or {}
        if not isinstance(p, dict):
            continue
        if t in ("TCP_CONNECT_ATTEMPT", "TCP_CONNECT") and "address" in p:
            contacted.setdefault(host_of(p["address"]), set()).add(t)
        elif t == "UDP_CONNECT" and "address" in p:
            udp_connect.setdefault(ev["source"]["id"], host_of(p["address"]))
        elif t == "UDP_BYTES_SENT" and "address" in p:
            udp_sent.add(host_of(p["address"]))
            contacted.setdefault(host_of(p["address"]), set()).add(t)
        if "RESULT" in t or "CACHE_HIT" in t or t.startswith("DNS_CONFIG"):
            continue
        for k in REQUEST_KEYS:
            v = p.get(k)
            if isinstance(v, str) and v:
                if "://" in v and not v.split("://")[0] in ("http", "https", "ws", "wss"):
                    continue
                h = host_of(v)
                if h:
                    requested.setdefault(h, set()).add(t)
    probes = sorted({a for a in udp_connect.values() if a not in udp_sent})
    return requested, contacted, probes


def gate_netlog(label, privacy_on=True):
    path_dir = tempfile.mkdtemp(prefix="birch-netlog.")
    netlog = os.path.join(path_dir, "netlog.json")
    env = {"BIRCH_TEST": "netlog", "BIRCH_PERSIST": "1", "BIRCH_NETLOG": netlog,
           "BIRCH_HOLD": str(A.netlog_hold)}
    if not privacy_on:
        env["BIRCH_PRIVACY"] = "off"
    name = f"netlog-{label}" + ("" if privacy_on else "-stock")
    run = run_app(name, env, A.netlog_hold + 120)
    if not os.path.exists(netlog):
        gate(f"5 network ({label})", "FAIL" if privacy_on else "INFO",
             [f"{name}: no NetLog written"], required=privacy_on)
        return
    requested, contacted, probes = netlog_hosts(netlog)
    bad_req = {h: sorted(v) for h, v in requested.items() if not ALLOWED.search(h)}
    bad_con = {h: sorted(v) for h, v in contacted.items() if not ALLOWED.search(h)}
    # Windows' own proxy auto-detection (WPAD) asks the LAN's DNS server for
    # "wpad"; it is an OS proxy setting, not a Chromium/Google service. It is
    # reported separately; the DNS packets it causes are only excused when
    # no other non-fixture host was looked up.
    wpad = bad_req.pop("wpad", None)
    if not bad_req:
        bad_con = {k: v for k, v in bad_con.items() if v != ["UDP_BYTES_SENT"]}
    other = dict(bad_req, **{"addr " + k: v for k, v in bad_con.items()})
    ev = [f"{name}: NetLog {os.path.getsize(netlog)} bytes",
          f"{name}: hosts requested: " + ", ".join(sorted(requested)),
          f"{name}: addresses connected/sent to: " + ", ".join(sorted(contacted)),
          f"{name}: UDP connect() without any packet sent (route probes): "
          + (", ".join(probes) or "none"),
          f"{name}: non-fixture requests/connections: "
          + (json.dumps(other, sort_keys=True) if other else "none"),
          f"{name}: WPAD (Windows proxy auto-detect) lookup: " + ("yes" if wpad else "no")]
    if privacy_on:
        ok = not other and run["clean_exit"] and not run["timed_out"]
        gate(f"5 network ({label})", "PASS" if ok else "FAIL", ev)
        shutil.copy(netlog, os.path.join(A.out, f"{name}.json"))
    else:
        gate(f"5 network ({label})", "INFO", ev, required=False)


# ---- gate 6, 7 ----------------------------------------------------------------

def gate_perm():
    run = run_app("perm", {"BIRCH_TEST": "perm", "BIRCH_FAKE_MEDIA": "1"}, 120)
    gate("6 permissions", verdict_from_checks(run),
         check_lines(run) + grep(run, "perm:"))


def gate_tls():
    before = len(server_requests())
    run = run_app("tls", {"BIRCH_TEST": "tls"}, 120)
    secret = [r for r in server_requests()[before:] if r["path"] == "/tls/secret.html"]
    ev = check_lines(run) + grep(run, "tls:") + grep(run, "load:") + [
        f"HTTPS fixture requests for the page: {len(secret)}"]
    ok = verdict_from_checks(run) == "PASS" and not secret
    gate("7 HTTPS bad certificate", "PASS" if ok else "FAIL", ev)


# ---- gate 8 -------------------------------------------------------------------

AD_HOSTS = "pagead2.googlesyndication.com,b.scorecardresearch.com"


def gate_ubol():
    if not A.ubol or not os.path.isfile(os.path.join(A.ubol, "manifest.json")):
        gate("8 extensions (uBOL)", "NOT TESTED", "uBOL not available")
        return
    before = len(server_requests())
    ctl = run_app("ubol-control", {"BIRCH_TEST": "ubol", "BIRCH_HOSTMAP": AD_HOSTS}, 120)
    ctl_reqs = server_requests()[before:]
    before = len(server_requests())
    run = run_app("ubol", {"BIRCH_TEST": "ubol", "BIRCH_HOSTMAP": AD_HOSTS,
                           "BIRCH_PERSIST": "1", "BIRCH_EXPECT_BLOCK": "1",
                           "BIRCH_EXTENSIONS": os.path.abspath(A.ubol)}, 180)
    reqs = server_requests()[before:]
    ad = lambda rs: sorted({r["host"] for r in rs if r["host"] in AD_HOSTS.split(",")})
    ev = (["control run (no extension): " + "; ".join(check_lines(ctl)),
           f"control run: ad hosts that reached the fixture server: {ad(ctl_reqs)}"]
          + check_lines(run) + grep(run, "ubol:") + grep(run, "popup:") +
          [f"uBOL run: ad hosts that reached the fixture server: {ad(reqs)}"])
    ok = (verdict_from_checks(run) == "PASS" and verdict_from_checks(ctl) == "PASS"
          and not ad(reqs) and len(ad(ctl_reqs)) == 2)
    gate("8 extensions (uBOL)", "PASS" if ok else "FAIL", ev)


# ---- gate 10, 12 --------------------------------------------------------------

def gate_codecs():
    if not A.media:
        gate("10 codecs", "NOT TESTED", "no media fixtures")
        return
    run = run_app("codecs", {"BIRCH_TEST": "codecs"}, 150)
    line = next((l for l in run["lines"] if l.startswith("codecs: ")), "codecs: missing")
    try:
        data = json.loads(line[len("codecs: "):])
        ev = [f"{m['codec']}: played={m['played']} canPlayType={m['canPlayType']} "
              f"mse={m['mse']} t={m['time']}" + (f" error={m['error']}" if "error" in m else "")
              for m in data["media"]]
        ev += [f"widevine: {data['widevine']}", f"clearkey: {data['clearkey']}"]
        gate("10 codecs", "INFO", ev, required=False)
    except (ValueError, KeyError):
        gate("10 codecs", "FAIL", [line], required=False)


def dir_size(p):
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(p) for f in fs)


def memory_windows(_proc):
    ps = ("Get-Process | Where-Object { $_.Path -eq '%s' } | "
          "Select-Object Id,WorkingSet64,PrivateMemorySize64 | ConvertTo-Json -Compress"
          % A.app.replace("'", "''"))
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True).stdout.strip()
    rows = json.loads(out) if out else []
    rows = rows if isinstance(rows, list) else [rows]
    return {"processes": len(rows),
            "working_set_mb": round(sum(r["WorkingSet64"] for r in rows) / 2**20, 1),
            "private_mb": round(sum(r["PrivateMemorySize64"] for r in rows) / 2**20, 1)}


def memory_linux(proc):
    rows = inspect_linux(proc)
    pss = rss = 0
    for r in rows:
        try:
            with open(f"/proc/{r['pid']}/smaps_rollup") as f:
                for l in f:
                    if l.startswith("Pss:"):
                        pss += int(l.split()[1])
                    elif l.startswith("Rss:"):
                        rss += int(l.split()[1])
        except OSError:
            pass
    return {"processes": len(rows), "pss_mb": round(pss / 1024, 1),
            "rss_mb": round(rss / 1024, 1)}


def gate_cost():
    mem = memory_windows if A.platform == "windows" else memory_linux
    run = run_app("idle", {"BIRCH_TEST": "idle", "BIRCH_HOLD": "25"}, 120,
                  marker="idle: hold", during=lambda p: (time.sleep(12), mem(p))[1])
    app_dir = os.path.dirname(os.path.abspath(A.app))
    zpath = os.path.join(tempfile.mkdtemp(prefix="birch-zip."), "app.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for d, _, fs in os.walk(app_dir):
            for f in fs:
                if f.endswith((".pdb", ".lib", ".exp", ".ilk", ".log")):
                    continue
                p = os.path.join(d, f)
                z.write(p, os.path.relpath(p, app_dir))
    deps = json.load(open(os.path.join(HERE, "..", "deps.json")))
    key = "windows64" if A.platform == "windows" else "linux64"
    ev = [f"idle memory, one blank tab (~14 s after start): {json.dumps(run['during'])}",
          f"app folder (excl. .pdb/.lib): installed size "
          f"{round(sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(app_dir) for f in fs if not f.endswith(('.pdb', '.lib', '.exp', '.ilk'))) / 2**20, 1)} MiB",
          f"zip of app folder (download size estimate): {round(os.path.getsize(zpath) / 2**20, 1)} MiB",
          f"CEF minimal distribution download: {round(deps['cef']['files'][key]['size'] / 2**20, 1)} MiB"]
    gate("12 cost", "INFO", ev, required=False)


def main():
    global A, WORK
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--platform", required=True, choices=["windows", "linux"])
    p.add_argument("--media", default="")
    p.add_argument("--ubol", default="")
    p.add_argument("--out", required=True)
    p.add_argument("--only", default="")
    p.add_argument("--netlog-hold", type=int, default=75)
    A = p.parse_args()
    A.app = os.path.abspath(A.app)
    os.makedirs(A.out, exist_ok=True)
    WORK = tempfile.mkdtemp(prefix="birch-fixtures.")
    server = start_server(WORK)
    only = set(filter(None, A.only.split(",")))
    want = lambda n: not only or n in only
    label = A.platform
    try:
        if want("tabs"):
            gate_tabs(label)
        if want("storage"):
            gate_storage(label)
        if want("netlog"):
            gate_netlog(label, True)
            gate_netlog(label, False)
        if want("sandbox"):
            gate_sandbox(label)
        if want("cost"):
            gate_cost()
        if A.platform == "windows":
            if want("download"):
                gate_download()
            if want("perm"):
                gate_perm()
            if want("tls"):
                gate_tls()
            if want("ubol"):
                gate_ubol()
            if want("codecs"):
                gate_codecs()
    finally:
        server.terminate()
    with open(os.path.join(A.out, "gates.json"), "w") as f:
        json.dump(RESULTS, f, indent=1)
    with open(os.path.join(A.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(f"# Gates on {A.platform}\n\n")
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
