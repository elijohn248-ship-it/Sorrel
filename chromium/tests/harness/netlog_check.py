#!/usr/bin/env python3
"""Reads a Chromium NetLog and lists every host Birch asked for and every
address it connected or sent packets to. Anything but the local fixture
server (*.birch.test, 127.0.0.1, localhost, ::1) fails, with exactly one
tolerance: the operating system's proxy auto-detection lookup of "wpad"
(Windows' "Automatically detect settings"; Birch follows the OS's proxy
settings by the owner's decision of 2026-11-24). The DNS packets that lookup
causes are excused only when no other non-fixture host was asked for.

A UDP connect() that sends no packet (Chromium's IPv6 reachability probe asks
the OS for a route to 2001:4860:4860::8888) contacts nothing and is reported
separately.

  python3 -I netlog_check.py <netlog.json>        exit 1 on any offender
"""
import json
import re
import sys
from urllib.parse import urlsplit

ALLOWED = re.compile(r"(^|\.)birch\.test$|^127\.0\.0\.1$|^localhost$|^::1$")
WPAD = re.compile(r"^wpad$")
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


def load(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    try:
        return json.loads(text)
    except ValueError:
        # A NetLog cut short by a crash lacks its closing brackets.
        return json.loads(text.rstrip().rstrip(",") + "]}")


def analyze(path):
    data = load(path)
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
                if "://" in v and v.split("://")[0] not in ("http", "https", "ws", "wss"):
                    continue  # birch://, chrome://, data: … never reach the network
                h = host_of(v)
                if h:
                    requested.setdefault(h, set()).add(t)
    probes = sorted({a for a in udp_connect.values() if a not in udp_sent})
    bad_req = {h: sorted(v) for h, v in requested.items() if not ALLOWED.search(h)}
    bad_con = {h: sorted(v) for h, v in contacted.items() if not ALLOWED.search(h)}
    wpad = {h: v for h, v in bad_req.items() if WPAD.match(h)}
    for h in wpad:
        bad_req.pop(h)
    if not bad_req:
        # Only the OS proxy lookup (or nothing) was asked for: DNS packets to
        # the resolver are that lookup's, not a connection to a service.
        bad_con = {k: v for k, v in bad_con.items() if v != ["UDP_BYTES_SENT"]}
    offenders = dict(bad_req, **{"addr " + k: v for k, v in bad_con.items()})
    return {
        "requested": sorted(requested),
        "contacted": sorted(contacted),
        "route_probes": probes,
        "wpad": sorted(wpad),
        "offenders": offenders,
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    r = analyze(sys.argv[1])
    print("netlog: hosts requested: " + ", ".join(r["requested"]))
    print("netlog: addresses contacted: " + ", ".join(r["contacted"]))
    print("netlog: route probes (no packet sent): " + (", ".join(r["route_probes"]) or "none"))
    print("netlog: OS proxy auto-detect (wpad) lookup: " + ("yes" if r["wpad"] else "no"))
    print("netlog: non-fixture requests/connections: "
          + (json.dumps(r["offenders"], sort_keys=True) if r["offenders"] else "none"))
    sys.exit(1 if r["offenders"] else 0)


if __name__ == "__main__":
    main()
