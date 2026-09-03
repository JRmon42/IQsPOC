#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 12-workiq-fabriciq-gaps.sh
#
# Work IQ and Fabric IQ could not be exercised in this POC. Rather than say
# "not tested", this script probes each prerequisite until the service itself
# states why, so the gap list is evidence rather than a reading of the docs.
#
# Every probe below is expected to FAIL. The failure text is the deliverable.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/00-env.sh

GAPS="${EVIDENCE_DIR}/gaps"
mkdir -p "$GAPS"

probe () {  # $1 label, $2 file, rest: command
  local label="$1" file="$2"; shift 2
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  printf '%s\n' "$out" > "${GAPS}/${file}"
  printf '  %-34s ' "$label"
  if [[ $rc -eq 0 ]]; then echo "OK"; else echo "FAILED (this is the evidence)"; fi
  printf '%s\n' "$out" | head -c 300 | sed 's/^/      /'
  echo
}

# ---------------------------------------------------------------------------
iq::header "G1  Work IQ prerequisites - is there a Microsoft 365 substrate?"
# ---------------------------------------------------------------------------
# Work IQ retrieves from the Microsoft 365 substrate (SharePoint, Exchange,
# Teams, Graph connectors). None of that exists without M365 licensing, so the
# licence inventory is the first thing to establish.

iq::info "licences actually present in this tenant:"
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --resource "https://graph.microsoft.com" -o json > "${GAPS}/m365-skus.json" 2>&1 || true
python3 - "${GAPS}/m365-skus.json" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("value", [])
except Exception:
    print("      <could not read licence list>"); raise SystemExit
if not v:
    print("      none")
for s in v:
    print(f"      {s.get('skuPartNumber','?'):<40} enabled="
          f"{s.get('prepaidUnits',{}).get('enabled')} consumed={s.get('consumedUnits')}")
need = {"SPE_E3","SPE_E5","ENTERPRISEPACK","ENTERPRISEPREMIUM",
        "Microsoft_365_Copilot","SHAREPOINTENTERPRISE"}
have = {s.get("skuPartNumber") for s in v}
missing = need - have
print()
print(f"      M365/Copilot SKUs present: {sorted(have & need) or 'NONE'}")
PY
echo

probe "SharePoint Online reachable?" "sharepoint-root.txt" \
  az rest --method get --url "https://graph.microsoft.com/v1.0/sites/root" \
     --resource "https://graph.microsoft.com"

probe "Graph connectors present?" "graph-connections.txt" \
  az rest --method get --url "https://graph.microsoft.com/v1.0/external/connections" \
     --resource "https://graph.microsoft.com"

# ---------------------------------------------------------------------------
iq::header "G2  Fabric IQ prerequisites - is there a Fabric tenant?"
# ---------------------------------------------------------------------------
iq::info "Microsoft.Fabric resource provider registration:"
az provider show -n Microsoft.Fabric --query "{namespace:namespace,state:registrationState}" \
  -o json | tee "${GAPS}/fabric-rp.json" | sed 's/^/      /'
echo

iq::info "existing Fabric capacities in the subscription:"
az resource list --resource-type Microsoft.Fabric/capacities -o json \
  > "${GAPS}/fabric-capacities.json"
python3 -c "
import json; d=json.load(open('${GAPS}/fabric-capacities.json'))
print('      ' + (', '.join(x['name'] for x in d) if d else 'none'))"
echo

probe "Create F2 capacity (control plane)" "fabric-capacity-create.txt" \
  az rest --method put \
     --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Fabric/capacities/iqspocfab?api-version=2023-11-01" \
     --body "{\"location\":\"${LOCATION}\",\"sku\":{\"name\":\"F2\",\"tier\":\"Fabric\"},\"properties\":{\"administration\":{\"members\":[\"${FABRIC_ADMIN:-$(az account show --query user.name -o tsv)}\"]}}}"

probe "Fabric data plane /v1/capacities" "fabric-dataplane.txt" \
  az rest --method get --url "https://api.fabric.microsoft.com/v1/capacities" \
     --resource "https://api.fabric.microsoft.com"

# ---------------------------------------------------------------------------
iq::header "G3  Diagnosis"
# ---------------------------------------------------------------------------
python3 - "${GAPS}" <<'PY'
import json, os, sys
g = sys.argv[1]
def read(f):
    try: return open(os.path.join(g, f), errors="replace").read()
    except Exception: return ""

spo   = read("sharepoint-root.txt")
fabdp = read("fabric-dataplane.txt")
fabcp = read("fabric-capacity-create.txt")

findings = []
if "does not have a SPO license" in spo:
    findings.append(("Work IQ", "BLOCKED",
        "Graph replied 'Tenant does not have a SPO license.' There is no Microsoft 365 "
        "substrate in this tenant, so there is nothing for Work IQ to retrieve from."))
if "UserNotLicensed" in fabdp:
    findings.append(("Fabric IQ", "BLOCKED",
        "The Fabric data plane replied 'UserNotLicensed'. No Fabric/Power BI tenant has "
        "been initialised, which is also why the ARM capacity PUT returns a bare 401."))
elif "Unable to authorize with Azure Active Directory" in fabcp:
    findings.append(("Fabric IQ", "BLOCKED",
        "ARM returned 'Unable to authorize with Azure Active Directory' from the Fabric RP."))

for name, state, why in findings:
    print(f"  {name:<10} {state}")
    for line in why.split(". "):
        if line.strip():
            print("      " + line.strip().rstrip(".") + ".")
    print()
if not findings:
    print("  No blocking condition detected - re-check the raw probe output.")
print("  Full remediation: docs/work-iq-requirements.md, docs/fabric-iq-requirements.md")
PY
