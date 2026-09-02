# What could and could not be tested in this tenant

Tenant `8181de63-3f9c-40ed-9967-94512f7a75fe`,
subscription `7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa` (Sweden Central).

Assessed before building, then re-checked empirically. The distinction between
"we chose not to" and "the tenant would not let us" matters when presenting to
ST, so each blocker below was actually attempted.

| Service | Testable here | Verdict |
|---|---|---|
| **Foundry IQ** | ✅ Yes, end to end | Fully exercised: index → ingest → semantic query → chat → knowledge source → knowledge base → agentic retrieval, all under private networking. |
| **Web IQ** | ✅ Yes (better than expected) | Grounding with Bing provisioned successfully. Its residency, Private Link and logging posture were all measured directly. |
| **Fabric IQ** | ❌ Blocked | F2 capacity create returned **HTTP 401 "Unable to authorize with Azure Active Directory"** from the Fabric RP. |
| **Work IQ** | ❌ Blocked | Tenant carries only `AAD_PREMIUM_P2`. No M365, no Copilot licences, no M365 content to index. |

---

## Foundry IQ — fully testable

Everything ST asked about was reproducible: private endpoints, public-access
denial, keyless auth, diagnostic-logging defaults, log contents, retention,
encryption and residency. This is where the POC's evidence is strongest, and
fortunately it is also the service ST is most likely to adopt first.

It also surfaced the finding that would have bitten a production rollout: the
Search→model shared private link (see `network-flows.md` §3).

## Web IQ — testable, and the results are the most important ones

Initially assessed as *conditional*, on the assumption that Grounding with Bing
would require a payable offer unavailable on an `Internal_2014-09-01`
subscription. That assumption was wrong — the resource provisioned on the first
attempt.

This was fortunate, because it converted the highest-risk topic in the ST
briefing from documentation into measurement. See `findings.md` §4.

## Fabric IQ — blocked at the tenant level

```
HTTP 401  Unauthorized: Unable to authorize with Azure Active Directory.
```

A 401 from the Fabric resource provider — as opposed to a quota, policy or
`SkuNotAvailable` error — indicates the **Fabric / Power BI tenant has never
been initialised** in this directory. The subscription is willing; the tenant
has no Fabric presence for the capacity to attach to.

This is a tenant-setup prerequisite rather than a technical limitation. To
complete a Fabric IQ test someone must first initialise Fabric in the directory,
then perform the portal-only steps captured in
`out/evidence/fabric-manual-steps.txt` — the Ontology, Graph and Data Agent
preview switches are not exposed through ARM at all.

**Still worth raising with ST**, because two Fabric IQ properties differ sharply
from what the POC measured elsewhere:

* Fabric data agent activity lands in the **Microsoft Purview / M365 unified
  audit log**, not in the Log Analytics workspace used by Foundry and AI Search.
  ST would be governing two separate audit surfaces.
* A Fabric data agent invoked with **user identity** enforces that user's
  OneLake permissions — the opposite of the AI Search result in this POC, where
  a single managed identity collapsed every end user into one object ID. For
  ST's per-user auditing requirement this is a meaningful difference.

## Work IQ — not testable

Work IQ indexes Microsoft 365 content through the Microsoft Graph. This tenant
has none: no Exchange, no SharePoint, no Teams, no Copilot licences. There is
nothing to index and no licence under which to index it.

Nothing in this POC therefore validates or contradicts the Work IQ statements in
the briefing document; those remain documentation-based and are labelled as such.

The key Work IQ points for ST are unaffected by the lack of a test, because they
are contractual rather than technical: Work IQ operates inside the Microsoft 365
data boundary, honours existing SharePoint/Graph permissions at query time, and
is covered by the M365 DPA. Validating that would require a licensed tenant with
representative content.

---

## Environment constraints worked around

Recorded because they will recur if anyone re-runs this on a similar machine:

| Constraint | Workaround |
|---|---|
| Bundled Bicep CLI hard-fails without `libicu`; no sudo available | `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` exported in `00-env.sh` |
| `jq` not installed, cannot install | all JSON handled with `python3` |
| `curl` absent on the WSL host (present on the VM) | host-side HTTP via `urllib` |
| `az` `log-analytics` extension will not install | `src/la_query.py` calls the Log Analytics REST API directly |
| `az vm run-command` truncates long stdout from the front | results framed as `gzip -c \| base64 -w0` between BEGINB64/ENDB64 markers |
| `gpt-4o-mini` is in a deprecating state | deployed `gpt-4.1-mini` (2025-04-14) |
| `Standard_B2s` capacity-restricted in Sweden Central | used `Standard_B2as_v2` |
| Search preview APIs are split across versions | `knowledgeSources` → `2025-08-01-preview`; `knowledgeBases` → `2025-11-01-preview` |
