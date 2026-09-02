#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04 - Network flow mapping.  This is the core deliverable for the customer.
#
#   C8  Private Link projects each PaaS service into the customer VNet
#   C9  Public network access is genuinely blocked
#   C10 Agent egress uses a customer-managed *delegated* subnet
#
# Produces out/evidence/c8-private-dns.json, c9-public-blocked.json,
# c10-delegated-subnet.json and a human-readable flow map.
# -----------------------------------------------------------------------------
set -uo pipefail
source "$(dirname "$0")/00-env.sh"
iq::load_outputs || exit 1

# ---------------------------------------------------------------- C10 --------
iq::header "C10  VNet topology and subnet delegation"
az network vnet subnet list -g "$RG" --vnet-name "$VNET_NAME" \
  --query "[].{subnet:name,prefix:addressPrefix,delegatedTo:delegations[0].serviceName,peNetworkPolicies:privateEndpointNetworkPolicies,nsg:networkSecurityGroup.id}" \
  -o json > "${EVIDENCE_DIR}/c10-delegated-subnet.json"
python3 - "${EVIDENCE_DIR}/c10-delegated-subnet.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
print(f"  {'SUBNET':<14}{'PREFIX':<18}{'DELEGATED TO':<32}{'NSG'}")
for r in rows:
    nsg = (r.get("nsg") or "-").split("/")[-1]
    print(f"  {r['subnet']:<14}{r['prefix']:<18}{(r.get('delegatedTo') or '-'):<32}{nsg}")
