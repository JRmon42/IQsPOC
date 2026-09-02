#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03 - Opt in to Azure AI Search diagnostic logging.
#
# This is the deliberate "customer switches it on" step. Everything that shows
# up in Log Analytics afterwards is proof of what the platform *can* capture -
# and, just as importantly, of what it never captures.
#
# Categories on Microsoft.Search/searchServices:
#   OperationLogs  - administrative, indexing AND query operations
#   AllMetrics     - latency, QPS, throttling
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

iq::header "Available diagnostic categories on Azure AI Search"
az monitor diagnostic-settings categories list --resource "$SEARCH_ID" \
  --query "value[].{name:name,type:properties.categoryType,groups:properties.categoryGroups}" -o table

iq::header "Enabling OperationLogs + AllMetrics -> ${LAW_NAME}"
az monitor diagnostic-settings create \
  --name "iqspoc-search-diag" \
  --resource "$SEARCH_ID" \
  --workspace "$LAW_ID" \
  --logs    '[{"category":"OperationLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]' \
  -o json > "${EVIDENCE_DIR}/c3-diagnostics-enabled.json" 2>&1 \
  && iq::ok "diagnostic setting created on ${SEARCH_NAME}" \
  || { iq::fail "could not create diagnostic setting"; cat "${EVIDENCE_DIR}/c3-diagnostics-enabled.json"; }

iq::header "Enabling Foundry account diagnostics -> ${LAW_NAME}"
# Audit + RequestResponse + Trace. RequestResponse is the interesting one for
# ST: it is the category that could contain prompt/completion metadata.
az monitor diagnostic-settings create \
  --name "iqspoc-foundry-diag" \
  --resource "$FOUNDRY_ID" \
  --workspace "$LAW_ID" \
  --logs    '[{"category":"Audit","enabled":true},{"category":"RequestResponse","enabled":true},{"category":"Trace","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]' \
  -o json > "${EVIDENCE_DIR}/c3-foundry-diagnostics-enabled.json" 2>&1 \
  && iq::ok "diagnostic setting created on ${FOUNDRY_NAME}" \
  || iq::warn "Foundry diagnostics not created - see ${EVIDENCE_DIR}/c3-foundry-diagnostics-enabled.json"

iq::header "Confirming the delta versus the C2 baseline"
az monitor diagnostic-settings list --resource "$SEARCH_ID" \
  --query "value[].{name:name,workspace:workspaceId,logs:logs[?enabled].category,metrics:metrics[?enabled].category}" \
  -o json | tee "${EVIDENCE_DIR}/c3-diagnostics-after.json"

iq::info ""
iq::info "Retention is now governed by the Log Analytics workspace (30 days here),"
iq::info "NOT by Azure AI Search. Change it with:"
iq::info "  az monitor log-analytics workspace update -g ${RG} -n ${LAW_NAME} --retention-time <30-730>"
iq::info ""
iq::info "Ingestion takes 5-15 minutes to first appear. Run src/foundry_iq_test.py"
iq::info "to generate traffic, then scripts/05-query-logs.sh to read it back."
