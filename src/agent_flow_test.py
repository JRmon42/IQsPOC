#!/usr/bin/env python3
"""
Exercise a NETWORK-INJECTED Foundry agent against Foundry IQ and Web IQ.

Runs ON the in-VNet VM (the project endpoint has public access disabled), and
authenticates with the VM's managed identity.

Two agents are created so the two flows can be observed separately:

  agent A -> azure_ai_search tool  (Foundry IQ)  : should stay on the backbone
  agent B -> bing_grounding tool   (Web IQ)      : must egress to the internet

Marker strings are planted in the prompts so the same query text can later be
located in - or shown to be absent from - the diagnostic logs.
"""
import json
import sys
import time
import urllib.error
import urllib.request

PROJECT_ENDPOINT = "https://iqspoc-foundry-lnoqy4pkotz5c.services.ai.azure.com/api/projects/iqspoc-project"
API = "2025-05-01"
MODEL = "gpt-4.1-mini"
SEARCH_CONN = "searchconn"
BING_CONN = "binggrounding"
INDEX = "iqspoc-index"

MARKER_FOUNDRY = "IQPOCAGENT-FOUNDRY"
MARKER_WEB = "IQPOCAGENT-WEB"

results = {"agents": [], "runs": [], "errors": []}


def token(resource="https://ai.azure.com"):
    url = ("http://169.254.169.254/metadata/identity/oauth2/token"
           f"?api-version=2018-02-01&resource={resource}")
    r = urllib.request.Request(url, headers={"Metadata": "true"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.load(resp)["access_token"]


TOK = token()
H = {"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"}


def call(path, method="GET", body=None):
    url = f"{PROJECT_ENDPOINT}{path}"
    url += ("&" if "?" in url else "?") + f"api-version={API}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, headers=H, method=method)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:900]}
    except Exception as e:  # network-level failure is itself a result
        return 0, {"exception": str(e)}


def make_agent(name, instructions, tools, tool_resources=None):
    body = {"model": MODEL, "name": name, "instructions": instructions,
            "tools": tools}
    if tool_resources:
        body["tool_resources"] = tool_resources
    s, d = call("/assistants", "POST", body)
    print(f"  create agent {name}: HTTP {s}")
    if s not in (200, 201):
        print("   ", json.dumps(d)[:500])
        results["errors"].append({"stage": f"create:{name}", "status": s, "body": d})
        return None
    results["agents"].append({"name": name, "id": d.get("id"), "tools": [t.get("type") for t in tools]})
    return d["id"]


def run_agent(agent_id, prompt, label):
    """Create a thread, post the prompt, run it, and poll to completion."""
    s, th = call("/threads", "POST", {})
    if s not in (200, 201):
        results["errors"].append({"stage": f"thread:{label}", "status": s, "body": th})
        print(f"  thread create failed: HTTP {s}")
        return
    tid = th["id"]
    call(f"/threads/{tid}/messages", "POST", {"role": "user", "content": prompt})
    s, run = call(f"/threads/{tid}/runs", "POST", {"assistant_id": agent_id})
    if s not in (200, 201):
        results["errors"].append({"stage": f"run:{label}", "status": s, "body": run})
        print(f"  run create failed: HTTP {s}  {json.dumps(run)[:300]}")
        return
    rid = run["id"]
    status = run.get("status")
    for _ in range(60):
        if status in ("completed", "failed", "cancelled", "expired"):
            break
        time.sleep(5)
        _, run = call(f"/threads/{tid}/runs/{rid}")
        status = run.get("status")
    print(f"  run {label}: {status}")

    answer, steps = "", []
    if status == "completed":
        _, msgs = call(f"/threads/{tid}/messages")
        for m in msgs.get("data", []):
            if m.get("role") == "assistant":
                for c in m.get("content", []):
                    if c.get("type") == "text":
                        answer = c["text"]["value"]
                break
    _, sd = call(f"/threads/{tid}/runs/{rid}/steps")
    for st in sd.get("data", []):
        det = st.get("step_details", {})
        for tc in det.get("tool_calls", []) or []:
            steps.append(tc.get("type"))

    results["runs"].append({
        "label": label, "thread": tid, "run": rid, "status": status,
        "tool_calls": steps, "last_error": run.get("last_error"),
        "usage": run.get("usage"),
        "answer_excerpt": answer[:600],
    })
    if answer:
        print(f"    answer: {answer[:200].replace(chr(10), ' ')}")
    if steps:
        print(f"    tools invoked: {steps}")
    if run.get("last_error"):
        print(f"    last_error: {json.dumps(run['last_error'])[:300]}")


print("=== A. Foundry IQ agent (azure_ai_search tool) ===")
conn_id = (f"/subscriptions/7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa/resourceGroups/rg-iqs-poc-sc"
           f"/providers/Microsoft.CognitiveServices/accounts/iqspoc-foundry-lnoqy4pkotz5c"
           f"/projects/iqspoc-project/connections/{SEARCH_CONN}")
a = make_agent(
    "iqspoc-foundry-agent",
    "You answer strictly from the attached Azure AI Search index. Cite what you find.",
    [{"type": "azure_ai_search"}],
    {"azure_ai_search": {"indexes": [{
        "index_connection_id": conn_id,
        "index_name": INDEX,
        "query_type": "simple",
    }]}},
)
if a:
    run_agent(a, f"{MARKER_FOUNDRY} What do the documents say about secure boot "
                 "signature validation and ECDSA?", "foundry-iq")

print("\n=== B. Web IQ agent (bing_grounding tool) ===")
bing_id = (f"/subscriptions/7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa/resourceGroups/rg-iqs-poc-sc"
           f"/providers/Microsoft.CognitiveServices/accounts/iqspoc-foundry-lnoqy4pkotz5c"
           f"/projects/iqspoc-project/connections/{BING_CONN}")
b = make_agent(
    "iqspoc-webiq-agent",
    "You answer using live web results. Always cite your sources.",
    [{"type": "bing_grounding",
      "bing_grounding": {"search_configurations": [
          {"connection_id": bing_id, "count": 3, "market": "en-US"}]}}],
)
if b:
    run_agent(b, f"{MARKER_WEB} What is STMicroelectronics' most recent published "
                 "quarterly revenue?", "web-iq")

print("\n=== RESULTS_JSON_BEGIN ===")
print(json.dumps(results, indent=2))
print("=== RESULTS_JSON_END ===")