PY
DEL=$(python3 -c "
import json
rows=json.load(open('${EVIDENCE_DIR}/c10-delegated-subnet.json'))
print(next((r['delegatedTo'] for r in rows if r['subnet']=='snet-agent'), ''))")
if [[ "$DEL" == "Microsoft.App/environments" ]]; then
  iq::ok "snet-agent is delegated to '${DEL}'"
  iq::info "This is what 'VNet injection into a customer-managed delegated subnet'"
  iq::info "means: the Agent Service places its OUTBOUND NICs inside YOUR subnet,"
  iq::info "so agent egress is subject to YOUR NSG rules, YOUR UDRs and YOUR firewall."
else
  iq::fail "snet-agent delegation is '${DEL}' (expected Microsoft.App/environments)"
fi

# ---------------------------------------------------------------- C8 ---------
iq::header "C8  Private endpoints and the private IPs they allocate"
az network private-endpoint list -g "$RG" \
  --query "[].{pe:name,subnet:subnet.id,service:privateLinkServiceConnections[0].groupIds[0],target:privateLinkServiceConnections[0].privateLinkServiceId,state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status,ips:customDnsConfigs[].ipAddresses[]}" \
  -o json > "${EVIDENCE_DIR}/c8-private-endpoints.json"

# The authoritative record of "name -> private IP" lives on the PE NIC.
az network private-endpoint list -g "$RG" --query "[].{name:name,nic:networkInterfaces[0].id}" -o tsv \
| while read -r PE NICID; do
    az network nic show --ids "$NICID" \
      --query "ipConfigurations[].{pe:'$PE',fqdn:privateLinkConnectionProperties.fqdns[0],ip:privateIPAddress}" -o tsv
  done > "${EVIDENCE_DIR}/c8-pe-ip-map.tsv"
printf "  %-24s %-58s %s\n" "PRIVATE ENDPOINT" "FQDN" "PRIVATE IP"
while IFS=$'\t' read -r PE FQDN IP; do printf "  %-24s %-58s %s\n" "$PE" "$FQDN" "$IP"; done \
  < "${EVIDENCE_DIR}/c8-pe-ip-map.tsv"

iq::header "C8  Private DNS zone A-records"
: > "${EVIDENCE_DIR}/c8-private-dns.json"
python3 - <<'PY' > /dev/null
PY
{
  echo "["
  FIRST=1
  for Z in $(az network private-dns zone list -g "$RG" --query "[].name" -o tsv); do
    for REC in $(az network private-dns record-set a list -g "$RG" -z "$Z" \
                   --query "[].{n:name,ip:join(',',aRecords[].ipv4Address)}" -o tsv 2>/dev/null | tr '\t' '|'); do
      NAME="${REC%%|*}"; IP="${REC##*|}"
      [[ $FIRST -eq 0 ]] && echo ","
      FIRST=0
      printf '  {"zone":"%s","record":"%s","privateIp":"%s","fqdn":"%s.%s"}' "$Z" "$NAME" "$IP" "$NAME" "$Z"
    done
  done
  echo ""
  echo "]"
} > "${EVIDENCE_DIR}/c8-private-dns.json"
python3 - "${EVIDENCE_DIR}/c8-private-dns.json" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    print("  (no A records yet)"); raise SystemExit
print(f"  {'FQDN':<64}{'PRIVATE IP'}")
for r in rows:
    print(f"  {r['fqdn']:<64}{r['privateIp']}")
print()
print("  A client INSIDE the VNet resolves these names to 10.30.2.x (RFC1918).")
print("  A client OUTSIDE the VNet resolves them to a public CNAME whose")
print("  endpoint then refuses the connection - see C9.")
PY

# ---------------------------------------------------------------- C9 ---------
iq::header "C9  Public network access is blocked"
{
  echo "{"
  echo "  \"search\":  $(az search service show -g "$RG" -n "$SEARCH_NAME" --query "{publicNetworkAccess:publicNetworkAccess,ipRules:networkRuleSet.ipRules}" -o json),"
  echo "  \"foundry\": $(az cognitiveservices account show -g "$RG" -n "$FOUNDRY_NAME" --query "{publicNetworkAccess:properties.publicNetworkAccess,defaultAction:properties.networkAcls.defaultAction}" -o json),"
  echo "  \"storage\": $(az storage account show -g "$RG" -n "$STORAGE_NAME" --query "{publicNetworkAccess:publicNetworkAccess,defaultAction:networkRuleSet.defaultAction}" -o json),"
  echo "  \"cosmos\":  $(az cosmosdb show -g "$RG" -n "$COSMOS_NAME" --query "{publicNetworkAccess:publicNetworkAccess}" -o json)"
  echo "}"
} > "${EVIDENCE_DIR}/c9-public-blocked.json"
cat "${EVIDENCE_DIR}/c9-public-blocked.json"

iq::header "C9  Live probe from THIS host (which is outside the VNet)"
iq::info "Expect connection refused / 403 for every private-only endpoint."
python3 "${REPO_ROOT}/src/network_probe.py" \
  --endpoints "${SEARCH_ENDPOINT}" "${FOUNDRY_ENDPOINT}" \
              "https://${STORAGE_NAME}.blob.core.windows.net/" \
              "https://${COSMOS_NAME}.documents.azure.com/" \
  --out "${EVIDENCE_DIR}/c9-public-probe.json"

# ---------------------------------------------------------------- routes -----
iq::header "Effective outbound path from the agent subnet"
iq::info "Default Azure system routes send 0.0.0.0/0 to 'Internet'."
iq::info "To force agent egress through an inspection point, associate a route"
iq::info "table on snet-agent with 0.0.0.0/0 -> VirtualAppliance <firewall-ip>."
az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n snet-agent \
  --query "{routeTable:routeTable.id,natGateway:natGateway.id,serviceEndpoints:serviceEndpoints[].service,defaultOutboundAccess:defaultOutboundAccess}" \
  -o json | tee "${EVIDENCE_DIR}/c10-agent-egress.json"

iq::header "NSG rules currently applied to the agent subnet"
NSG=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n snet-agent --query "networkSecurityGroup.id" -o tsv)
if [[ -n "$NSG" ]]; then
  az network nsg show --ids "$NSG" \
    --query "securityRules[].{name:name,dir:direction,access:access,proto:protocol,src:sourceAddressPrefix,dst:destinationAddressPrefix,dport:destinationPortRange,prio:priority}" \
    -o table
  iq::info "(empty = only Azure default rules, i.e. all outbound allowed)"
  iq::info "Add a deny-all-Internet outbound rule here to prove that Web IQ /"
  iq::info "Grounding with Bing stops working - it MUST reach the public internet."
fi

iq::ok "network flow evidence written to ${EVIDENCE_DIR}"
