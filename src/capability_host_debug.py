#!/usr/bin/env python3
"""
Create the project capability host and follow the Azure-AsyncOperation header
so the REAL failure reason is visible.

`az rest` discards response headers, so a failed long-running ARM operation
just shows up as provisioningState=Failed with no explanation. This script
keeps the header and polls the operation endpoint, which does carry the error.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

SUB = "7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa"
RG = "rg-iqs-poc-sc"
ACC = "iqspoc-foundry-lnoqy4pkotz5c"
PROJ = "iqspoc-project"
API = "2025-06-01"
ARM = "https://management.azure.com"

tok = subprocess.run(
    ["az", "account", "get-access-token", "--resource", ARM, "--query", "accessToken", "-o", "tsv"],
    capture_output=True, text=True, check=True).stdout.strip()
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}

base = (f"{ARM}/subscriptions/{SUB}/resourceGroups/{RG}/providers"
        f"/Microsoft.CognitiveServices/accounts/{ACC}/projects/{PROJ}"
        f"/capabilityHosts/iqspocprojhost?api-version={API}")


def req(url, method, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, headers=H, method=method)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, dict(resp.headers), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


# Remove any previous failed instance so the create is clean.
print("deleting any existing capability host ...")
req(base, "DELETE")
for _ in range(20):
    s, _, b = req(base, "GET")
    if s == 404:
        print("  gone")
        break
    time.sleep(10)

body = {"properties": {
    "capabilityHostKind": "Agents",
    "vectorStoreConnections": ["searchconn"],
    "storageConnections": ["storageconn"],
    "threadStorageConnections": ["cosmosconn"],
}}
print("creating capability host ...")
status, headers, payload = req(base, "PUT", body)
print(f"  PUT -> HTTP {status}")

op = headers.get("Azure-AsyncOperation") or headers.get("azure-asyncoperation") \
     or headers.get("Location") or headers.get("location")
if not op:
    print("  no async operation header; body was:")
    print(payload[:2000])
    sys.exit(0)

print(f"  polling {op[:110]} ...")
for i in range(40):
    s, _, b = req(op, "GET")
    try:
        d = json.loads(b)
    except Exception:
        print(f"  attempt {i}: HTTP {s} (unparseable)")
        time.sleep(15)
        continue
    st = d.get("status") or d.get("properties", {}).get("provisioningState")
    print(f"  attempt {i}: {st}")
    if st in ("Succeeded", "Failed", "Canceled"):
        print("\n=== FULL OPERATION PAYLOAD ===")
        print(json.dumps(d, indent=2)[:4000])
        break
    time.sleep(15)
