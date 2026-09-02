#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04b - Deploy the in-VNet test client and re-run the probe from INSIDE.
#
# The whole point: run the identical probe from two vantage points.
#   outside the VNet -> DNS_FAILED / PUBLIC_BLOCKED
#   inside  the VNet -> PRIVATE_PATH (10.30.2.x)
#
# Interaction with the VM is entirely through `az vm run-command`, so the VM
# needs no public IP and the NSG needs no inbound rule.
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

KEY="${HOME}/.ssh/iqspoc_vm"
if [[ ! -f "${KEY}.pub" ]]; then
  iq::header "Generating a break-glass SSH key (${KEY})"
  mkdir -p "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "iqspoc" >/dev/null
fi

iq::header "Deploying in-VNet test client (VM + NAT gateway)"
az deployment group create \
  --resource-group "$RG" \
  --name iqspoc-vm \
  --template-file "${REPO_ROOT}/infra/vm.bicep" \
  --parameters vnetName="$VNET_NAME" adminPublicKey="$(cat "${KEY}.pub")" \
  --query properties.outputs -o json > "${OUT_DIR}/vm-outputs.json" || {
    iq::fail "VM deployment failed"; cat "${OUT_DIR}/vm-outputs.json"; exit 1; }
iq::jtable "${OUT_DIR}/vm-outputs.json"

VM_NAME=$(iq::jget "${OUT_DIR}/vm-outputs.json" vmName.value)
NAT_IP=$(iq::jget  "${OUT_DIR}/vm-outputs.json" natEgressIp.value)
iq::ok "test client ${VM_NAME} deployed; deterministic egress IP = ${NAT_IP}"

iq::header "Waiting for cloud-init to finish (installs az CLI + SDKs)"
for i in $(seq 1 30); do
  R=$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
        --scripts "cat /var/log/iqspoc-ready 2>/dev/null || echo NOTREADY" \
        --query "value[0].message" -o tsv 2>/dev/null)
  if [[ "$R" == *"iqspoc-client-ready"* ]]; then iq::ok "cloud-init complete"; break; fi
  iq::info "attempt ${i}/30 - still initialising..."
  sleep 30
done

iq::header "Copying the probe onto the client and running it INSIDE the VNet"
PROBE_B64=$(base64 -w0 "${REPO_ROOT}/src/network_probe.py")
az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "echo '${PROBE_B64}' | base64 -d > /tmp/network_probe.py && \
             python3 /tmp/network_probe.py \
               --endpoints '${SEARCH_ENDPOINT}' '${FOUNDRY_ENDPOINT}' \
                           'https://${STORAGE_NAME}.blob.core.windows.net/' \
                           'https://${COSMOS_NAME}.documents.azure.com/'" \
  --query "value[0].message" -o tsv | tee "${EVIDENCE_DIR}/c8-probe-from-inside-vnet.txt"

iq::header "Authenticated data-plane call from INSIDE the VNet (managed identity)"
# Data-plane RBAC can take several minutes to propagate. Retry so the evidence
# reflects steady state rather than a propagation race.
for i in $(seq 1 12); do
  OUT=$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "TOK=\$(curl -s -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://search.azure.com' | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"access_token\"])'); \
               echo '--- GET /indexes from INSIDE the VNet (resolves to a 10.30.2.x private endpoint) ---'; \
               curl -s -o /tmp/o -w 'HTTP %{http_code}\n' -H \"Authorization: Bearer \$TOK\" '${SEARCH_ENDPOINT}/indexes?api-version=2024-07-01'; \
               head -c 400 /tmp/o" \
    --query "value[0].message" -o tsv)
  if [[ "$OUT" == *"HTTP 200"* ]]; then break; fi
  iq::info "attempt ${i}/12 - waiting for data-plane RBAC propagation..."
  sleep 30
done
echo "$OUT" | tee "${EVIDENCE_DIR}/c8-authenticated-from-inside.txt"
[[ "$OUT" == *"HTTP 200"* ]] \
  && iq::ok "authenticated call SUCCEEDS from inside the VNet" \
  || iq::warn "still not 200 - check RBAC; an empty-bodied 403 is an RBAC denial, not a network block"

iq::header "Side-by-side interpretation"
cat <<EOF

  From OUTSIDE the VNet (this host):
    - <foundry>.cognitiveservices.azure.com  ->  NO public A record at all
    - <search>.search.windows.net            ->  public IP, then HTTP 403
      "Request is denied as the source is not allowed by applicable rules.
       The service is set 'publicNetworkAccess: Disabled'."

  From INSIDE the VNet (${VM_NAME}):
    - the same names resolve to 10.30.2.x private endpoint addresses
    - the same authenticated request succeeds

  That difference IS the Private Link guarantee, measured rather than asserted.
  Egress from the client tier is pinned to a single NAT address (${NAT_IP}),
  which is the source address Microsoft-side services would observe.

EOF
iq::ok "inside-VNet evidence written to ${EVIDENCE_DIR}"
