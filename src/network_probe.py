#!/usr/bin/env python3
"""
network_probe.py - probe a set of endpoints and classify how they resolve and
whether they are reachable from wherever this script is running.

Run it from OUTSIDE the VNet (your laptop / this host) and then again from a VM
INSIDE snet-app. The two result sets, side by side, are the clearest possible
demonstration of what Private Link actually does:

    outside the VNet : name -> public CNAME -> connection refused / 403
    inside  the VNet : name -> 10.30.2.x   -> 200 / 401 (i.e. it answers)

Usage:
    python3 network_probe.py --endpoints https://a https://b --out probe.json
    python3 network_probe.py --from-outputs out/deployment-outputs.json
"""
from __future__ import annotations

import argparse
import json
import socket
import ssl
import sys
import time
from urllib.parse import urlparse

PRIVATE_PREFIXES = ("10.", "192.168.", "172.16.", "172.17.", "172.18.", "172.19.",
                    "172.20.", "172.21.", "172.22.", "172.23.", "172.24.",
                    "172.25.", "172.26.", "172.27.", "172.28.", "172.29.",
                    "172.30.", "172.31.")


def is_private(ip: str) -> bool:
    return ip.startswith(PRIVATE_PREFIXES)


def resolve(host: str) -> dict:
    """Full CNAME chain is not exposed by getaddrinfo; capture what we can."""
    out = {"host": host, "addresses": [], "error": None, "canonical": None}
    try:
        canon, _aliases, addrs = socket.gethostbyname_ex(host)
        out["canonical"] = canon
        out["addresses"] = addrs
    except Exception as exc:  # noqa: BLE001
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def tcp_probe(host: str, port: int, timeout: float = 6.0) -> dict:
    out = {"port": port, "connected": False, "tls": None, "error": None,
           "elapsed_ms": None}
    t0 = time.time()
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            out["connected"] = True
            if port == 443:
                ctx = ssl.create_default_context()
                with ctx.wrap_socket(sock, server_hostname=host) as tls:
                    out["tls"] = {
                        "version": tls.version(),
                        "cipher": tls.cipher()[0] if tls.cipher() else None,
                    }
    except Exception as exc:  # noqa: BLE001
        out["error"] = f"{type(exc).__name__}: {exc}"
    out["elapsed_ms"] = round((time.time() - t0) * 1000, 1)
    return out


def https_probe(url: str, timeout: float = 10.0) -> dict:
    """An HTTP status is far more informative than 'connected: true'.

    403 with a Private-Link message  -> public access is blocked (expected)
    401                              -> reachable, just unauthenticated
    connection error                 -> blocked at the network layer
    """
    import urllib.error
    import urllib.request

    out = {"status": None, "error": None, "body_snippet": None}
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            out["status"] = resp.status
            out["body_snippet"] = resp.read(400).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        out["status"] = exc.code
        try:
            out["body_snippet"] = exc.read(400).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            pass
    except Exception as exc:  # noqa: BLE001
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def classify(dns: dict, http: dict) -> str:
    if dns["error"]:
        return "DNS_FAILED"
    private = any(is_private(a) for a in dns["addresses"])
    if private:
        return "PRIVATE_PATH"            # resolved to an RFC1918 address
    status = http.get("status")
    if status in (403,):
        return "PUBLIC_BLOCKED"          # resolves publicly but service refuses
    if http.get("error"):
        return "PUBLIC_UNREACHABLE"
    if status in (401, 400, 404):
        return "PUBLIC_REACHABLE"
    return "PUBLIC_REACHABLE"


def probe(url: str) -> dict:
    parsed = urlparse(url if "//" in url else f"https://{url}")
    host = parsed.hostname or url
    dns = resolve(host)
    tcp = tcp_probe(host, 443) if not dns["error"] else {"connected": False,
                                                        "error": "skipped - DNS failed"}
    http = https_probe(f"https://{host}/") if not dns["error"] else {"error": "skipped"}
    return {
        "url": url,
        "host": host,
        "dns": dns,
        "tcp": tcp,
        "http": http,
        "verdict": classify(dns, http),
    }


VERDICT_MEANING = {
    "PRIVATE_PATH":       "resolved to a private IP - traffic stays on the Microsoft backbone via Private Link",
    "PUBLIC_BLOCKED":     "resolves publicly but the service refuses the caller (publicNetworkAccess=Disabled)",
    "PUBLIC_UNREACHABLE": "no TCP/TLS path from here at all",
    "PUBLIC_REACHABLE":   "reachable over the public internet",
    "DNS_FAILED":         "name did not resolve",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--endpoints", nargs="*", default=[])
    ap.add_argument("--from-outputs", help="path to deployment-outputs.json")
    ap.add_argument("--out", help="write JSON results here")
    args = ap.parse_args()

    targets = list(args.endpoints)
    if args.from_outputs:
        d = json.load(open(args.from_outputs))
        g = lambda k: d.get(k, {}).get("value")  # noqa: E731
        for u in (g("searchEndpoint"), g("foundryEndpoint")):
            if u:
                targets.append(u)
        if g("storageAccountName"):
            targets.append(f"https://{g('storageAccountName')}.blob.core.windows.net/")
        if g("cosmosName"):
            targets.append(f"https://{g('cosmosName')}.documents.azure.com/")
    # Control endpoints: these must always be publicly reachable, which proves
    # the probe host itself has working internet and that a negative result for
    # the private services is meaningful.
    targets += ["https://login.microsoftonline.com/", "https://api.bing.microsoft.com/"]

    if not targets:
        ap.error("no endpoints given")

    results = [probe(t) for t in dict.fromkeys(targets)]

    width = max(len(r["host"]) for r in results)
    print(f"\n  {'HOST'.ljust(width)}  {'RESOLVED TO':<40} {'HTTP':<6} VERDICT")
    print(f"  {'-' * width}  {'-' * 40} {'-' * 6} {'-' * 20}")
    for r in results:
        addrs = ",".join(r["dns"]["addresses"]) or (r["dns"]["error"] or "-")
        st = str(r["http"].get("status") or "-")
        print(f"  {r['host'].ljust(width)}  {addrs[:40]:<40} {st:<6} {r['verdict']}")
    print()
    for v in dict.fromkeys(r["verdict"] for r in results):
        print(f"  {v:<20} {VERDICT_MEANING.get(v, '')}")
    print()

    if args.out:
        with open(args.out, "w") as fh:
            json.dump({"probedFrom": socket.gethostname(),
                       "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "results": results}, fh, indent=2)
        print(f"  written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
