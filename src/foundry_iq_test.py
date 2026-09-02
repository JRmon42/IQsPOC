#!/usr/bin/env python3
"""
foundry_iq_test.py - end-to-end Foundry IQ exercise, run from INSIDE the VNet.

What it does, and why each step matters to the customer conversation:

  1. Creates an Azure AI Search index and pushes a handful of documents.
     -> demonstrates concretely that Foundry IQ's storage/retrieval substrate
        is Azure AI Search, in the customer's own subscription and geography.

  2. Runs a set of deliberately distinctive queries.
     -> the query strings are chosen so they can be searched for verbatim in
        Log Analytics afterwards. This is how we prove BOTH halves of the
        Product Manager's statement: query text CAN appear in OperationLogs,
        while the caller's user identity and document contents do NOT.

  3. Calls the chat model through the Foundry endpoint.
     -> proves the inference path also traverses the private endpoint.

  4. Best-effort: creates a Foundry IQ knowledge base / knowledge source.
     -> preview surface; the script records whatever the API returns rather
        than failing the run.

Authentication is always Entra ID (managed identity on the VM). No keys exist:
the services were deployed with disableLocalAuth / allowSharedKeyAccess=false.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_VERSION = "2024-07-01"

# The marker makes these queries trivially greppable in Log Analytics later.
MARKER = "IQPOCPROBE"

SAMPLE_DOCS = [
    {
        "id": "1",
        "title": "STM32 Secure Boot",
        "content": (
            "The STM32 secure boot chain validates firmware signatures using an "
            "ECDSA public key stored in one-time programmable memory. "
            f"Internal reference {MARKER}-DOC-ALPHA. "
            "Confidential design note: rotation of the OTP key is not possible."
        ),
        "category": "security",
    },
    {
        "id": "2",
        "title": "Wafer Fab Yield Report",
        "content": (
            "Quarterly yield for the 28nm FD-SOI line reached 94.2 percent. "
            f"Internal reference {MARKER}-DOC-BRAVO. "
            "Confidential: defect density attributed to lithography overlay drift."
        ),
        "category": "manufacturing",
    },
    {
        "id": "3",
        "title": "Supplier Contract Terms",
        "content": (
            "Payment terms with the substrate supplier are net-60 with a 2 percent "
            f"early settlement discount. Internal reference {MARKER}-DOC-CHARLIE. "
            "Confidential: unit pricing schedule attached."
        ),
        "category": "procurement",
    },
]

PROBE_QUERIES = [
    f"{MARKER} secure boot signature validation",
    f"{MARKER} wafer yield defect density",
    f"{MARKER} supplier payment terms net-60",
]


def token(scope: str) -> str:
    """Fetch an Entra token, preferring the VM's managed identity."""
    try:
        from azure.identity import DefaultAzureCredential

        return DefaultAzureCredential().get_token(scope).token
    except Exception:  # noqa: BLE001 - fall back to raw IMDS
        resource = scope.replace("/.default", "")
        url = ("http://169.254.169.254/metadata/identity/oauth2/token"
               f"?api-version=2018-02-01&resource={resource}")
        req = urllib.request.Request(url, headers={"Metadata": "true"})
        with urllib.request.urlopen(req, timeout=15) as r:  # noqa: S310
            return json.load(r)["access_token"]


def call(method: str, url: str, tok: str, body: dict | None = None) -> tuple[int, object]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310
            raw = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except Exception:  # noqa: BLE001
            return exc.code, raw
    except Exception as exc:  # noqa: BLE001
        return -1, f"{type(exc).__name__}: {exc}"


