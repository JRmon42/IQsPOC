#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fabric IQ - what can and cannot be validated from code.
#
# Fabric IQ is the "IQ" layer over OneLake: ontologies, graph, and Fabric data
# agents. Unlike Foundry IQ it is NOT fully controllable from ARM:
#
#   * the CAPACITY (F-SKU) is an ARM resource  -> testable here
#   * the tenant/workspace preview toggles for Ontology, Graph and Data Agents
#     live in the Fabric ADMIN PORTAL only     -> not testable here
#
# This script therefore proves the parts that are provable, and states plainly
# which parts require a portal operator. Capacity is billed per hour while it
# is RUNNING, so the script creates, inspects, then PAUSES it by default.
#
#   ./scripts/08-fabric-iq.sh            # create, inspect, pause
#   FABRIC_DELETE=1 ./scripts/08-fabric-iq.sh   # ... and delete at the end
#   FABRIC_SKIP=1   ./scripts/08-fabric-iq.sh   # documentation only, no spend
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
iq::load_outputs || true

FABRIC_NAME="${FABRIC_NAME:-iqspocfab$(echo "${SUBSCRIPTION_ID}" | tr -d '-' | cut -c1-8)}"
FABRIC_SKU="${FABRIC_SKU:-F2}"
FABRIC_API="2023-11-01"
ARM="https://management.azure.com"
FAB_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Fabric/capacities/${FABRIC_NAME}"

ADMIN_UPN="${ADMIN_UPN:-$(az account show --query user.name -o tsv 2>/dev/null)}"

iq::header "Fabric IQ - scope of what this script can prove"
cat <<EOF
       PROVABLE HERE (ARM control plane):
         - can an F-SKU capacity be created on this subscription?
         - what region does it land in? (data residency)
         - does Microsoft.Fabric/capacities support Private Link?
         - what diagnostic log categories exist?

       NOT PROVABLE HERE (Fabric admin portal only):
         - enabling the Ontology / Graph / Data Agent preview switches
         - creating a workspace, lakehouse, ontology or data agent
         - workspace-level private/managed VNet settings
       These require an interactive operator at https://app.fabric.microsoft.com
       with Fabric Administrator rights. They are called out in docs/feasibility.md.
EOF

if [[ "${FABRIC_SKIP:-0}" == "1" ]]; then
  iq::warn "FABRIC_SKIP=1 - stopping before any billable resource is created"
  exit 0
fi

# ---------------------------------------------------------------------------
iq::header "Is Microsoft.Fabric available on this subscription?"
# ---------------------------------------------------------------------------
STATE=$(az provider show -n Microsoft.Fabric --query registrationState -o tsv 2>/dev/null || echo "NotFound")
if [[ "$STATE" != "Registered" ]]; then
  iq::info "registering Microsoft.Fabric ..."
  az provider register -n Microsoft.Fabric >/dev/null 2>&1
  for i in $(seq 1 15); do
    STATE=$(az provider show -n Microsoft.Fabric --query registrationState -o tsv 2>/dev/null)
    [[ "$STATE" == "Registered" ]] && break
    sleep 20
  done
fi
iq::info "Microsoft.Fabric registration state = ${STATE}"

# ---------------------------------------------------------------------------
iq::header "Creating ${FABRIC_SKU} capacity ${FABRIC_NAME} in ${LOCATION}"
# ---------------------------------------------------------------------------
iq::info "capacity admin will be: ${ADMIN_UPN}"
if az rest --method put --url "${ARM}${FAB_ID}?api-version=${FABRIC_API}" \
     --body "{\"location\":\"${LOCATION}\",\"sku\":{\"name\":\"${FABRIC_SKU}\",\"tier\":\"Fabric\"},\"properties\":{\"administration\":{\"members\":[\"${ADMIN_UPN}\"]}}}" \
     -o json > "${EVIDENCE_DIR}/fabric-capacity.json" 2>"${OUT_DIR}/.faberr"; then
  iq::ok "Fabric capacity created"
  FAB_OK=1
  python3 - "${EVIDENCE_DIR}/fabric-capacity.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get('properties', {})
print(f"       name      : {d.get('name')}")
print(f"       location  : {d.get('location')}")
print(f"       sku       : {d.get('sku', {}).get('name')} ({d.get('sku', {}).get('tier')})")
print(f"       state     : {p.get('state')}")
print(f"       admins    : {p.get('administration', {}).get('members')}")
PY
else
  iq::warn "could not create a Fabric capacity:"
  sed 's/^/       /' "${OUT_DIR}/.faberr" | head -6
  iq::info "=> Fabric IQ cannot be exercised on this subscription. For ST this"
  iq::info "   is a commercial/licensing prerequisite, not a technical blocker."
  FAB_OK=0
