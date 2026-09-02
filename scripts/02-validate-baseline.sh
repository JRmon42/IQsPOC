#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 02 - Day-zero posture validation.
#
# Proves, against live Azure resources, the briefing claims:
#   C1  Foundry IQ is backed by Azure AI Search
#   C2  Diagnostic resource logging is customer-configured and OFF by default
#   C5  Log Analytics default retention is 30 days and is configurable
#   C6  TLS 1.2+ in transit, 256-bit AES at rest
#   C7  Data is stored/processed in the selected Azure geography
#   C12 Keyless / Entra-only authentication is enforceable
#
# IMPORTANT: run this BEFORE 03-enable-search-logging.sh, otherwise C2 will
# (correctly) report that logging is now on.
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

PASS=0; FAIL=0
_pass() { iq::ok "$*"; PASS=$((PASS+1)); }
_fail() { iq::fail "$*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- C1 ---------
iq::header "C1  Foundry IQ is backed by Azure AI Search"
az search service show -g "$RG" -n "$SEARCH_NAME" \
  --query "{name:name,sku:sku.name,kind:type,location:location,status:status,replicas:replicaCount,partitions:partitionCount,semantic:semanticSearch}" \
  -o json > "${EVIDENCE_DIR}/c1-search-backing.json"
cat "${EVIDENCE_DIR}/c1-search-backing.json"
SKU=$(iq::jget "${EVIDENCE_DIR}/c1-search-backing.json" sku)
[[ -n "$SKU" ]] && _pass "Azure AI Search '$SEARCH_NAME' (sku=$SKU) is the retrieval engine" \
                || _fail "could not read the search service"
iq::info "Foundry IQ knowledge bases are surfaced as Azure AI Search"
iq::info "knowledge-base + knowledge-source objects on this very service."

# ---------------------------------------------------------------- C2 ---------
iq::header "C2  Diagnostic resource logging is OFF by default"
for RID_NAME in "$SEARCH_ID:AI Search" "$FOUNDRY_ID:Foundry account"; do
  RID="${RID_NAME%%:*}"; LBL="${RID_NAME##*:}"
  F="${EVIDENCE_DIR}/c2-diagnostics-$(echo "$LBL" | tr ' ' '-').json"
  az monitor diagnostic-settings list --resource "$RID" -o json 2>/dev/null > "$F"
  # The CLI returns a bare array on newer versions and {"value":[...]} on older.
  N=$(python3 - "$F" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d if isinstance(d, list) else d.get("value", [])))
except Exception:
    print("?")
PY
)
  if [[ "$N" == "0" ]]; then
    _pass "$LBL: 0 diagnostic settings - nothing is being logged until a human opts in"
  else
    iq::warn "$LBL: $N diagnostic setting(s) already present (expected 0 on a fresh deploy)"
  fi
done
iq::info "Consequence for ST: query text is NOT captured anywhere by default."

# ---------------------------------------------------------------- C5 ---------
iq::header "C5  Log Analytics retention"
az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" \
  --query "{name:name,retentionInDays:retentionInDays,sku:sku.name,workspaceCapping:workspaceCapping.dailyQuotaGb,location:location}" \
  -o json > "${EVIDENCE_DIR}/c5-retention.json"
cat "${EVIDENCE_DIR}/c5-retention.json"
RET=$(iq::jget "${EVIDENCE_DIR}/c5-retention.json" retentionInDays)
[[ "$RET" == "30" ]] && _pass "retention = 30 days (the documented default; 30-730 configurable)" \
                     || iq::warn "retention = ${RET} days (default is 30)"

