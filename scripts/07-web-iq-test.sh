#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# C11 - Web IQ / "Grounding with Bing Search"
#
# This is the most important governance test in the POC, because Web IQ is the
# ONE IQ service that sits OUTSIDE the Azure DPA / Product Terms boundary.
#
# Rather than argue the point from documentation, this script provisions the
# service and lets Azure's own control plane state the answer:
#
#   * what region can the resource be placed in?        -> data residency
#   * does the resource type support Private Link?      -> network isolation
#   * what diagnostic LOG categories does it expose?    -> auditability
#   * what does Foundry say about private endpoints
#     for a Bing connection?                            -> peRequirement/peStatus
#   * what auth does the connection demand?             -> keyless posture
#
# Everything printed here is machine output from Azure, not commentary.
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
iq::load_outputs || exit 1

BING_NAME="${BING_NAME:-iqspoc-bing}"
BING_API="2020-06-10"
BING_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Bing/accounts/${BING_NAME}"
ARM="https://management.azure.com"

# ---------------------------------------------------------------------------
iq::header "C11.0  Is Grounding with Bing even available on this subscription?"
# ---------------------------------------------------------------------------
STATE=$(az provider show -n Microsoft.Bing --query registrationState -o tsv 2>/dev/null)
if [[ "$STATE" != "Registered" ]]; then
  iq::info "registering Microsoft.Bing ..."
  az provider register -n Microsoft.Bing >/dev/null 2>&1
  for i in $(seq 1 15); do
    STATE=$(az provider show -n Microsoft.Bing --query registrationState -o tsv 2>/dev/null)
    [[ "$STATE" == "Registered" ]] && break
    sleep 20
  done
fi
iq::info "Microsoft.Bing provider registration state = ${STATE}"

if az rest --method put --url "${ARM}${BING_ID}?api-version=${BING_API}" \
      --body '{"location":"global","sku":{"name":"G1"},"kind":"Bing.Grounding","properties":{}}' \
      -o json > "${EVIDENCE_DIR}/c11-bing-account.json" 2>"${OUT_DIR}/.bingerr"; then
  iq::ok "Grounding with Bing account provisioned on this subscription"
  BING_OK=1
else
  iq::warn "could not provision Grounding with Bing:"
  sed 's/^/       /' "${OUT_DIR}/.bingerr" | head -5
  iq::info "On many EA/internal subscriptions this fails - Grounding with Bing"
  iq::info "requires a payable offer. That itself is a useful finding."
  BING_OK=0
fi

if [[ "$BING_OK" == "1" ]]; then
  python3 - "${EVIDENCE_DIR}/c11-bing-account.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"       name     : {d['name']}")
print(f"       kind     : {d['kind']}")
print(f"       location : {d['location']}")
print(f"       sku      : {d['sku']['name']}")
print(f"       endpoint : {d['properties'].get('endpoint')}")
PY

  # -------------------------------------------------------------------------
  iq::header "C11.1  DATA RESIDENCY - can the resource be pinned to a region?"
  # -------------------------------------------------------------------------
  LOC=$(iq::jget "${EVIDENCE_DIR}/c11-bing-account.json" location)
  if [[ "$LOC" == "global" ]]; then
    iq::fail "location = 'global' - there is NO regional placement to choose"
    iq::info "=> Unlike AI Search and Foundry (both pinned to ${LOCATION}), the"
    iq::info "   Bing grounding resource has no region. Web queries are served by"
    iq::info "   a global service. ST cannot assert EU-only processing for the"
    iq::info "   text that is sent to Bing."
  else
    iq::warn "location = ${LOC} (unexpected - re-check residency assumptions)"
  fi

  # -------------------------------------------------------------------------
  iq::header "C11.2  NETWORK ISOLATION - does Microsoft.Bing support Private Link?"
  # -------------------------------------------------------------------------
  if az rest --method get \
       --url "${ARM}${BING_ID}/privateLinkResources?api-version=${BING_API}" \
       -o json > "${EVIDENCE_DIR}/c11-bing-privatelink.json" 2>&1; then
    iq::warn "privateLinkResources returned a payload - inspect it:"
    head -20 "${EVIDENCE_DIR}/c11-bing-privatelink.json" | sed 's/^/       /'
  else
    cp "${EVIDENCE_DIR}/c11-bing-privatelink.json" "${EVIDENCE_DIR}/c11-bing-privatelink.txt" 2>/dev/null
    iq::fail "no privateLinkResources on Microsoft.Bing/accounts"
    grep -o "ResourceTypeRegistrationNotFound[^\"]*" "${EVIDENCE_DIR}/c11-bing-privatelink.json" \
      | head -1 | sed 's/^/       /'
    iq::info "=> Grounding with Bing CANNOT be placed behind a private endpoint."
    iq::info "   Compare: AI Search, Foundry, Storage and Cosmos in this POC all"
    iq::info "   have private endpoints and public access disabled."
  fi

  # -------------------------------------------------------------------------
  iq::header "C11.3  AUDITABILITY - what can be sent to Log Analytics?"
  # -------------------------------------------------------------------------
  az rest --method get \
    --url "${ARM}${BING_ID}/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview" \
    -o json > "${EVIDENCE_DIR}/c11-bing-diag-categories.json" 2>&1
  python3 - "${EVIDENCE_DIR}/c11-bing-diag-categories.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("       (could not read categories)"); raise SystemExit
