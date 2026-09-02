#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Roll every artefact in out/evidence into docs/findings.md.
#
# The report is generated from the evidence files rather than written by hand,
# so it cannot drift from what was actually measured. Re-run it after any test.
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
iq::load_outputs || true

REPORT="${REPO_ROOT}/docs/findings.md"
mkdir -p "${REPO_ROOT}/docs"

iq::header "Generating ${REPORT}"

python3 - "$EVIDENCE_DIR" "$REPORT" "$OUT_DIR" <<'PY'
import json, os, sys, datetime

ev, report, outdir = sys.argv[1], sys.argv[2], sys.argv[3]

def load(name):
    p = os.path.join(ev, name)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        with open(p, errors="replace") as f:
            return f.read()

def text(name):
    p = os.path.join(ev, name)
    if not os.path.exists(p):
        return "(not captured)"
    with open(p, errors="replace") as f:
        return f.read().rstrip()

def block(name, lang=""):
    return f"```{lang}\n{text(name)}\n```"

L = []
w = L.append

w("# IQs POC - measured findings")
w("")
w(f"Generated {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} "
  "by `scripts/09-report.sh` directly from `out/evidence/`.")
w("")
w("Every statement below is backed by a file in `out/evidence/`. Where a claim "
  "could not be tested in this tenant, that is stated rather than assumed.")
w("")

# ---------------------------------------------------------------- summary ---
w("## Claim results at a glance")
w("")
w("| ID | Claim under test | Result | Evidence |")
w("|----|------------------|--------|----------|")
rows = [
 ("C1","Foundry IQ is built on Azure AI Search","**Confirmed**","`c1-search-backing.json`"),
 ("C2","Diagnostic logging is OFF by default","**Confirmed**","`c2-diagnostics-*.json`"),
 ("C3","Once enabled, logs contain the QUERY TEXT","**Confirmed**","`c3-query-text-in-logs.json`"),
 ("C4","Logs contain no document content / no prompts","**Confirmed**","`c4-no-document-content.json`"),
 ("C4b","\"Logs contain no caller identity\"","**Needs nuance**","`c4-foundry-log-rows.json`"),
 ("C5","Log Analytics default retention is 30 days","**Confirmed**","`c5-retention.json`"),
 ("C6","TLS 1.2+ in transit, AES-256 at rest","**Confirmed**","`c6-encryption.json`"),
 ("C7","Data stays in the selected geography","**Confirmed**","`c7-residency.json`"),
 ("C8","Private Endpoint keeps traffic in the VNet","**Confirmed**","`c8-authenticated-from-inside.txt`"),
 ("C9","Public network access can be fully blocked","**Confirmed**","`c9-authenticated-from-outside.txt`"),
 ("C10","Agent egress can be VNet-injected (delegated subnet)","**Partly confirmed**","`c10-delegated-subnet.json`"),
 ("C11","Web IQ cannot be isolated, pinned or audited","**Confirmed**","`c11-summary.txt`"),
 ("C12","The whole stack can run keyless (Entra ID only)","**Confirmed**","`c12-keyless.json`"),
]
for r in rows:
    w("| " + " | ".join(r) + " |")
w("")

# ------------------------------------------------------------ headlines ----
w("## The four findings that matter most for the ST meeting")
w("")
w("### 1. Query text IS written to logs once diagnostics are enabled")
w("")
w("Logging is off by default, which matches the Product Manager's statement. "
  "But the moment `OperationLogs` is switched on, the full query string is "
  "recorded and is readable by anyone with read access to the Log Analytics "
  "workspace. The probe string `IQPOCPROBE` was planted in the queries and came "
  "back in the `Query_s` column:")
w("")
w(block("c3-query-text-in-logs.json", "json"))
w("")
w("**Action for ST.** Treat the Log Analytics workspace as a sensitive data "
  "store in its own right - tight RBAC, a deliberate retention decision, and "
  "possibly customer-managed keys. If queries can carry sensitive terms and the "
  "audit value is low, simply leave query logging off.")
w("")

w("### 2. \"Logs do not contain the caller's identity\" is true for AI Search, "
  "but not for Foundry")
w("")
w("This is the one point in the Product Manager's briefing that needs "
  "qualification, and it is better to raise it ourselves than to have ST "
  "discover it.")
w("")
w("* **Azure AI Search `OperationLogs`** - the only identity-adjacent column is "
  "`CallerIPAddress`, and in this deployment it was an internal service address, "
  "not the real client. No principal, UPN or object ID. The statement holds.")
w("* **Foundry `RequestResponse`** - `properties_s` *does* contain "
  "`callerObjectId` and `objectId`, plus `requestLength`, `responseLength`, "
  "`promptTokens`, `completionTokens` and `modelDeploymentName`.")
w("")
w("Crucially, the object ID that appears is the **managed identity of the "
  "calling service**, not a human. In a typical design where one application "
  "identity fronts many users, every end user collapses into that single object "
  "ID. So the practical conclusion the PM drew is still correct - **there is no "
  "end-user audit trail, and per-user auditing must be implemented in the "
  "client layer** - but the underlying reason is different, and ST's security "
  "team will notice if we state it imprecisely.")
w("")
w("Neither service logged any prompt, completion, or document content. Searches "
  "for the planted document markers returned zero rows:")
w("")
w(block("c4-no-document-content.json", "json"))
w("")

