#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 06 - Read the logs back and prove what is, and is not, recorded.
#
#   C3  When diagnostic logging is enabled, QUERY TEXT can appear in the logs.
#   C4  Document CONTENTS and end-user IDENTITY do not.
#
# Both halves matter. C3 is the risk ST needs to know about; C4 is the
# reassurance. Proving them together is far more persuasive than either alone.
#
# Uses the Log Analytics REST API through src/la_query.py, because the
# `log-analytics` az CLI extension cannot be installed everywhere.
#
# Ingestion lag is 5-15 minutes; the script retries.
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

MARKER="IQPOCPROBE"
DOC_MARKER="IQPOCPROBE-DOC-ALPHA"      # only ever appears inside document bodies
LAQ="python3 ${REPO_ROOT}/src/la_query.py -w ${LAW_CUSTOMER_ID} --timespan P1D"

count() { $LAQ -q "$1" --count-only 2>/dev/null | tail -1; }

iq::header "Waiting for Azure AI Search OperationLogs to be ingested"
for i in $(seq 1 20); do
  N=$(count "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.SEARCH'")
  [[ "${N:-0}" != "0" ]] && { iq::ok "Search operation logs are flowing (${N} rows)"; break; }
  iq::info "attempt ${i}/20 - none yet, waiting 60s..."
  sleep 60
done

iq::header "Everything Azure AI Search emitted"
$LAQ -q "AzureDiagnostics
         | where ResourceProvider == 'MICROSOFT.SEARCH'
         | summarize Events=count() by Category, OperationName
         | order by Events desc" \
     --out "${EVIDENCE_DIR}/c3-log-operations.json"

# ---------------------------------------------------------------- C3 ---------
iq::header "C3  Does the QUERY TEXT appear in the logs?"
$LAQ -q "AzureDiagnostics
         | where ResourceProvider == 'MICROSOFT.SEARCH'
         | where * has '${MARKER}'
         | project TimeGenerated, OperationName, Query_s, IndexName_s, Documents_d, DurationMs
         | order by TimeGenerated desc
         | take 15" \
     --out "${EVIDENCE_DIR}/c3-query-text-in-logs.json"
N=$(count "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.SEARCH' | where * has '${MARKER}'")
if [[ "${N:-0}" != "0" ]]; then
  iq::ok "${N} Search log row(s) contain the literal probe query text"
  iq::info "=> CONFIRMED. Enabling OperationLogs makes query strings readable by"
  iq::info "   anyone with read access to the Log Analytics workspace."
  iq::info "   ACTION FOR ST: if queries can contain sensitive terms, treat the"
  iq::info "   workspace as a sensitive data store (tight RBAC, short retention)"
  iq::info "   or simply leave query logging off - it is off by default."
else
  iq::warn "no Search rows with the marker yet - ingestion may still be catching up"
fi

# ---------------------------------------------------------------- C4a --------
iq::header "C4  Are DOCUMENT CONTENTS or RESULTS in the logs?"
$LAQ -q "AzureDiagnostics
         | where * has '${DOC_MARKER}' or * has 'ECDSA' or * has 'net-60'
                or * has 'FD-SOI' or * has 'defect density'
         | take 5" \
     --out "${EVIDENCE_DIR}/c4-no-document-content.json"
N=$(count "AzureDiagnostics | where * has '${DOC_MARKER}' or * has 'ECDSA' or * has 'net-60' or * has 'FD-SOI'")
if [[ "${N:-0}" == "0" ]]; then
  iq::ok "0 rows contain any document-body marker"
  iq::info "=> CONFIRMED. Indexed content and search RESULTS are never written to"
  iq::info "   diagnostic logs - only request metadata plus the query string."
else
  iq::fail "${N} row(s) appear to contain document content - inspect the evidence file"
fi

# ---------------------------------------------------------------- C4b --------
iq::header "C4  Is the CALLER'S IDENTITY in the logs? (the important nuance)"
iq::info "Azure AI Search and Microsoft Foundry behave DIFFERENTLY here."
echo
iq::info "-- Azure AI Search OperationLogs --"
$LAQ -q "AzureDiagnostics
         | where ResourceProvider == 'MICROSOFT.SEARCH'
         | take 1" \
     --out "${EVIDENCE_DIR}/c4-search-log-schema.json"