def step(msg: str) -> None:
    print(f"\n=== {msg} ===")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--search-endpoint", default=os.environ.get("SEARCH_ENDPOINT"))
    ap.add_argument("--foundry-endpoint", default=os.environ.get("FOUNDRY_ENDPOINT"))
    ap.add_argument("--model", default=os.environ.get("MODEL_NAME", "gpt-4.1-mini"))
    ap.add_argument("--index", default="iqspoc-index")
    ap.add_argument("--model-resource-uri", default=os.environ.get("MODEL_RESOURCE_URI"),
                    help="Azure OpenAI endpoint for the knowledge base model. "
                         "Must be the *.openai.azure.com form so it matches the "
                         "shared private link's private DNS zone.")
    ap.add_argument("--out", default="/tmp/foundry_iq_results.json")
    args = ap.parse_args()

    if not args.search_endpoint:
        ap.error("--search-endpoint is required")

    if not args.model_resource_uri and args.foundry_endpoint:
        # https://<sub>.cognitiveservices.azure.com/ -> https://<sub>.openai.azure.com
        host = args.foundry_endpoint.split("//", 1)[-1].split("/", 1)[0]
        args.model_resource_uri = f"https://{host.split('.', 1)[0]}.openai.azure.com"

    results: dict = {"marker": MARKER, "steps": []}
    record = lambda name, status, detail: results["steps"].append(  # noqa: E731
        {"step": name, "status": status, "detail": detail})

    search_tok = token("https://search.azure.com/.default")

    # -- 1. index ------------------------------------------------------------
    step("1. Create the Azure AI Search index that backs Foundry IQ")
    index_def = {
        "name": args.index,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "title", "type": "Edm.String", "searchable": True},
            {"name": "content", "type": "Edm.String", "searchable": True},
            {"name": "category", "type": "Edm.String", "filterable": True, "facetable": True},
        ],
        "semantic": {
            "configurations": [{
                "name": "default",
                "prioritizedFields": {
                    "titleField": {"fieldName": "title"},
                    "prioritizedContentFields": [{"fieldName": "content"}],
                },
            }]
        },
    }
    st, body = call("PUT",
                    f"{args.search_endpoint}/indexes/{args.index}?api-version={API_VERSION}",
                    search_tok, index_def)
    print(f"  PUT /indexes/{args.index} -> HTTP {st}")
    record("create_index", st, args.index if st < 300 else body)
    if st >= 300:
        print(json.dumps(body, indent=2)[:800])
        return 1

    # -- 2. documents --------------------------------------------------------
    step("2. Upload documents (they stay in the customer's own search service)")
    payload = {"value": [{"@search.action": "mergeOrUpload", **d} for d in SAMPLE_DOCS]}
    st, body = call("POST",
                    f"{args.search_endpoint}/indexes/{args.index}/docs/index?api-version={API_VERSION}",
                    search_tok, payload)
    print(f"  POST docs/index -> HTTP {st}")
    record("upload_documents", st, len(SAMPLE_DOCS))
    time.sleep(5)

    # -- 3. queries ----------------------------------------------------------
    step("3. Run marked queries (these strings are what we hunt for in the logs)")
    query_log = []
    for q in PROBE_QUERIES:
        st, body = call("POST",
                        f"{args.search_endpoint}/indexes/{args.index}/docs/search?api-version={API_VERSION}",
                        search_tok,
                        {"search": q, "top": 3, "queryType": "semantic",
                         "semanticConfiguration": "default"})
        hits = len(body.get("value", [])) if isinstance(body, dict) else 0
        print(f"  HTTP {st}  hits={hits}  q={q!r}")
        query_log.append({"query": q, "status": st, "hits": hits})
    record("queries", 200, query_log)
    print("\n  NOTE: each of these query strings is now eligible to appear in")
    print("  AzureDiagnostics / OperationLogs. The caller identity behind them")
    print("  is NOT recorded - scripts/05-query-logs.sh proves both points.")

    # -- 4. inference --------------------------------------------------------
    if args.foundry_endpoint:
        step("4. Call the chat model through the Foundry private endpoint")
        ftok = token("https://cognitiveservices.azure.com/.default")
        url = (f"{args.foundry_endpoint.rstrip('/')}/openai/deployments/{args.model}"
               f"/chat/completions?api-version=2024-10-21")
        st, body = call("POST", url, ftok, {
            "messages": [
                {"role": "system", "content": "Answer only from the supplied context."},
                {"role": "user",
                 "content": f"Context: {SAMPLE_DOCS[0]['content']}\n\n"
                            f"Question: {MARKER} how are firmware signatures validated?"},
            ],
            "max_tokens": 120,
        })
        print(f"  POST chat/completions -> HTTP {st}")
        if st < 300 and isinstance(body, dict):
            print("  answer:", body["choices"][0]["message"]["content"][:220])
            record("inference", st, body.get("usage"))
        else:
            print("  ", str(body)[:400])
            record("inference", st, str(body)[:400])

    # -- 5. Foundry IQ knowledge base (preview, best effort) -----------------
    step("5. Foundry IQ knowledge source + knowledge base (preview API)")
    # knowledgeSources and knowledgeBases landed on different preview versions.
    KS_API, KB_API = "2025-08-01-preview", "2025-11-01-preview"
    ks_name, kb_name = "iqspoc-ks", "iqspoc-kb"

    st, body = call("PUT",
                    f"{args.search_endpoint}/knowledgeSources/{ks_name}?api-version={KS_API}",
                    search_tok,
                    {"name": ks_name, "kind": "searchIndex",
                     "searchIndexParameters": {"searchIndexName": args.index}})
    print(f"  PUT /knowledgeSources/{ks_name} -> HTTP {st}")
    record("knowledge_source", st, body)

    kb_def = {
        "name": kb_name,
        "knowledgeSources": [{"name": ks_name}],
        "models": [{
            "kind": "azureOpenAI",
            "azureOpenAIParameters": {
                # NOTE: this MUST be the *.openai.azure.com form. The shared
                # private link that Azure AI Search opens towards the model uses
                # group id 'openai_account', whose private DNS zone is
                # privatelink.openai.azure.com. Pointing this at the
                # *.cognitiveservices.azure.com hostname makes Search resolve a
                # public name instead, and the call is refused with
                # "Public access is disabled. Please configure private endpoint."
                "resourceUri": args.model_resource_uri,
                "deploymentId": args.model,
                "modelName": args.model,
            },
        }],
    }
    st, body = call("PUT",
                    f"{args.search_endpoint}/knowledgeBases/{kb_name}?api-version={KB_API}",
                    search_tok, kb_def)
    print(f"  PUT /knowledgeBases/{kb_name} -> HTTP {st}")
    record("knowledge_base", st, body)

    # -- 6. agentic retrieval against the knowledge base ---------------------
    if st < 300:
        step("6. Agentic retrieval through the Foundry IQ knowledge base")
        st, body = call(
            "POST",
            f"{args.search_endpoint}/knowledgeBases/{kb_name}/retrieve?api-version={KB_API}",
            search_tok,
            {"messages": [{"role": "user", "content": [
                {"type": "text",
                 "text": f"{MARKER} what protects the STM32 firmware signature?"}]}]},
        )
        print(f"  POST /knowledgeBases/{kb_name}/retrieve -> HTTP {st}")
        if isinstance(body, dict):
            print("  ", json.dumps(body)[:500])
        record("agentic_retrieval", st, body if isinstance(body, dict) else str(body)[:500])
        print("\n  This is Foundry IQ doing query planning + retrieval + synthesis")
        print("  entirely inside the customer's own Azure AI Search service.")
    else:
        print("  (knowledge base not created - recorded, not fatal)")

    with open(args.out, "w") as fh:
        json.dump(results, fh, indent=2)
    print(f"\n  results written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
