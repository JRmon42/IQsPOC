#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# C10 (completion) - run a NETWORK-INJECTED agent and observe both flows.
#
# Earlier the agent subnet was only *delegated*; nothing had been injected into
# it, so C10 could only be reported as "partly confirmed". This script:
#
#   1. proves the injection actually happened (serviceAssociationLink on the
#      subnet, which only appears once the agent runtime claims it);
#   2. runs an agent that calls Foundry IQ (Azure AI Search)  -> private path;
#   3. runs an agent that calls Web IQ (Grounding with Bing)  -> public egress;
#   4. captures what each flow did, for the network diagrams.
#
# The agent test must execute INSIDE the VNet because the project endpoint has
# public network access disabled - which is itself part of the evidence.
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
iq::load_outputs || exit 1

VM_NAME=$(iq::jget "${OUT_DIR}/vm-outputs.json" vmName.value)
[[ -z "$VM_NAME" ]] && { iq::fail "no in-VNet VM - run scripts/04b-invnet-client.sh"; exit 1; }
ARM="https://management.azure.com"
ACC="${ARM}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}"
PROJ="${ACC}/projects/${PROJECT_NAME}"

# ---------------------------------------------------------------------------
iq::header "C10.1  Is the agent runtime actually injected into snet-agent?"
# ---------------------------------------------------------------------------
az cognitiveservices account show -g "$RG" -n "$FOUNDRY_NAME" -o json 2>/dev/null \
  | python3 -c "
import json,sys
p=json.load(sys.stdin)['properties']
ni=p.get('networkInjections')
print('  networkInjections :', json.dumps(ni))
print('  publicNetworkAccess:', p.get('publicNetworkAccess'))
" | tee "${EVIDENCE_DIR}/c10-network-injection.txt"

az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n snet-agent -o json 2>/dev/null \
  > "${EVIDENCE_DIR}/c10-agent-subnet.json"
python3 - "${EVIDENCE_DIR}/c10-agent-subnet.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sal = d.get('serviceAssociationLinks') or []
print(f"  addressPrefix          : {d.get('addressPrefix')}")
print(f"  delegations            : {[x['serviceName'] for x in d.get('delegations', [])]}")
print(f"  serviceAssociationLinks: {[s.get('name') for s in sal]}")
print(f"  linkedResourceType     : {[s.get('linkedResourceType') for s in sal]}")
if sal:
    print("\n  A serviceAssociationLink only exists once the platform has actually")
    print("  claimed the subnet. Delegation alone never creates one, so this is")
    print("  the difference between 'configured for injection' and 'injected'.")
PY
SAL=$(python3 -c "
import json
d=json.load(open('${EVIDENCE_DIR}/c10-agent-subnet.json'))
print(len(d.get('serviceAssociationLinks') or []))")
[[ "$SAL" != "0" ]] && iq::ok "agent runtime IS injected into snet-agent" \
                    || iq::warn "no serviceAssociationLink - injection has not taken effect"

iq::header "C10.2  Capability hosts (the thing that triggers injection)"
for H in "${ACC}/capabilityHosts/iqspocacchost" "${PROJ}/capabilityHosts/iqspocprojhost"; do
  az rest --method get --url "${H}?api-version=2025-06-01" -o json 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin); p=d['properties']
