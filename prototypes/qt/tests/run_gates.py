#!/usr/bin/env python3
"""Runs the Qt WebEngine prototype against local fixtures for the 12 gates (CI only).

Starts an HTTP and an HTTPS (self-signed, so gate 7 fails it) fixture server on
127.0.0.1, then launches the prototype once per scenario with a fresh scratch
BIRCH_HOME. Hostnames *.test, the punycode lookalike and one ad domain are
mapped to 127.0.0.1 with Chromium's --host-resolver-rules, so no test traffic
leaves the runner; anything else the engine contacts shows up in the NetLog.

Writes <out>/summary.txt (every expected/got line, marked ok/MISMATCH, plus the
harness's own checks) and per-scenario logs/screenshots. Never reads any real
profile; never uploads NetLogs or scratch profiles (only host summaries).

Exit code: 0 when every scenario ran to its end (gate results are findings,
reported in the summary), 1 when the harness or the app could not run.
"""
import argparse
import http.server
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
IS_WIN = sys.platform.startswith("win")
LOOKALIKE = "xn--80ak6aa92e.com"
# Chromium's host resolver checks IPv6 reachability with a UDP connect() to Google
# Public DNS's IPv6 address. A UDP connect sends no packet; strace (Linux) shows
# whether anything is ever sent there.
IPV6_PROBE = "2001:4860:4860::8888"
AD_HOST = "ib.adnxs.com"
ALLOWED_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]", LOOKALIKE, AD_HOST}
GIF = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,"
       b"\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")

HITS = []           # (scenario, host, path)
HITS_LOCK = threading.Lock()
STATE = {"scenario": "", "media": None}


def page(title, body):
    return (f"<!doctype html><meta charset=utf-8><title>{title}</title><body>{body}"
            "<script>function goHang(){location.href=location.protocol+'//evil.test:'+location.port+'/hang';}"
            "</script>").encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass  # the browser closed a connection (e.g. the hanging /hang request); not a test result

    def log_message(self, *args):  # keep CI logs short
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].lower()
        path = urllib.parse.urlsplit(self.path).path
        with HITS_LOCK:
            HITS.append((STATE["scenario"], host, path))
        if path in ("/page1.html", "/page2.html"):
            return self.send(200, page("Fixture " + path[1:6], "<p>Birch fixture page.</p>"))
        if path == "/hang":
            time.sleep(25)
            return self.send(200, page("late", "late"))
        if path == "/secret.html":
            return self.send(200, page("secret", "<p>BIRCH-SECRET must never be shown over a bad certificate</p>"))
        if path == "/mark.html":
            label = re.sub(r"[^a-z0-9-]", "", host.split(".")[0])[:40]
            body = page("mark", "<img src='/mark.png'><script>localStorage.setItem('birchmark', location.hostname);"
                                "const q=indexedDB.open('birchmark');q.onsuccess=q.onerror=()=>{window.__markDone=true};"
                                "</script>")
            return self.send(200, body, headers=[("Set-Cookie", f"birchmark_{label}=1; Max-Age=86400; Path=/"),
                                                 ("Cache-Control", "max-age=3600")])
        if path in ("/mark.png", "/ok.gif", "/pixel.gif"):
            return self.send(200, GIF, "image/gif", [("Cache-Control", "max-age=3600")])
        if path == "/download.bin":
            return self.send(200, secrets.token_bytes(65536), "application/octet-stream",
                             [("Content-Disposition", 'attachment; filename="birch-download-test.bin"')])
        if path == "/ads.html":
            body = page("ads", "<script>window.__ads={done:false};const res={};"
                               "function probe(k,u){return new Promise(r=>{const i=new Image();"
                               "i.onload=()=>{res[k]=true;r()};i.onerror=()=>{res[k]=false;r()};i.src=u+'?t='+Date.now();});}"
                               f"Promise.all([probe('tracker','http://{AD_HOST}:'+location.port+'/pixel.gif'),"
                               "probe('firstParty','/ok.gif')]).then(()=>{window.__ads=Object.assign({done:true},res)});"
                               "</script>")
            return self.send(200, body)
        if path in ("/perm.html", "/codecs.html"):
            return self.send(200, (FIXTURES / path[1:]).read_bytes())
        if path.startswith("/media/") and STATE["media"]:
            f = Path(STATE["media"]) / Path(path).name
            if f.is_file():
                ctype = {".mp4": "video/mp4", ".webm": "video/webm", ".m4a": "audio/mp4", ".mp3": "audio/mpeg",
                         ".flac": "audio/flac"}.get(f.suffix, "application/octet-stream")
                return self.send(200, f.read_bytes(), ctype)
        return self.send(404, b"not found", "text/plain")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def free_server(tls_ctx=None):
    srv = Server(("127.0.0.1", 0), Handler)
    if tls_ctx:
        srv.socket = tls_ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def make_cert(d):
    d.mkdir(parents=True, exist_ok=True)
    key, crt = d / "key.pem", d / "cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(crt),
                    "-days", "2", "-subj", "/CN=bad.test", "-addext", "subjectAltName=DNS:bad.test"],
                   check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(crt), str(key))
    return ctx


