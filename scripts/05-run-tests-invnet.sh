#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 05 - Run the functional Foundry IQ test from INSIDE the VNet.
#
# The services are publicNetworkAccess=Disabled, so the only place these tests
# CAN run is the in-VNet client. That constraint is itself part of the proof.
#
# Ships src/*.py to the VM over the Azure control plane (no inbound port, no
# SSH), runs them under the VM's managed identity, and brings the output back.
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

VM_NAME="${VM_NAME:-iqspoc-client}"

iq::header "Shipping test client to ${VM_NAME}"
SCRIPT_B64=$(base64 -w0 "${REPO_ROOT}/src/foundry_iq_test.py")

iq::header "Running Foundry IQ end-to-end test inside the VNet"
az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "echo '${SCRIPT_B64}' | base64 -d > /tmp/foundry_iq_test.py && \
             python3 /tmp/foundry_iq_test.py \
               --search-endpoint '${SEARCH_ENDPOINT}' \
               --foundry-endpoint '${FOUNDRY_ENDPOINT}' \
               --model '${MODEL_NAME}' 2>&1" \
  --query "value[0].message" -o tsv | tee "${EVIDENCE_DIR}/c3-foundry-iq-run.txt"

iq::header "Retrieving structured results"
# base64 round-trip: run-command wraps stdout in banner text, so extracting
# raw JSON with sed is unreliable once the payload contains braces.
az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "echo BEGINB64; gzip -c /tmp/foundry_iq_results.json | base64 -w0; echo; echo ENDB64" \
  --query "value[0].message" -o tsv > "${OUT_DIR}/.results.b64" 2>/dev/null
sed -n '/BEGINB64/,/ENDB64/p' "${OUT_DIR}/.results.b64" \
  | grep -oE '^[A-Za-z0-9+/=]{40,}$' | head -1 | base64 -d | gunzip \
  > "${EVIDENCE_DIR}/c3-foundry-iq-results.json" 2>/dev/null \
  || echo '{}' > "${EVIDENCE_DIR}/c3-foundry-iq-results.json"
iq::info "$(wc -c < "${EVIDENCE_DIR}/c3-foundry-iq-results.json") bytes captured"

iq::ok "traffic generated - wait ~10 minutes, then run scripts/06-query-logs.sh"
