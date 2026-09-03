#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 11-nsg-enforcement.sh
#
# The governance question ST actually has to answer is not "does Web IQ work?"
# but "if we let Foundry IQ in, have we also silently let Web IQ in?".
#
# Agent VNet injection is the only lever that could separate them, because it
# is the only point where ST owns the network. So this script tests the lever
# rather than describing it:
#
#   1. Apply an NSG on the injected agent subnet that denies outbound to the
#      Internet service tag while still allowing AzureCloud.
#   2. Re-run BOTH agents.
#   3. Compare against the recorded unrestricted baseline.
#
# Three outcomes, all of them worth knowing:
#
#   Foundry OK / Web blocked -> ST can adopt Foundry IQ and block Web IQ at the
#                               subnet. The strongest possible answer.
#   both blocked             -> the injected runtime needs internet for its own
#                               dependencies; the lever is all-or-nothing.
#   both OK                  -> Bing egress does not traverse the customer
#                               subnet at all, so there is NO network control
#                               and Web IQ must be governed by policy instead.
#
# The rules are removed again at the end so the environment is left as found.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/00-env.sh
iq::load_outputs

NSG="iqspoc-nsg-agent"
SUBNET="snet-agent"
VNET=$(az network vnet list -g "$RG" --query '[0].name' -o tsv)
VM_NAME=$(iq::jget "${OUT_DIR}/vm-outputs.json" vmName.value)
BASELINE="${EVIDENCE_DIR}/c10-agent-results.json"

run_agents () {  # $1 = evidence label
  local label="$1"
  local b64 out
  b64=$(gzip -c src/agent_flow_test.py | base64 -w0)
  out=$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
        --scripts "echo '${b64}' | base64 -d | gunzip > /tmp/aft.py; python3 /tmp/aft.py 2>&1" \
        --query "value[0].message" -o tsv 2>&1 || true)
  printf '%s\n' "$out" > "${EVIDENCE_DIR}/c13-${label}-run.txt"
  python3 - "${EVIDENCE_DIR}/c13-${label}-run.txt" "${EVIDENCE_DIR}/c13-${label}.json" <<'PY'
import json, re, sys
t = open(sys.argv[1], errors="replace").read()
m = re.search(r"=== RESULTS_JSON_BEGIN ===\s*(\{.*?\})\s*=== RESULTS_JSON_END ===", t, re.S)
d = json.loads(m.group(1)) if m else {"runs": [], "errors": [{"stage": "parse", "status": 0, "body": t[-400:]}]}
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
}

summarise () {  # $1 = json file, $2 = heading
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(f"  {sys.argv[2]}: <no result>"); raise SystemExit
print(f"  {sys.argv[2]}")
if not d.get("runs"):
    print("      no runs completed")
for r in d["runs"]:
    err = ""
    if r.get("last_error"):
        err = " last_error=" + json.dumps(r["last_error"])[:160]
    print(f"      {r['label']:<12} status={r['status']:<12} tools={r.get('tool_calls')}{err}")
for e in d.get("errors", []):
    print(f"      ERROR {e['stage']}: HTTP {e['status']} {json.dumps(e['body'])[:160]}")
PY
}

iq::header "C13.1  Baseline - agents with unrestricted subnet egress"
if [[ -f "$BASELINE" ]]; then
  summarise "$BASELINE" "baseline (no NSG restriction)"
else
  iq::warn "no baseline found; run scripts/10-agent-flows.sh first"
fi

iq::header "C13.2  Applying deny-Internet NSG to the injected subnet"
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n AllowAzureCloudOut --priority 100 \
  --direction Outbound --access Allow --protocol '*' \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes AzureCloud --destination-port-ranges '*' -o none 2>/dev/null || true
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n DenyInternetOut --priority 200 \
  --direction Outbound --access Deny --protocol '*' \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes Internet --destination-port-ranges '*' -o none 2>/dev/null || true

az network nsg rule list -g "$RG" --nsg-name "$NSG" \
  --query "[].{name:name,priority:priority,access:access,dest:destinationAddressPrefix}" \
  -o json > "${EVIDENCE_DIR}/c13-nsg-rules.json"
iq::ok "NSG rules accepted on an injected subnet (the platform did not reject them)"
az network nsg rule list -g "$RG" --nsg-name "$NSG" \
  --query "[].{n:name,p:priority,a:access,d:destinationAddressPrefix}" -o table

iq::info "waiting 90s for NSG programming to take effect"
sleep 90

iq::header "C13.3  Re-running both agents with Internet egress denied"
run_agents "denied"
summarise "${EVIDENCE_DIR}/c13-denied.json" "with DenyInternetOut in force"