# ------------------------------------------------------------------ checks

CHECK_RE = re.compile(r"^(?P<area>[\w+\-\[\]]+): (?P<what>\S+) expected=(?P<exp>\S+) got=(?P<got>\S*)(?P<rest>.*)$")
INFO_PREFIXES = ("version:", "flags:", "codec:", "drm:", "cost:", "motion:", "sandbox: proc", "sandbox: process-types",
                 "sandbox: separate-gpu", "sandbox: app-process", "sandbox: chrome-sandbox-page", "ext: builtin",
                 "private: hit", "private: normal-marker", "motw: linux", "nav: qt-default", "crash: renderer-terminated",
                 "tls: certificate-error", "perm: request", "nav: refused", "gates: deadline", "shot:")


def summarize(scenario, lines, out):
    for line in lines:
        m = CHECK_RE.match(line)
        if m:
            ok = m["exp"] == m["got"]
            out.append(f"[{scenario}] {'ok      ' if ok else 'MISMATCH'} {line}")
        elif line.startswith(INFO_PREFIXES):
            out.append(f"[{scenario}] info     {line}")


def harness_check(out, scenario, area, what, expected, got, extra=""):
    ok = str(expected) == str(got)
    out.append(f"[{scenario}] {'ok      ' if ok else 'MISMATCH'} {area}: {what} expected={expected} got={got}"
               + (f" {extra}" if extra else ""))