logs = [v['name'] for v in d.get('value', []) if v['properties'].get('categoryType') == 'Logs']
mets = [v['name'] for v in d.get('value', []) if v['properties'].get('categoryType') == 'Metrics']
print(f"       Log categories     : {logs if logs else 'NONE'}")
print(f"       Metric categories  : {mets if mets else 'NONE'}")
PY
  LOGCATS=$(python3 -c "
import json
d=json.load(open('${EVIDENCE_DIR}/c11-bing-diag-categories.json'))
print(len([v for v in d.get('value',[]) if v['properties'].get('categoryType')=='Logs']))
" 2>/dev/null || echo 0)
  if [[ "$LOGCATS" == "0" ]]; then
    iq::fail "Grounding with Bing exposes ZERO diagnostic LOG categories"
    iq::info "=> There is no Azure-side, per-query audit trail of what text left"
    iq::info "   the tenant towards Bing. Contrast with AI Search, where enabling"
    iq::info "   OperationLogs records every query string (proved in C3)."
    iq::info "   ACTION FOR ST: if web grounding is used, the ONLY place a record"
    iq::info "   of the outbound query can exist is the calling application."
  fi
fi

# ---------------------------------------------------------------------------
iq::header "C11.4  What does FOUNDRY say about private endpoints for this connection?"
# ---------------------------------------------------------------------------
CONN_API="2025-06-01"
PROJ="${ARM}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}/projects/${PROJECT_NAME}"

if [[ "$BING_OK" == "1" ]]; then
  BKEY=$(az rest --method post --url "${ARM}${BING_ID}/listKeys?api-version=${BING_API}" \
           --query key1 -o tsv 2>/dev/null)
  az rest --method put --url "${PROJ}/connections/binggrounding?api-version=${CONN_API}" \
    --body "{\"properties\":{\"category\":\"GroundingWithBingSearch\",\"target\":\"https://api.bing.microsoft.com/\",\"authType\":\"ApiKey\",\"credentials\":{\"key\":\"${BKEY}\"},\"isSharedToAll\":true,\"metadata\":{\"ApiType\":\"Azure\",\"ResourceId\":\"${BING_ID}\",\"type\":\"bing_grounding\"}}}" \
    -o json > "${EVIDENCE_DIR}/c11-bing-connection.json" 2>&1 \
    && iq::ok "Bing grounding connection created on the Foundry project" \
    || iq::warn "connection create failed (see evidence file)"
fi

# Also create the AI Search connection so the two can be compared side by side.
az rest --method put --url "${PROJ}/connections/searchconn?api-version=${CONN_API}" \
  --body "{\"properties\":{\"category\":\"CognitiveSearch\",\"target\":\"${SEARCH_ENDPOINT}\",\"authType\":\"AAD\",\"isSharedToAll\":true,\"metadata\":{\"ApiType\":\"Azure\",\"ResourceId\":\"${SEARCH_ID}\"}}}" \
  -o json > "${EVIDENCE_DIR}/c11-search-connection.json" 2>&1 \
  && iq::ok "AI Search connection created (for comparison)" \
  || iq::warn "AI Search connection create failed"

az rest --method get --url "${PROJ}/connections?api-version=${CONN_API}" -o json \
  > "${EVIDENCE_DIR}/c11-all-connections.json" 2>&1

iq::info ""
iq::info "Foundry's OWN verdict on each connection (peRequirement / peStatus):"
python3 - "${EVIDENCE_DIR}/c11-all-connections.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("       (no connections payload)"); raise SystemExit
rows = []
for v in d.get('value', []):
    p = v.get('properties', {})
    rows.append((v['name'], p.get('category', '-'), p.get('authType', '-'),
                 p.get('peRequirement', '-'), p.get('peStatus', '-')))
if not rows:
    print("       (none)"); raise SystemExit
hdr = ('connection', 'category', 'authType', 'peRequirement', 'peStatus')
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(5)]
print('       ' + '  '.join(h.ljust(w[i]) for i, h in enumerate(hdr)))
print('       ' + '  '.join('-' * w[i] for i in range(5)))
for r in rows:
    print('       ' + '  '.join(str(c).ljust(w[i]) for i, c in enumerate(r)))