print(f\"  {d['name']:<18} state={p.get('provisioningState')} kind={p.get('capabilityHostKind')}\")
sub=p.get('customerSubnet')
if sub: print(f\"                     customerSubnet={sub.split('/')[-1]}\")
for k in ('vectorStoreConnections','storageConnections','threadStorageConnections'):
    if p.get(k): print(f'                     {k}={p[k]}')
"
done

# ---------------------------------------------------------------------------
iq::header "C10.3  Running the agents from inside the VNet"
# ---------------------------------------------------------------------------
iq::info "shipping src/agent_flow_test.py to ${VM_NAME} and executing it there"

# az vm run-command truncates long stdout from the FRONT, so the payload is
# gzipped+base64'd in both directions and framed with explicit markers.
SCRIPT_B64=$(gzip -c "${REPO_ROOT}/src/agent_flow_test.py" | base64 -w0)

OUT=$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "echo '${SCRIPT_B64}' | base64 -d | gunzip > /tmp/agent_flow_test.py; \
             python3 /tmp/agent_flow_test.py > /tmp/agentout.txt 2>&1; \
             echo BEGINB64; gzip -c /tmp/agentout.txt | base64 -w0; echo; echo ENDB64" \
  --query "value[0].message" -o tsv 2>&1)

echo "$OUT" | sed -n '/BEGINB64/,/ENDB64/p' | grep -v 'B64$' | tr -d '\n' \
  | base64 -d 2>/dev/null | gunzip 2>/dev/null > "${EVIDENCE_DIR}/c10-agent-run.txt"

if [[ -s "${EVIDENCE_DIR}/c10-agent-run.txt" ]]; then
  cat "${EVIDENCE_DIR}/c10-agent-run.txt"
else
  iq::warn "could not decode agent output; raw run-command message follows"
  echo "$OUT" | tail -40 | tee "${EVIDENCE_DIR}/c10-agent-run.txt"
fi

# Pull the structured block out for the diagram generator.
python3 - "${EVIDENCE_DIR}/c10-agent-run.txt" "${EVIDENCE_DIR}/c10-agent-results.json" <<'PY'
import json, re, sys
try:
    t = open(sys.argv[1], errors="replace").read()
except Exception:
    sys.exit(0)
m = re.search(r"=== RESULTS_JSON_BEGIN ===\s*(\{.*?\})\s*=== RESULTS_JSON_END ===", t, re.S)
if not m:
    print("  (no structured results block found)"); sys.exit(0)
d = json.loads(m.group(1))
json.dump(d, open(sys.argv[2], "w"), indent=2)
print("\n  Parsed agent results:")
for r in d.get("runs", []):
    print(f"    {r['label']:<12} status={r['status']:<10} tools={r.get('tool_calls')}")
    if r.get("last_error"):
        print(f"                 last_error={json.dumps(r['last_error'])[:200]}")
for e in d.get("errors", []):
    print(f"    ERROR {e['stage']}: HTTP {e['status']} {json.dumps(e['body'])[:200]}")
PY

# ---------------------------------------------------------------------------
iq::header "C10.4  Egress evidence - where did each flow actually go?"
# ---------------------------------------------------------------------------
NAT_IP=$(iq::jget "${OUT_DIR}/vm-outputs.json" natEgressIp.value)
iq::info "NAT Gateway egress IP for the client subnet: ${NAT_IP:-<unknown>}"
iq::info ""
iq::info "Foundry IQ flow  : the agent runtime in snet-agent reaches Azure AI Search"
iq::info "                   over the private endpoint. This traffic really does"
iq::info "                   traverse the customer subnet - scripts/11-nsg-enforcement.sh"
iq::info "                   proves it by denying the PE address and breaking the agent."
iq::info "Web IQ flow      : NOT from this subnet. Denying all Internet egress on"
iq::info "                   snet-agent leaves Grounding with Bing working, so the"
iq::info "                   Bing call is made service-side by Microsoft."
iq::info "                   Run scripts/11-nsg-enforcement.sh for the measurement."
iq::info ""
iq::info "Note: snet-agent has no NAT Gateway and no route table attached, so do not"
iq::info "      attribute agent egress to ${NAT_IP:-the client NAT IP} - that address"
iq::info "      belongs to snet-app, where the test VM lives."
iq::info ""
iq::info "Because the agent runtime is injected into snet-agent, that egress is"
iq::info "subject to the customer's UDRs and NSGs on that subnet - which is the"
iq::info "only place ST can technically block Web IQ."

iq::header "C10 complete - see scripts/11-agent-diagrams.sh for the diagrams"