def load_netlog(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        t = text.rstrip().rstrip(",")
        for tail in ("]}", "}]}", "]}]}"):
            try:
                return json.loads(t + tail)
            except json.JSONDecodeError:
                continue
    return None


def netlog_hosts(path):
    """Every hostname and remote IP the engine's network stack touched."""
    data = load_netlog(path)
    if data is None:
        return None, None
    hosts, addrs = set(), set()

    def take_url(u):
        try:
            p = urllib.parse.urlsplit(u)
        except ValueError:
            return
        if p.scheme in ("http", "https", "ws", "wss") and p.hostname:
            hosts.add(p.hostname.lower())

    def walk(k, v):
        if isinstance(v, dict):
            for kk, vv in v.items():
                walk(kk, vv)
        elif isinstance(v, list):
            for vv in v:
                walk(k, vv)
        elif isinstance(v, str):
            if k in ("url", "original_url", "new_url", "location", "initiator", "redirect_url"):
                take_url(v)
            elif k in ("host", "hostname", "server_host", "host_port", "destination", "proxy_server"):
                h = v.split("://")[-1]
                if h.startswith("["):
                    h = h[1:].split("]")[0]
                else:
                    h = h.rsplit(":", 1)[0] if h.count(":") == 1 else h
                if h:
                    hosts.add(h.lower())
            elif k in ("address", "remote_address", "peer_address"):
                a = v.rsplit(":", 1)[0].strip("[]")
                addrs.add(a)
            elif k == "address_list":
                for a in v.split(","):
                    addrs.add(a.strip().rsplit(":", 1)[0].strip("[]"))

    for ev in data.get("events", []):
        walk("", ev.get("params", {}))
    return hosts, addrs


def netlog_offenders(path):
    """Event and source type names of NetLog events that mention a non-fixture host (no page data)."""
    data = load_netlog(path)
    if data is None:
        return []
    consts = data.get("constants", {})
    ev_names = {v: k for k, v in consts.get("logEventTypes", {}).items()}
    src_names = {v: k for k, v in consts.get("logSourceType", {}).items()}
    out = {}
    for ev in data.get("events", []):
        text = json.dumps(ev.get("params", {}))
        for h in re.findall(r'"(?:host|hostname|url|host_port)": "([^"]+)"', text):
            hh = urllib.parse.urlsplit(h).hostname if "://" in h else h.rsplit(":", 1)[0]
            if hh and not host_allowed(hh.lower()):
                key = (hh, ev_names.get(ev.get("type"), str(ev.get("type"))),
                       src_names.get(ev.get("source", {}).get("type"), "?"))
                out[key] = out.get(key, 0) + 1
    return [{"host": k[0], "event": k[1], "source": k[2], "count": v} for k, v in sorted(out.items())]


def host_allowed(h):
    return h.endswith(".test") or h in ALLOWED_HOSTS


def scan_tree(roots, marker):
    needles = [marker.encode(), marker.encode("utf-16-le")]
    hits, scanned, unreadable = [], 0, 0
    for root in roots:
        root = Path(root)
        if not root.exists():
            continue
        for p in root.rglob("*"):
            try:
                if not p.is_file() or p.stat().st_size > 256 * 1024 * 1024:
                    continue
                data = p.read_bytes()
            except OSError:
                unreadable += 1
                continue
            scanned += 1
            if any(n in data for n in needles):
                hits.append(str(p.relative_to(root)) if p.is_relative_to(root) else str(p))
    return hits, scanned, unreadable


def motw_of(path):
    if not IS_WIN:
        return None
    try:
        with open(str(path) + ":Zone.Identifier", "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# ------------------------------------------------------------------ running

def start_tcp_monitor(out_file, seconds):
    """Windows: every TCP connection owned by the app's processes (catches what the NetLog can't)."""
    if not IS_WIN:
        return None
    script = (f"$end=(Get-Date).AddSeconds({seconds});"
              "while((Get-Date) -lt $end){"
              "$ids=@((Get-Process -Name birch-qt-proto,QtWebEngineProcess -ErrorAction SilentlyContinue).Id);"
              "if($ids.Count -gt 0){Get-NetTCPConnection -ErrorAction SilentlyContinue | "
              "Where-Object { $ids -contains $_.OwningProcess -and $_.RemoteAddress -ne '0.0.0.0' -and "
              "$_.RemoteAddress -ne '::' } | ForEach-Object { \"$($_.RemoteAddress)|$($_.RemotePort)|$($_.State)\" }};"
              "Start-Sleep -Milliseconds 500}")
    return subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                            stdout=open(out_file, "w"), stderr=subprocess.DEVNULL)


def run_app(args, name, gates, extra_env=None, idle=0, netlog=True, strace=False, timeout=420, delay=360):
    print(f"== scenario {name}: gates={gates}", flush=True)
    STATE["scenario"] = name
    out = Path(args.out)
    scratch = Path(tempfile.mkdtemp(prefix=f"birch-qt-{name}-"))
    home = scratch / "birch-home"
    home.mkdir()
    downloads = scratch / "downloads"
    downloads.mkdir()
    netlog_path = Path(args.private_dir) / f"netlog-{name}.json"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BIRCH_", "QTWEBENGINE_"))}
    rules = f"MAP *.test 127.0.0.1,MAP {LOOKALIKE} 127.0.0.1,MAP {AD_HOST} 127.0.0.1"
    flags = [f'"--host-resolver-rules={rules}"', "--use-fake-device-for-media-stream"]
    if netlog:
        flags.append(f'"--log-net-log={netlog_path}"')
    env.update({
        "BIRCH_HOME": str(home),
        "BIRCH_GATES": gates,
        "BIRCH_SNAPSHOT": str(out / f"{name}-window.png"),
        "BIRCH_SHOTS": str(out / f"shots-{name}"),
        "BIRCH_DELAY": str(delay),
        "BIRCH_IDLE": str(idle),
        "BIRCH_DOWNLOADS": str(downloads),
        "BIRCH_FIXTURE_PORT": str(args.port),
        "BIRCH_TLS_PORT": str(args.tls_port),
        "QTWEBENGINE_CHROMIUM_FLAGS": " ".join(flags),
    })
    if args.ubol_zip:
        env["BIRCH_UBOL_ZIP"] = args.ubol_zip
    env["BIRCH_DNR_PROBE"] = str(FIXTURES / "dnr-probe")
    if extra_env:
        env.update({k: v.format(scratch=scratch, home=home) for k, v in extra_env.items()})
    log_path = out / f"{name}.log"
    cmd = [args.app]
    if strace:
        cmd = ["strace", "-f", "-qq", "-e", "trace=socket,connect,sendto,sendmsg", "-o", str(out / f"{name}-strace.txt")] + cmd
    mon = start_tcp_monitor(out / f"{name}-tcp.txt", timeout) if netlog else None
    t0 = time.time()
    with open(log_path, "w", encoding="utf-8", errors="replace") as logf:
        try:
            proc = subprocess.run(cmd, env=env, stdout=logf, stderr=subprocess.STDOUT, timeout=timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    elapsed = time.time() - t0
    if mon:
        mon.terminate()
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    print(f"   exit={code} seconds={elapsed:.0f} lines={len(lines)}", flush=True)
    return {"name": name, "code": code, "lines": lines, "scratch": scratch, "home": home, "downloads": downloads,
            "netlog": netlog_path if netlog else None, "seconds": elapsed}


def main():
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles are cp1252
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--media")
    ap.add_argument("--ubol-zip")
    ap.add_argument("--scenarios", default="refuse,main,baseline,ubol,private,cost")
    ap.add_argument("--strace", action="store_true", help="Linux: also run the network scenario under strace")
    ap.add_argument("--label", default="")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    args.private_dir = tempfile.mkdtemp(prefix="birch-qt-private-")  # NetLogs, cert: never uploaded
    STATE["media"] = args.media
    tls_ctx = make_cert(Path(args.private_dir) / "tls")
    http_srv, tls_srv = free_server(), free_server(tls_ctx)
    args.port, args.tls_port = http_srv.server_address[1], tls_srv.server_address[1]
    print(f"fixtures: http=127.0.0.1:{args.port} https=127.0.0.1:{args.tls_port}", flush=True)

    summary = [f"# Qt WebEngine prototype gate results {args.label}".rstrip(),
               f"# platform={sys.platform} python={sys.version.split()[0]}"]
    wanted = args.scenarios.split(",")
    broken = []
    results = {}

    if "refuse" in wanted:
        STATE["scenario"] = "refuse"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BIRCH_", "QTWEBENGINE_"))}
        env.update({"BIRCH_HOME": tempfile.mkdtemp(prefix="birch-qt-refuse-"), "BIRCH_GATES": "nav",
                    "QTWEBENGINE_CHROMIUM_FLAGS": "--no-sandbox"})
        p = subprocess.run([args.app], env=env, capture_output=True, text=True, timeout=60)
        harness_check(summary, "refuse", "sandbox", "exit-code-with---no-sandbox", 3, p.returncode)
        harness_check(summary, "refuse", "sandbox", "refusal-logged", 1,
                      int("refused-switch" in (p.stdout + p.stderr)))

    scen = {
        "main": dict(gates="nav,tls,perm,download,sandbox,ads,codecs,sidebar", idle=45),
        "baseline": dict(gates="nav,tls,ads", idle=45, extra_env={"BIRCH_BASELINE": "1"}),
        "ubol": dict(gates="ext", idle=30),
        "cost": dict(gates="cost", netlog=False),
        "sandbox": dict(gates="nav,sandbox", netlog=False),
        "strace": dict(gates="nav,ads", idle=20, strace=True),
    }
    for name in wanted:
        if name in ("refuse", "private") or name not in scen:
            continue
        if name == "strace" and not args.strace:
            continue
        r = run_app(args, name, **scen[name])
        results[name] = r
        summarize(name, r["lines"], summary)
        if not any(l.startswith("gates: done") for l in r["lines"]):
            broken.append(name)
            harness_check(summary, name, "gates", "reached-end", 1, 0, f"exit={r['code']}")

    if "private" in wanted:
        mark_norm = f"norm-{secrets.token_hex(4)}"
        mark_priv = f"priv-{secrets.token_hex(4)}"
        extra = {"BIRCH_PERSIST_SCRATCH": "1", "BIRCH_MARK_NORM": mark_norm + ".test",
                 "BIRCH_MARK_PRIV": mark_priv + ".test", "TMP": "{scratch}", "TEMP": "{scratch}", "TMPDIR": "{scratch}"}
        if not IS_WIN:
            extra.update({"HOME": "{scratch}/home", "XDG_CACHE_HOME": "{scratch}/home/.cache",
                          "XDG_DATA_HOME": "{scratch}/home/.local/share", "XDG_CONFIG_HOME": "{scratch}/home/.config"})
        # Where else Qt might write: the app's own standard folders outside the scratch tree.
        app_dirs = []
        if IS_WIN:
            for var in ("LOCALAPPDATA", "APPDATA"):
                if os.environ.get(var):
                    app_dirs.append(Path(os.environ[var]) / "Birch")
        r = run_app(args, "private", "private", extra_env=dict(extra, BIRCH_SCAN_ROOTS="{scratch}"), netlog=True)
        results["private"] = r
        summarize("private", r["lines"], summary)
        if not any(l.startswith("gates: done") for l in r["lines"]):
            broken.append("private")
        roots = [r["scratch"]] + app_dirs
        hits, scanned, unreadable = scan_tree(roots, mark_priv)
        harness_check(summary, "private", "private", "files-with-private-marker-after-exit", 0, len(hits),
                      f"scanned={scanned} unreadable={unreadable} files={hits[:6]}")
        nhits, _, _ = scan_tree(roots, mark_norm)
        harness_check(summary, "private", "private", "normal-marker-found-on-disk-positive-control", 1,
                      int(len(nhits) > 0), f"files={nhits[:4]}")

    # Network: hosts in NetLogs, TCP monitor (Windows), strace (Linux).
    for name, r in results.items():
        if not r.get("netlog"):
            continue
        hosts, addrs = netlog_hosts(r["netlog"]) if Path(r["netlog"]).exists() else (None, None)
        if hosts is None:
            harness_check(summary, name, "netlog", "recorded", 1, 0)
            continue
        bad_hosts = sorted(h for h in hosts if not host_allowed(h))
        if IPV6_PROBE in addrs:
            summary.append(f"[{name}] info     netlog: ipv6-reachability-probe address={IPV6_PROBE} (UDP connect, see strace)")
        bad_addrs = sorted(a for a in addrs if a not in ("127.0.0.1", "::1", "", IPV6_PROBE) and not a.startswith("0.0.0.0"))
        harness_check(summary, name, "netlog", "recorded", 1, 1, f"hosts-seen={len(hosts)}")
        if name == "baseline":
            # Qt's defaults without Birch's extra switches: this is what Birch has to switch off.
            summary.append(f"[{name}] info     netlog: qt-default-non-fixture-hosts count={len(bad_hosts)} list={bad_hosts[:20]}")
        else:
            harness_check(summary, name, "netlog", "non-fixture-hosts", 0, len(bad_hosts), f"list={bad_hosts[:20]}")
        harness_check(summary, name, "netlog", "non-local-addresses", 0, len(bad_addrs), f"list={bad_addrs[:20]}")
        offenders = netlog_offenders(r["netlog"]) if bad_hosts else []
        for o in offenders[:12]:
            summary.append(f"[{name}] info     netlog: offender host={o['host']} event={o['event']} source={o['source']} count={o['count']}")
        (out / f"{name}-netlog-hosts.json").write_text(json.dumps({"hosts": sorted(hosts), "addresses": sorted(addrs)},
                                                                 indent=1))
        tcp = out / f"{name}-tcp.txt"
        if tcp.exists():
            remote = sorted({l.split("|")[0] for l in tcp.read_text(errors="replace").splitlines() if "|" in l})
            nonlocal_ = [a for a in remote if a not in ("127.0.0.1", "::1")]
            harness_check(summary, name, "tcp-monitor", "non-local-connections", 0, len(nonlocal_),
                          f"remotes={remote[:20]}")
    for name, r in results.items():
        st = out / f"{name}-strace.txt"
        if st.exists():
            local = ("127.0.0.1", "::1", "0.0.0.0", "::", "127.0.0.53")
            socktype, pending = {}, {}
            tcp, udp, sent = set(), set(), set()
            for line in st.read_text(errors="replace").splitlines():
                parts = line.split(None, 1)
                if len(parts) < 2:
                    continue
                pid, call = parts
                m = re.match(r"socket\((AF_INET6?), (SOCK_\w+).*\) = (\d+)", call)
                if m:
                    socktype[(pid, m.group(3))] = m.group(2)
                    continue
                m = re.match(r"socket\((AF_INET6?), (SOCK_\w+).*<unfinished", call)
                if m:
                    pending[pid] = m.group(2)
                    continue
                m = re.match(r"<\.\.\. socket resumed>.*= (\d+)", call)
                if m and pid in pending:
                    socktype[(pid, m.group(1))] = pending.pop(pid)
                    continue
                ip = re.search(r'inet_addr\("([\d.]+)"\)|inet_pton\(AF_INET6, "([^"]+)"', call)
                if not ip:
                    continue
                ip = ip.group(1) or ip.group(2)
                if ip in local:
                    continue
                fd = re.match(r"\w+\((\d+),", call)
                kind = socktype.get((pid, fd.group(1) if fd else ""), "?")
                if call.startswith(("sendto(", "sendmsg(")):
                    sent.add(ip)
                elif call.startswith("connect("):
                    (udp if kind == "SOCK_DGRAM" else tcp).add(ip)
            harness_check(summary, name, "strace", "tcp-or-unknown-connects-to-non-local-ip", 0, len(tcp), f"ips={sorted(tcp)}")
            harness_check(summary, name, "strace", "packets-sent-to-non-local-ip", 0, len(sent), f"ips={sorted(sent)}")
            summary.append(f"[{name}] info     strace: udp-connect-only (no data) ips={sorted(udp)}")
            harness_check(summary, name, "strace", "app-reached-end", 1,
                          int(any(l.startswith("gates: done") for l in r["lines"])))

    # Fixture server view of the ad request (uBOL must stop it before it is sent).
    with HITS_LOCK:
        hits = list(HITS)
    for name in ("main", "baseline"):
        if name in results:
            n = sum(1 for s, h, p in hits if s == name and h == AD_HOST)
            harness_check(summary, name, "fixture-server", "ad-requests-received-without-blocker", ">=1",
                          ">=1" if n >= 1 else n, f"count={n}")
    if "ubol" in results:
        n = sum(1 for s, h, p in hits if s == "ubol" and h == AD_HOST)
        summary.append(f"[ubol] info     fixture-server: ad-requests-received count={n} (0 means every blocker test held)")

    # Mark of the Web, checked from outside the app too.
    if IS_WIN and "main" in results:
        files = list(Path(results["main"]["downloads"]).glob("*"))
        z = motw_of(files[0]) if files else None
        zones = re.findall(r"ZoneId=(\d)", z or "")
        harness_check(summary, "main", "motw-external", "zone-identifier-present", 1, int(bool(z)), f"zone={zones}")

    for name, r in results.items():
        summary.append(f"[{name}] info     harness: seconds={r['seconds']:.0f} exit={r['code']}")
    (out / "summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(summary))
    http_srv.shutdown()
    tls_srv.shutdown()
    if broken:
        print(f"harness: scenarios that did not reach their end: {broken}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