fi

if [[ "${FAB_OK}" == "1" ]]; then
  # -------------------------------------------------------------------------
  iq::header "Data residency and network posture of the capacity"
  # -------------------------------------------------------------------------
  FLOC=$(iq::jget "${EVIDENCE_DIR}/fabric-capacity.json" location)
  if [[ "$FLOC" == "$LOCATION" ]]; then
    iq::ok "capacity is pinned to ${FLOC} - unlike Web IQ, Fabric IS regional"
    iq::info "=> Fabric capacity, and the OneLake data it backs, has a home region."
    iq::info "   NOTE: the capacity region is not automatically the same as the"
    iq::info "   Fabric TENANT home region, which is fixed when Fabric is first"
    iq::info "   enabled. ST should confirm the tenant home region separately."
  else
    iq::warn "capacity landed in ${FLOC}, expected ${LOCATION}"
  fi

  iq::header "Diagnostic log categories exposed by Microsoft.Fabric/capacities"
  az rest --method get \
    --url "${ARM}${FAB_ID}/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview" \
    -o json > "${EVIDENCE_DIR}/fabric-diag-categories.json" 2>&1
  python3 - "${EVIDENCE_DIR}/fabric-diag-categories.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("       (none returned)"); raise SystemExit
logs = [v['name'] for v in d.get('value', []) if v['properties'].get('categoryType') == 'Logs']
mets = [v['name'] for v in d.get('value', []) if v['properties'].get('categoryType') == 'Metrics']
print(f"       Log categories    : {logs if logs else 'NONE'}")
print(f"       Metric categories : {mets if mets else 'NONE'}")
PY
  iq::info "Fabric's richer audit trail is NOT here - it is in the Microsoft"
  iq::info "Purview / M365 unified audit log, which is a tenant-level surface."

  # -------------------------------------------------------------------------
  iq::header "Pausing the capacity so it stops billing"
  # -------------------------------------------------------------------------
  if az rest --method post --url "${ARM}${FAB_ID}/suspend?api-version=${FABRIC_API}" -o none 2>&1; then
    iq::ok "capacity suspended (billing stops; resource is retained)"
  else
    iq::warn "suspend call did not succeed - CHECK THE PORTAL so you do not pay for idle capacity"
  fi

  if [[ "${FABRIC_DELETE:-0}" == "1" ]]; then
    iq::info "FABRIC_DELETE=1 - deleting the capacity"
    az rest --method delete --url "${ARM}${FAB_ID}?api-version=${FABRIC_API}" -o none 2>&1 \
      && iq::ok "capacity deleted" || iq::warn "delete failed - remove it manually"
  else
    iq::info "capacity retained but suspended. Delete with:"
    iq::info "  FABRIC_DELETE=1 ./scripts/08-fabric-iq.sh"
  fi
fi

# ---------------------------------------------------------------------------
iq::header "Manual steps an operator must perform for a full Fabric IQ test"
# ---------------------------------------------------------------------------
cat <<'EOF' | tee "${EVIDENCE_DIR}/fabric-manual-steps.txt"
  1. https://app.fabric.microsoft.com -> Settings -> Admin portal -> Tenant settings
     Enable, scoped to a security group rather than the whole org:
       - "Users can create Fabric items"
       - the Ontology / Graph (preview) switches
       - "Users can create and use Fabric data agents"
       - "Users can share Fabric data agents"
  2. Assign the F-SKU capacity to a workspace.
  3. Create a lakehouse, load data, build the ontology/graph.
  4. Create a Fabric data agent over it and connect it to Foundry.

  PRIVACY POINTS TO RAISE WITH ST WHILE IN THE ADMIN PORTAL
   - Fabric data agent activity is recorded in the M365 unified audit log
     (Purview), NOT in the Log Analytics workspace used by Foundry/AI Search.
     ST will therefore have TWO separate audit surfaces to govern.
   - A Fabric data agent enforces the CALLING USER's OneLake permissions when
     invoked with user identity. That is the opposite of the AI Search finding
     in this POC, where a single managed identity collapsed every end user into
     one object ID. This distinction matters for ST's auditing requirement.
   - Cross-tenant/model processing for the agent's language model follows the
     Fabric Copilot settings, including the "data leaves your geography" toggle.
     Confirm that setting explicitly with ST.
EOF

iq::header "Fabric IQ script complete"