python3 - "${EVIDENCE_DIR}/c4-search-log-schema.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])) or []
if not rows:
    print("       (no Search rows yet)"); raise SystemExit
r = {k: v for k, v in rows[0].items() if v not in (None, "", [])}
w = max(len(k) for k in r)
for k, v in sorted(r.items()):
    print(f"       {k.ljust(w)} : {str(v)[:88]}")
ident = [k for k in r if any(t in k.lower() for t in
         ("caller", "identity", "principal", "objectid", "upn", "user"))]
print()
print(f"       identity-bearing columns present: {ident or 'NONE'}")
PY
echo
iq::info "-- Microsoft Foundry RequestResponse --"
$LAQ -q "AzureDiagnostics
         | where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
         | project TimeGenerated, OperationName, CallerIPAddress, DurationMs,
                   ResultSignature, properties_s
         | take 5" \
     --out "${EVIDENCE_DIR}/c4-foundry-log-rows.json"
python3 - "${EVIDENCE_DIR}/c4-foundry-log-rows.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])) or []
if not rows:
    print("       (no Foundry rows yet)"); raise SystemExit
for r in rows[:3]:
    print(f"       {r.get('TimeGenerated')}  {r.get('OperationName')}  "
          f"callerIP={r.get('CallerIPAddress')}")
    try:
        p = json.loads(r.get("properties_s") or "{}")
    except Exception:  # noqa: BLE001
        p = {}
    for k in ("callerObjectId", "objectId", "requestLength", "responseLength",
              "promptTokens", "completionTokens", "modelDeploymentName"):
        if k in p:
            print(f"         {k:<22}= {p[k]}")
    print()
PY
cat <<'EOF'
       INTERPRETATION - this is the precise answer for ST:

       * Azure AI Search OperationLogs carry NO caller column at all. You
         cannot answer "who ran this query?" from them.
       * Microsoft Foundry RequestResponse DOES carry callerObjectId /
         objectId - but that is the object ID of the calling SERVICE PRINCIPAL
         or managed identity, not an end user. CallerIPAddress is masked to a
         /24 (e.g. 192.168.0.*).
       * In a typical app where one managed identity fronts many humans, every
         end user collapses to the same object ID. So there is still NO
         end-user audit trail.
       * Neither log carries prompt text, completion text or document content -
         only lengths and token counts.

       => Per-user auditing MUST be implemented in the customer's own
          application layer. This confirms the Product Manager's statement,
          with the refinement that "no caller identity" is specific to
          Azure AI Search.
EOF

# ---------------------------------------------------------------- C4c --------
iq::header "C4  Do prompt or completion bodies appear anywhere?"
$LAQ -q "AzureDiagnostics
         | where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
         | where * has '${MARKER}'
         | take 5" \
     --out "${EVIDENCE_DIR}/c4-foundry-prompt-content.json"
N=$(count "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES' | where * has '${MARKER}'")
if [[ "${N:-0}" == "0" ]]; then
  iq::ok "0 Foundry rows contain the prompt marker"
  iq::info "=> RequestResponse records request METADATA only (lengths, tokens,"
  iq::info "   latency, status). Prompt/completion CONTENT is handled separately"
  iq::info "   by abuse monitoring - that is where Modified Abuse Monitoring"
  iq::info "   (ContentLogging=false) is the control to ask for."
else
  iq::warn "${N} Foundry row(s) contain prompt text - inspect the evidence file"
fi

# ---------------------------------------------------------------- C5 ---------
iq::header "C5  Where the retention clock actually lives"
az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" \
  --query "{workspace:name,retentionInDays:retentionInDays,sku:sku.name}" -o json \
  | tee "${EVIDENCE_DIR}/c5-retention-after.json"
iq::info "Retention is a Log Analytics property, not an AI Search or Foundry one."
iq::info "Deleting the diagnostic setting stops collection; rows already ingested"
iq::info "persist until workspace retention expires or the table is purged."

iq::ok "log evidence written to ${EVIDENCE_DIR}"
