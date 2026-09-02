#!/usr/bin/env python3
"""
la_query.py - run a KQL query against a Log Analytics workspace.

The `log-analytics` az CLI extension cannot be installed on every machine
(it needs a working pip toolchain), so this talks to the Log Analytics REST
API directly and reuses whatever credential `az` already has.

Output is a JSON array of row objects, which is much easier to assert on than
the API's native columns/rows shape.

Usage:
    python3 la_query.py --workspace <customerId> --query "AzureDiagnostics | take 5"
    python3 la_query.py -w <id> -q "..." --out rows.json --count-only
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.loganalytics.io"


def get_token() -> str:
    out = subprocess.run(
        ["az", "account", "get-access-token", "--resource", API,
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def query(workspace: str, kql: str, timespan: str | None = None) -> list[dict]:
    body: dict = {"query": kql}
    if timespan:
        body["timespan"] = timespan
    req = urllib.request.Request(
        f"{API}/v1/workspaces/{workspace}/query",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {get_token()}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:  # noqa: S310
            payload = json.load(r)
    except urllib.error.HTTPError as exc:
        sys.stderr.write(exc.read().decode("utf-8", "replace") + "\n")
        return []

    tables = payload.get("tables") or []
    if not tables:
        return []
    t = tables[0]
    cols = [c["name"] for c in t["columns"]]
    return [dict(zip(cols, row)) for row in t["rows"]]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-w", "--workspace", required=True, help="workspace customerId (GUID)")
    ap.add_argument("-q", "--query", required=True)
    ap.add_argument("--timespan", default="P1D")
    ap.add_argument("--out")
    ap.add_argument("--count-only", action="store_true")
    ap.add_argument("--columns", nargs="*", help="only print these columns")
    args = ap.parse_args()

    rows = query(args.workspace, args.query, args.timespan)

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(rows, fh, indent=2, default=str)

    if args.count_only:
        print(len(rows))
        return 0

    if not rows:
        print("  (0 rows)")
        return 0

    keys = args.columns or [k for k in rows[0] if any(
        r.get(k) not in (None, "", []) for r in rows)]
    width = {k: max(len(k), *(len(str(r.get(k, ""))[:60]) for r in rows)) for k in keys}
    print("  " + "  ".join(k.ljust(width[k]) for k in keys))
    print("  " + "  ".join("-" * width[k] for k in keys))
    for r in rows:
        print("  " + "  ".join(str(r.get(k, ""))[:60].ljust(width[k]) for k in keys))
    print(f"\n  ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
