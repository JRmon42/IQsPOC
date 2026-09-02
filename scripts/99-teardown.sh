#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tear the POC down.
#
# The stack costs real money while it exists - AI Search Basic and the four
# private endpoints bill per hour whether or not anything is running. Run this
# as soon as the ST meeting evidence has been captured.
#
#   ./scripts/99-teardown.sh            # prompts before deleting
#   FORCE=1 ./scripts/99-teardown.sh    # no prompt (for automation)
#   KEEP_LOGS=1 ./scripts/99-teardown.sh  # delete compute/search, keep the LAW
#
# Evidence in out/ is NEVER deleted by this script.
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

iq::header "Resources currently in ${RG}"
if ! az group show -n "$RG" -o none 2>/dev/null; then
  iq::ok "resource group ${RG} does not exist - nothing to tear down"
  exit 0
fi
az resource list -g "$RG" --query "[].{name:name,type:type}" -o table 2>/dev/null

COUNT=$(az resource list -g "$RG" --query "length(@)" -o tsv 2>/dev/null || echo 0)
iq::info ""
iq::info "${COUNT} resource(s) in ${RG}"

# Fabric capacity is billed hourly and lives outside the main Bicep deployment,
# so make sure it is suspended/removed even if the RG delete is declined.
FAB=$(az resource list -g "$RG" --resource-type Microsoft.Fabric/capacities --query "[].name" -o tsv 2>/dev/null)
if [[ -n "$FAB" ]]; then
  iq::warn "Fabric capacity present: ${FAB} (billed per hour while running)"
fi

if [[ "${KEEP_LOGS:-0}" == "1" ]]; then
  iq::header "KEEP_LOGS=1 - deleting billable resources but retaining the workspace"
  LAW=$(az resource list -g "$RG" --resource-type Microsoft.OperationalInsights/workspaces --query "[0].name" -o tsv 2>/dev/null)
  iq::info "retaining Log Analytics workspace: ${LAW:-<none>}"
  for T in Microsoft.Compute/virtualMachines \
           Microsoft.Search/searchServices \
           Microsoft.CognitiveServices/accounts \
           Microsoft.Fabric/capacities \
           Microsoft.Network/privateEndpoints \
           Microsoft.Network/natGateways; do
    for N in $(az resource list -g "$RG" --resource-type "$T" --query "[].name" -o tsv 2>/dev/null); do
      iq::info "deleting ${T}/${N}"
      az resource delete -g "$RG" -n "$N" --resource-type "$T" -o none 2>/dev/null \
        && iq::ok "deleted ${N}" || iq::warn "could not delete ${N}"
    done
  done
  iq::ok "billable compute/search/PE resources removed; workspace kept"
  iq::info "Delete the rest later with: az group delete -n ${RG} --yes"
  exit 0
fi

if [[ "${FORCE:-0}" != "1" ]]; then
  iq::header "Confirm"
  echo "  This DELETES the entire resource group ${RG} and everything above."
  echo "  Evidence under out/ is kept."
  read -r -p "  Type the resource group name to confirm: " ANSWER
  if [[ "$ANSWER" != "$RG" ]]; then
    iq::warn "input did not match - aborted, nothing deleted"
    exit 1
  fi
fi

iq::header "Deleting resource group ${RG}"
# --no-wait would return instantly, but then the operator has no idea whether
# deletion actually succeeded; a stuck delete leaves the bill running.
if az group delete -n "$RG" --yes -o none 2>&1; then
  iq::ok "resource group ${RG} deleted"
else
  iq::fail "delete failed - check for resource locks or denied policies"
  iq::info "resources may still be billing; inspect in the portal"
  exit 1
fi

iq::header "Left behind on purpose"
cat <<EOF
  * out/                       - all captured evidence (not deleted)
  * docs/                      - generated findings
  * the Microsoft.Bing provider registration (harmless, free)
  * any Entra app registrations or role assignments outside ${RG}

  Verify you are no longer being billed:
    az resource list -g ${RG} 2>/dev/null || echo "resource group is gone"
EOF

iq::header "Teardown complete"
