#!/usr/bin/env python3
"""
The azure_ai_search tool returned HTTP 500 on agent creation. A 500 (rather
than a 400) usually means the service accepted the shape but failed to resolve
something inside it - most often the connection identifier format.

This tries the known formats in turn and reports which one the service accepts,
so the answer is determined rather than guessed.
"""
import json
import urllib.error
import urllib.request

EP = "https://iqspoc-foundry-lnoqy4pkotz5c.services.ai.azure.com/api/projects/iqspoc-project"
API = "2025-05-01"
MODEL = "gpt-4.1-mini"
INDEX = "iqspoc-index"
SUB = "7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa"
RG = "rg-iqs-poc-sc"
ACC = "iqspoc-foundry-lnoqy4pkotz5c"
PRJ = "iqspoc-project"


def token(res="https://ai.azure.com"):
    u = f"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={res}"
    r = urllib.request.Request(u, headers={"Metadata": "true"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.load(resp)["access_token"]


H = {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def post(path, body):
    url = f"{EP}{path}?api-version={API}"
    r = urllib.request.Request(url, data=json.dumps(body).encode(), headers=H, method="POST")
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}
    except Exception as e:
        return 0, {"exception": str(e)}


CANDIDATES = {
    "1_name_only": "searchconn",
    "2_cogsvc_project_arm": (f"/subscriptions/{SUB}/resourceGroups/{RG}/providers"
                             f"/Microsoft.CognitiveServices/accounts/{ACC}/projects/{PRJ}"
                             f"/connections/searchconn"),
    "3_aml_workspace_arm": (f"/subscriptions/{SUB}/resourceGroups/{RG}/providers"
                            f"/Microsoft.MachineLearningServices/workspaces/{PRJ}"
                            f"/connections/searchconn"),
    "4_cogsvc_account_arm": (f"/subscriptions/{SUB}/resourceGroups/{RG}/providers"
                             f"/Microsoft.CognitiveServices/accounts/{ACC}"
                             f"/connections/searchconn"),
}

print("=== azure_ai_search connection-id format probe ===")
winner = None
for label, cid in CANDIDATES.items():
    body = {
        "model": MODEL,
        "name": f"probe-{label}",
        "instructions": "probe",
        "tools": [{"type": "azure_ai_search"}],
        "tool_resources": {"azure_ai_search": {"indexes": [
            {"index_connection_id": cid, "index_name": INDEX, "query_type": "simple"}
        ]}},
    }
    s, d = post("/assistants", body)
    msg = json.dumps(d)[:150] if s not in (200, 201) else d.get("id")
    print(f"  {label:<24} HTTP {s}  {msg}")
    if s in (200, 201) and winner is None:
        winner = (label, cid, d.get("id"))

print()
if winner:
    print(f"ACCEPTED FORMAT: {winner[0]}")
    print(f"  {winner[1]}")
    print(f"  agent id: {winner[2]}")
else:
    print("No connection-id format was accepted.")
    print("Falling back: probe whether the tool works with NO tool_resources.")
    s, d = post("/assistants", {
        "model": MODEL, "name": "probe-bare",
        "instructions": "probe", "tools": [{"type": "azure_ai_search"}]})
    print(f"  bare azure_ai_search tool -> HTTP {s} {json.dumps(d)[:200]}")