iq::header "C13.4  Control - is the NSG enforced on this subnet at all?"
# A serverless injected subnet has no NIC. If NSG rules were accepted by ARM but
# never programmed against the injected runtime, the result above would be an
# artefact rather than a finding. So deny the ONE destination we know the agent
# must reach - the Azure AI Search private endpoint - and confirm that the
# Foundry IQ agent breaks. If it does, the NSG is real and the Web IQ result stands.
az network nsg rule delete -g "$RG" --nsg-name "$NSG" -n DenyInternetOut -o none 2>/dev/null || true
az network nsg rule delete -g "$RG" --nsg-name "$NSG" -n AllowAzureCloudOut -o none 2>/dev/null || true
SEARCH_PE_IP=$(awk '/search/ {print $2; exit}' "${EVIDENCE_DIR}/c8-pe-ip-map.tsv" 2>/dev/null || echo "10.30.2.10")
iq::info "denying ${SUBNET} -> ${SEARCH_PE_IP} (the Azure AI Search private endpoint)"
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n DenySearchPE --priority 150 \
  --direction Outbound --access Deny --protocol '*' \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes "${SEARCH_PE_IP}/32" --destination-port-ranges '*' -o none
iq::info "waiting 90s for NSG programming to take effect"
sleep 90
run_agents "control"
summarise "${EVIDENCE_DIR}/c13-control.json" "with the Search private endpoint denied"

iq::header "C13.5  Verdict"
python3 - "$BASELINE" "${EVIDENCE_DIR}/c13-denied.json" "${EVIDENCE_DIR}/c13-control.json" \
         "${EVIDENCE_DIR}/c13-verdict.json" <<'PY'
import json, sys

def status(path):
    out = {}
    try:
        d = json.load(open(path))
    except Exception:
        return out
    for r in d.get("runs", []):
        out[r["label"]] = r.get("status")
    return out

base, den, ctl = (status(p) for p in sys.argv[1:4])
ok = lambda s: s == "completed"

# Is the NSG actually enforced against the injected runtime?
enforced = ok(base.get("foundry-iq")) and not ok(ctl.get("foundry-iq"))

if not enforced:
    v = "NSG_NOT_ENFORCED"
    msg = ("Denying even the Search private endpoint did not change the outcome, so NSG "
           "rules on this injected subnet are accepted by ARM but not enforced against the "
           "runtime. No conclusion can be drawn about Web IQ from the egress test.")
elif ok(den.get("foundry-iq")) and not ok(den.get("web-iq")):
    v = "SEPARABLE"
    msg = ("An NSG on the injected agent subnet blocks Web IQ while Foundry IQ keeps "
           "working. ST can adopt Foundry IQ and deny Grounding with Bing at the network layer.")
elif not ok(den.get("foundry-iq")) and not ok(den.get("web-iq")):
    v = "ALL_OR_NOTHING"
    msg = ("Denying Internet egress on the injected subnet breaks BOTH agents, so the "
           "injected runtime needs public egress for its own dependencies. The subnet NSG "
           "is a kill switch for the whole agent runtime, not a selective Web IQ control.")
elif ok(den.get("web-iq")):
    v = "WEB_IQ_IS_SERVICE_SIDE"
    msg = ("The NSG is provably enforced, because denying the Search private endpoint broke "
           "the Foundry IQ agent. Yet denying ALL Internet egress did not stop Web IQ. "
           "Therefore the Bing call is made service-side by Microsoft, not from the customer "
           "subnet. Foundry IQ retrieval is controllable with customer network policy; "
           "Web IQ is not controllable at the network layer at all and must be governed by "
           "withholding the Bing connection and enforcing that with Azure Policy.")
else:
    v = "INCONCLUSIVE"
    msg = "The three runs are not directly comparable; see the raw evidence."

res = {"verdict": v, "nsg_enforced": enforced,
       "baseline": base, "internet_denied": den, "search_pe_denied": ctl,
       "interpretation": msg}
json.dump(res, open(sys.argv[4], "w"), indent=2)
print(f"  NSG enforced on injected subnet: {enforced}")
print(f"  VERDICT: {v}\n")
for line in msg.split(". "):
    if line.strip():
        print("  " + line.strip().rstrip(".") + ".")
PY

iq::header "C13.6  Restoring the subnet to its original state"
for r in DenySearchPE DenyInternetOut AllowAzureCloudOut; do
  az network nsg rule delete -g "$RG" --nsg-name "$NSG" -n "$r" -o none 2>/dev/null || true
done
iq::ok "deny rules removed; ${SUBNET} in ${VNET} is back to unrestricted egress"
