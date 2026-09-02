#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01 - Deploy the IQs POC core infrastructure.
#
# Usage:
#   ./scripts/01-deploy.sh            # what-if preview then deploy
#   ./scripts/01-deploy.sh --whatif   # preview only
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

WHATIF_ONLY=0
[[ "${1:-}" == "--whatif" ]] && WHATIF_ONLY=1

iq::header "Context"
az account set --subscription "$SUBSCRIPTION_ID"
az account show --query "{sub:name,subId:id,tenant:tenantId,user:user.name}" -o table

iq::header "Ensuring resource group ${RG} (${LOCATION})"
az group create -n "$RG" -l "$LOCATION" \
  --tags project=IQsPOC purpose="Foundry/Web/Fabric/Work IQ validation" owner=JRmon42 \
  -o none
iq::ok "resource group ready"

iq::header "What-if"
az deployment group what-if \
  --resource-group "$RG" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters "${REPO_ROOT}/infra/main.parameters.json" \
  --no-pretty-print > "${OUT_DIR}/whatif.json" || true
python3 - "${OUT_DIR}/whatif.json" <<'PY' || cat "${OUT_DIR}/whatif.json"
import json, sys, re
d = json.load(open(sys.argv[1]))
for c in sorted(d.get("changes", []), key=lambda x: x["resourceId"]):
    rid = re.sub(r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/", "", c["resourceId"])
    print(f"  {c['changeType']:<10} {rid}")
PY

if [[ $WHATIF_ONLY -eq 1 ]]; then
  iq::info "what-if only; stopping here"
  exit 0
fi

iq::header "Deploying"
az deployment group create \
  --resource-group "$RG" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters "${REPO_ROOT}/infra/main.parameters.json" \
  --query properties.outputs -o json | tee "${OUT_DIR}/deployment-outputs.json"

iq::header "Outputs"
iq::jtable "${OUT_DIR}/deployment-outputs.json"
iq::ok "deployment complete - outputs written to ${OUT_DIR}/deployment-outputs.json"