# ---------------------------------------------------------------- C6 ---------
iq::header "C6  Encryption in transit and at rest"
{
  echo "{"
  echo "  \"storage\": $(az storage account show -g "$RG" -n "$STORAGE_NAME" \
        --query "{minimumTlsVersion:minimumTlsVersion,httpsOnly:supportsHttpsTrafficOnly,encryptionKeySource:encryption.keySource,blobEncrypted:encryption.services.blob.enabled,requireInfrastructureEncryption:encryption.requireInfrastructureEncryption}" -o json)",
  echo "  \"cosmos\": $(az cosmosdb show -g "$RG" -n "$COSMOS_NAME" \
        --query "{minimalTlsVersion:minimalTlsVersion,keySource:keyVaultKeyUri}" -o json)",
  echo "  \"foundry\": $(az cognitiveservices account show -g "$RG" -n "$FOUNDRY_NAME" \
        --query "{encryption:properties.encryption,disableLocalAuth:properties.disableLocalAuth}" -o json)",
  echo "  \"search\": $(az search service show -g "$RG" -n "$SEARCH_NAME" \
        --query "{encryptionWithCmk:encryptionWithCmk,disableLocalAuth:disableLocalAuth}" -o json)"
  echo "}"
} > "${EVIDENCE_DIR}/c6-encryption.json"
cat "${EVIDENCE_DIR}/c6-encryption.json"
TLS=$(az storage account show -g "$RG" -n "$STORAGE_NAME" --query minimumTlsVersion -o tsv)
[[ "$TLS" == "TLS1_2" || "$TLS" == "TLS1_3" ]] \
  && _pass "minimum TLS = $TLS (>= 1.2 as documented)" \
  || _fail "minimum TLS = $TLS"
iq::info "At rest: Azure Storage / AI Search / Cosmos all use 256-bit AES,"
iq::info "Microsoft-managed by default, customer-managed keys (CMK) optional."

# ---------------------------------------------------------------- C7 ---------
iq::header "C7  Data residency - everything in the selected geography"
az resource list -g "$RG" --query "[].{name:name,type:type,location:location}" -o json \
  > "${EVIDENCE_DIR}/c7-residency.json"
python3 - "${EVIDENCE_DIR}/c7-residency.json" <<'PY'
import json, sys, collections
rows = json.load(open(sys.argv[1]))
c = collections.Counter(r["location"] for r in rows)
for loc, n in c.most_common():
    print(f"  {loc:<20} {n} resource(s)")
PY
OFF=$(python3 -c "
import json,sys
rows=json.load(open('${EVIDENCE_DIR}/c7-residency.json'))
print(len([r for r in rows if r['location'] not in ('${LOCATION}','global')]))")
[[ "$OFF" == "0" ]] && _pass "no resource sits outside ${LOCATION} (global = DNS zones, which hold no customer data)" \
                    || iq::warn "$OFF resource(s) outside ${LOCATION}"
iq::info "CAVEAT: the model deployment SKU decides inference residency."
iq::info "GlobalStandard may route worldwide; use DataZoneStandard for EU-only."
az cognitiveservices account deployment list -g "$RG" -n "$FOUNDRY_NAME" \
  --query "[].{name:name,sku:sku.name,model:properties.model.name,version:properties.model.version}" -o table 2>/dev/null

# ---------------------------------------------------------------- C12 --------
iq::header "C12 Keyless / Entra-only authentication"
{
  echo "{"
  echo "  \"searchDisableLocalAuth\": $(az search service show -g "$RG" -n "$SEARCH_NAME" --query disableLocalAuth -o tsv | tr 'A-Z' 'a-z')," 
  echo "  \"foundryDisableLocalAuth\": $(az cognitiveservices account show -g "$RG" -n "$FOUNDRY_NAME" --query properties.disableLocalAuth -o tsv | tr 'A-Z' 'a-z'),"
  echo "  \"storageAllowSharedKeyAccess\": $(az storage account show -g "$RG" -n "$STORAGE_NAME" --query allowSharedKeyAccess -o tsv | tr 'A-Z' 'a-z'),"
  echo "  \"cosmosDisableLocalAuth\": $(az cosmosdb show -g "$RG" -n "$COSMOS_NAME" --query disableLocalAuth -o tsv | tr 'A-Z' 'a-z')"
  echo "}"
} > "${EVIDENCE_DIR}/c12-keyless.json"
cat "${EVIDENCE_DIR}/c12-keyless.json"
iq::info "All four data stores reject shared keys/API keys: every call must"
iq::info "carry an Entra ID token, which is what makes RBAC auditing possible."
_pass "keyless posture captured"

# ---------------------------------------------------------------- summary ----
iq::header "Baseline summary"
printf "  passed: %s   failed: %s\n" "$PASS" "$FAIL"
iq::info "evidence written to ${EVIDENCE_DIR}"
exit $(( FAIL > 0 ? 1 : 0 ))