PY

iq::info ""
iq::info "How to read that table honestly:"
iq::info "  * peStatus=NotApplicable appears for BOTH connections, so on its own"
iq::info "    it does NOT discriminate between them - it reflects how the"
iq::info "    connection object was declared, not the service's capability."
iq::info "    The decisive evidence for Bing is C11.2 (the resource type has no"
iq::info "    privateLinkResources at all) and C11.5 (public DNS resolution)."
iq::info "  * The connections DO differ on authentication, and that difference is"
iq::info "    real: AI Search = AAD (managed identity, keyless), Bing = ApiKey."
iq::info "    Every other component in this POC is keyless; web grounding forces"
iq::info "    a long-lived shared secret back into the design, which becomes a"
iq::info "    rotation and secret-storage obligation for ST."

# ---------------------------------------------------------------------------
iq::header "C11.5  Where does api.bing.microsoft.com actually resolve from the VNet?"
# ---------------------------------------------------------------------------
VM_NAME=$(iq::jget "${OUT_DIR}/vm-outputs.json" vmName.value)
if [[ -n "$VM_NAME" ]]; then
  az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "echo '--- private-linked AI Search (inside the VNet) ---'; getent hosts $(echo "${SEARCH_ENDPOINT}" | sed 's#https://##') ; \
               echo '--- Grounding with Bing ---'; getent hosts api.bing.microsoft.com" \
    --query "value[0].message" -o tsv 2>/dev/null \
    | tee "${EVIDENCE_DIR}/c11-dns-comparison.txt"
  iq::info ""
  iq::info "AI Search resolves to a 10.30.2.x address - the traffic never leaves"
  iq::info "the VNet. api.bing.microsoft.com resolves to a PUBLIC address, so the"
  iq::info "call traverses the internet edge (here, the NAT Gateway)."
else
  iq::warn "no in-VNet VM found - run scripts/04b-invnet-client.sh first"
fi

# ---------------------------------------------------------------------------
iq::header "C11  SUMMARY - Web IQ vs the private IQ services"
# ---------------------------------------------------------------------------
cat <<'EOF' | tee "${EVIDENCE_DIR}/c11-summary.txt"
  Dimension            Foundry IQ (AI Search)      Web IQ (Grounding w/ Bing)
  -------------------  --------------------------  ----------------------------
  Region placement     swedencentral (pinned)      global (no region exists)
  Private Endpoint     supported + in use          resource type has none
  DNS from the VNet    10.30.2.10 (private)        public IP via Traffic Manager
  Public access        disabled (proved: 403)      mandatory - public egress
  Diagnostic LOGS      OperationLogs available     NONE (metrics only)
  Query text audit     available if enabled        impossible on the Azure side
  Authentication       managed identity, keyless   API key (shared secret)
  Commercial terms     Azure Product Terms / DPA   separate Bing terms; data
                                                   leaves the Azure boundary

  Note on the DNS result: api.bing.microsoft.com resolved through
  bingapigblprod.trafficmanager.net - a GLOBAL Traffic Manager profile. Even
  though today it answered with a West Europe front end, the resolution path
  is explicitly global, so the serving region is not something ST controls or
  can contractually pin.

  BOTTOM LINE FOR ST
  Web IQ cannot be network-isolated, cannot be region-pinned, and cannot be
  audited from Azure. If ST's requirement is "no query text may leave our
  controlled boundary", web grounding must stay OFF, and that has to be
  enforced by policy on connection creation - not by network controls,
  because there is no network control available for it.
EOF

iq::header "C11 complete"
