#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Common environment for every IQs POC script.
# Source this file:  source scripts/00-env.sh
#
# No jq dependency - python3 is used for JSON so the scripts run on a stock
# WSL/Ubuntu image without root.
# -----------------------------------------------------------------------------
set -uo pipefail

export TENANT_ID="${TENANT_ID:-8181de63-3f9c-40ed-9967-94512f7a75fe}"
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa}"
export RG="${RG:-rg-iqs-poc-sc}"
export LOCATION="${LOCATION:-swedencentral}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-iqspoc-core}"

# The bundled Bicep CLI is a self-contained .NET binary; on minimal WSL images
# libicu is absent, which makes it hard-fail. Invariant globalisation avoids
# needing root to apt-get install libicu.
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export OUT_DIR="${REPO_ROOT}/out"
export EVIDENCE_DIR="${REPO_ROOT}/out/evidence"
mkdir -p "${OUT_DIR}" "${EVIDENCE_DIR}"

iq::header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
iq::ok()     { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
iq::fail()   { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; }
iq::warn()   { printf '\033[0;33m  WARN\033[0m %s\n' "$*"; }
iq::info()   { printf '       %s\n' "$*"; }

# Read a dotted path out of a JSON file. Missing paths return the empty string.
iq::jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print('' if d is None else d)
except Exception:
    print('')
PY
}

# Pretty "key = value" listing of an ARM outputs object.
iq::jtable() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
w = max((len(k) for k in d), default=0)
for k, v in sorted(d.items()):
    print(f"  {k.ljust(w)} = {v['value'] if isinstance(v, dict) and 'value' in v else v}")
PY
}

# Resolve deployment outputs into exported shell variables.
iq::load_outputs() {
  local f="${OUT_DIR}/deployment-outputs.json"
  if [[ ! -f "$f" ]]; then
    echo "!! ${f} not found - run scripts/01-deploy.sh first" >&2
    return 1
  fi
  eval "$(python3 - "$f" <<'PY'
import json, shlex, sys
m = {
    'searchName': 'SEARCH_NAME', 'searchEndpoint': 'SEARCH_ENDPOINT', 'searchId': 'SEARCH_ID',
    'foundryName': 'FOUNDRY_NAME', 'foundryId': 'FOUNDRY_ID', 'foundryEndpoint': 'FOUNDRY_ENDPOINT',
    'projectName': 'PROJECT_NAME', 'logAnalyticsName': 'LAW_NAME', 'logAnalyticsId': 'LAW_ID',
    'logAnalyticsCustomerId': 'LAW_CUSTOMER_ID', 'appInsightsName': 'APPI_NAME',
    'storageAccountName': 'STORAGE_NAME', 'cosmosName': 'COSMOS_NAME',
    'vnetName': 'VNET_NAME', 'modelDeploymentName': 'MODEL_NAME',
    'agentSubnetName': 'AGENT_SUBNET', 'resourceGroupName': 'RG_OUT',
}
d = json.load(open(sys.argv[1]))
for k, var in m.items():
    if k in d:
        print(f"export {var}={shlex.quote(str(d[k]['value']))}")
PY
)"
}