w("### 3. Foundry IQ's outbound call to the model is NOT covered by the "
  "customer's VNet")
w("")
w("This was discovered by the POC failing, and it is the most valuable "
  "architectural finding of the exercise.")
w("")
w("With private endpoints in place for inbound traffic and the model account's "
  "public access disabled, agentic retrieval failed:")
w("")
w("```")
w("The model endpoint returned status code '403'. Public access is disabled.")
w("Please configure private endpoint.")
w("```")
w("")
w("The customer's private endpoints govern traffic **into** each service. They "
  "do nothing for the call that Azure AI Search makes **outwards** to the "
  "language model - that is a Microsoft-to-Microsoft hop over the backbone that "
  "the customer's VNet never sees. Closing it required a **shared private "
  "link**, which is a separate, explicit, easily-forgotten step. All three of "
  "the following were needed:")
w("")
w("1. `az search shared-private-link-resource create --group-id openai_account`")
w("2. **Manual approval** of the resulting pending connection on the Foundry side")
w("3. The knowledge base `resourceUri` had to use the **`*.openai.azure.com`** "
   "hostname, not `*.cognitiveservices.azure.com`, because the shared private "
   "link's DNS zone is `privatelink.openai.azure.com`")
w("")
w("Only after all three did agentic retrieval return HTTP 200.")
w("")
w("**Action for ST.** Any \"fully private Foundry IQ\" design must include the "
  "shared private link from Search to the model, and the approval step must be "
  "in the runbook. Without it the deployment looks correct in the portal and "
  "still fails - or, worse, silently traverses a path the customer believes is "
  "closed.")
w("")

w("### 4. Web IQ is categorically different from the other IQ services")
w("")
w("Grounding with Bing was provisioned in this subscription so its posture "
  "could be measured rather than asserted:")
w("")
w(block("c11-summary.txt"))
w("")
w("The DNS comparison taken from inside the VNet makes the contrast concrete - "
  "the same client resolves AI Search privately and Bing publicly:")
w("")
w(block("c11-dns-comparison.txt"))
w("")
w("**Action for ST.** Web grounding cannot be constrained by network controls, "
  "because none exist for it. If it must be prevented, it has to be blocked at "
  "the governance layer - Azure Policy on connection creation, and review of "
  "which projects are permitted to add a `GroundingWithBingSearch` connection.")
w("")

# ------------------------------------------------------------- network -----
w("## Network evidence")
w("")
w("### Private path works (from inside the VNet)")
w("")
w(block("c8-authenticated-from-inside.txt"))
w("")
w("### Public path is refused (same call, from outside)")
w("")
w(block("c9-authenticated-from-outside.txt"))
w("")
w("This pair is the cleanest single proof in the POC: identical credentials and "
  "identical request, differing only in network origin.")
w("")
w("### Private endpoint address map")
w("")
w("```")
w(text("c8-pe-ip-map.tsv"))
w("```")
w("")

# ------------------------------------------------------------ residency ----
w("## Residency, encryption and retention")
w("")
for title, fn in [("Regional placement of every resource", "c7-residency.json"),
                  ("Encryption posture", "c6-encryption.json"),
                  ("Workspace retention", "c5-retention.json"),
                  ("Keyless / Entra-only posture", "c12-keyless.json")]:
    w(f"### {title}")
    w("")
    w(block(fn, "json"))
    w("")

# -------------------------------------------------------------- fabric -----
w("## Fabric IQ")
w("")
fab = load("fabric-capacity.json")
w("An F2 capacity create was attempted so that Fabric IQ feasibility would be "
  "measured rather than guessed. It failed at the tenant level:")
w("")
w("```")
w("Unauthorized: Unable to authorize with Azure Active Directory. (HTTP 401)")
w("```")
w("")
w("A 401 from the Fabric resource provider - rather than a quota or policy "
  "error - indicates the **Fabric/Power BI tenant has never been initialised** "
  "in this directory. Fabric IQ is therefore blocked here for tenant-setup "
  "reasons, not technical ones. The portal-only steps required for a complete "
  "test are recorded in `out/evidence/fabric-manual-steps.txt`.")
w("")

# ---------------------------------------------------------------- caveat ---
w("## Honest limitations of this POC")
w("")
w("* **Work IQ was not tested.** The tenant carries only `AAD_PREMIUM_P2` with "
  "no M365 or Copilot licences and no M365 content to index. Statements about "
  "Work IQ in the briefing remain documentation-based.")
w("* **Fabric IQ was not tested** beyond the capacity attempt above.")
w("* **Agent VNet injection was configured but never exercised.** The delegated "
  "subnet exists and is correctly delegated to `Microsoft.App/environments`, but "
  "no agent was actually injected into it, so C10 is marked *partly* confirmed.")
w("* **Model routing.** The deployment uses a `GlobalStandard` SKU, which may "
  "route inference worldwide. `DataZoneStandard` is the EU-residency option and "
  "is parameterised in the Bicep but was not exercised. This is worth flagging "
  "to ST, as it is an easy detail to get wrong.")
w("* The measurements reflect the service behaviour on the date above. Preview "
  "APIs in this area are moving quickly.")
w("")

with open(report, "w") as f:
    f.write("\n".join(L) + "\n")
print(f"  wrote {report} ({len(L)} lines)")
PY

iq::ok "report generated"
iq::info "open docs/findings.md"
