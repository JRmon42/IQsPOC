# Network flows between the IQ services and customer applications

This is the answer to ST's central question: *where does the traffic actually
go, and which parts of it can we control?*

Everything here was measured in the deployed POC (`rg-iqs-poc-sc`,
Sweden Central), not taken from documentation. Where a flow could not be
exercised, it is labelled as such.

---

## 1. The deployed topology

```
                          CUSTOMER-CONTROLLED BOUNDARY
  ┌──────────────────────────────────────────────────────────────────────┐
  │  VNet  iqspoc-vnet   10.30.0.0/16                                    │
  │                                                                       │
  │  snet-app     10.30.1.0/24   application / agent client               │
  │     └── iqspoc-client (10.30.1.4), no public IP                       │
  │                                                                       │
  │  snet-agent   10.30.3.0/24   delegated: Microsoft.App/environments    │
  │     └── reserved for Foundry Agent VNet injection (egress)            │
  │                                                                       │
  │  snet-pe      10.30.2.0/24   private endpoints (inbound)              │
  │     ├── 10.30.2.4   blob        stiqspoc….blob.core.windows.net       │
  │     ├── 10.30.2.5   foundry     ….cognitiveservices.azure.com         │
  │     ├── 10.30.2.6   foundry     ….openai.azure.com                    │
  │     ├── 10.30.2.7   foundry     ….services.ai.azure.com               │
  │     ├── 10.30.2.8   cosmos      ….documents.azure.com                 │
  │     ├── 10.30.2.9   cosmos      ….swedencentral.documents.azure.com   │
  │     └── 10.30.2.10  search      ….search.windows.net                  │
  │                                                                       │
  │  NAT Gateway ── deterministic egress 4.165.97.252 ────────────────────┼──▶ internet
  └──────────────────────────────────────────────────────────────────────┘
             │                                    ▲
             │ (A) inbound over Private Link      │ (B) shared private link
             ▼                                    │     Search ──▶ model
  ┌────────────────────────┐            ┌─────────────────────────┐
  │  Azure AI Search       │──────(B)──▶│  Foundry / model        │
  │  public access: OFF    │            │  public access: OFF     │
  └────────────────────────┘            └─────────────────────────┘
             │
             │ (C) NOT controllable by the customer VNet
             ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  Grounding with Bing  ·  location: global  ·  no Private Link    │
  └──────────────────────────────────────────────────────────────────┘
```

Note that a single Foundry account presents **three** distinct private-endpoint
hostnames. All three matter, and picking the wrong one is a real failure mode -
see flow B.

---

## 2. Flow-by-flow reference

| # | Flow | Path taken | Customer control | Measured result |
|---|------|-----------|------------------|-----------------|
| A1 | App → AI Search | Private Endpoint `10.30.2.10` | **Full** – PE + `publicNetworkAccess=Disabled` | HTTP 200 from inside the VNet |
| A2 | Internet → AI Search | blocked at the service | **Full** | HTTP 403, explicit `publicNetworkAccess: Disabled` |
| A3 | App → Foundry model | Private Endpoint `10.30.2.5/.6/.7` | **Full** | no public A record exists at all |
| A4 | App → Storage / Cosmos | PE `10.30.2.4`, `.8`, `.9` | **Full** | keyless, shared-key auth disabled |
| B | **AI Search → model** | Microsoft backbone, *outbound from Search* | **Indirect** – requires a *shared private link* | initially **403**; fixed (see §3) |
| C | Foundry/agent → Bing | **service-side, from Microsoft** – not from the customer VNet | **None** | denying *all* Internet egress on `snet-agent` did not stop it (§7a) |
| D | Agent → AI Search / customer APIs | injected subnet `snet-agent` | **Full** – VNet injection, NSG provably enforced | `serviceAssociationLink` present; denying the Search PE broke the agent (§7a) |
| E | Services → Log Analytics | Azure backbone | Partial – can use AMPLS | logging is off until enabled |
| F | Operators → control plane | `management.azure.com`, public | RBAC / Conditional Access | not a data path |

### Reading the table

Flows **A** and **D** are the ones ST already expects to control, and they
behave exactly as advertised. Flow **B** is the one that surprises people. Flow
**C** is the governance problem.

---

## 3. Flow B — the outbound hop the customer's VNet does not see

**This is the most important technical finding of the POC.**

A private endpoint controls traffic arriving *at* a service. It does nothing
about traffic that the service originates. When Azure AI Search performs
agentic retrieval it must call the language model itself, and that call is a
Microsoft-to-Microsoft hop that never enters the customer's VNet.

With the model's public access disabled — the correct, hardened configuration —
agentic retrieval failed outright:

```
The model endpoint returned status code '403'. Public access is disabled.
Please configure private endpoint.
```

Closing this properly required **all three** of the following. Missing any one
of them leaves the deployment broken or silently mis-pathed:

1. Create the outbound shared private link from Search to the model:
   ```bash
   az search shared-private-link-resource create \
     --name spl-foundry -g <rg> --service-name <search> \
     --group-id openai_account \
     --resource-id <foundry-account-id> \
     --request-message "Foundry IQ agentic retrieval"
   ```
2. **Approve** the resulting pending connection on the Foundry side. It does not
   auto-approve.
3. Point the knowledge base `resourceUri` at the **`*.openai.azure.com`**
   hostname — *not* `*.cognitiveservices.azure.com`. The shared private link is
   created in the `privatelink.openai.azure.com` DNS zone, so only that hostname
   resolves across it.

After all three, agentic retrieval returned HTTP 200.

**What to tell ST.** "Private endpoints everywhere" is not sufficient for a
private Foundry IQ deployment. The Search→model shared private link is a
separate, manual, approval-gated step that must appear in the runbook and in
any landing-zone template. It is easy to miss because the portal shows every
resource as correctly private while retrieval still fails.

---

## 4. Flow C — Web IQ leaves the boundary and cannot be stopped by networking

Measured from the same in-VNet client, resolving both hostnames back to back:

```
--- private-linked AI Search (inside the VNet) ---
10.30.2.10   iqspoc-search-….privatelink.search.windows.net
--- Grounding with Bing ---
172.199.17.73  api.bing.microsoft.com  bingapigblprod.trafficmanager.net
```

Three facts follow, each independently verified:

* `Microsoft.Bing/accounts` has **no `privateLinkResources`** — the resource
  type registration does not exist. Private Endpoint is not merely unused; it
  is unavailable.
* The account's `location` is **`global`**. There is no region to choose, so
  no EU-residency assertion can be made about text sent to Bing.
* Resolution goes through `bingapigblprod.trafficmanager.net`, an explicitly
  **global** Traffic Manager profile. Today it answered from West Europe, but
  the serving region is not something ST controls.

Because there is no network control, the only enforcement point is governance:

* Azure Policy denying creation of connections with
  `category = GroundingWithBingSearch`.
* Review of which Foundry projects may add web-grounding connections.
* Note that the Bing connection is forced to `authType: ApiKey`, while every
  other component in this POC is keyless. Adopting Web IQ reintroduces a
  long-lived shared secret and its rotation obligation.

A NAT Gateway or firewall can of course block the egress, but that blocks the
*feature*, not the *risk* — there is no configuration in which web grounding
works and the query text stays inside ST's boundary.

---

## 5. Proxy and forced-tunnelling — ST's explicit question

ST asked whether a proxy can be inserted. The honest answer differs per flow:

| Scenario | Supported? | Notes |
|---|---|---|
| Proxy for **customer app → IQ services** | **Yes** | This is ordinary outbound HTTPS from ST's own code. Route via Azure Firewall / explicit proxy, or keep it on Private Link and skip the proxy entirely. |
| Force-tunnel the **agent subnet** via UDR to an NVA/firewall | **Yes** | `snet-agent` is a normal delegated subnet; UDRs and NSGs apply. This is the right place to enforce egress policy for agent traffic. |
| Proxy the **Search → model** hop (flow B) | **No** | Customer-side network appliances are not in that path. Use the shared private link instead. |
| Proxy the **Foundry → Bing** hop (flow C) | **Not as a control** | Egress can be blocked, but not inspected in a way that keeps the data inside — the request is destined for a Microsoft-operated global service by design. |
| TLS inspection of any Microsoft-to-Microsoft hop | **No** | Certificate pinning and backbone routing put these outside customer MITM. |

**Recommended pattern for ST:** private endpoints for all inbound IQ traffic,
VNet injection plus a UDR to Azure Firewall for agent egress, and Azure Policy
rather than network controls to govern Web IQ.

---

## 6. Logging as a data flow

Worth treating as a flow in its own right, because it moves query text:

* Diagnostic logging is **off by default** — verified, zero diagnostic settings
  on a fresh deployment.
* Once `OperationLogs` is enabled, **the full query string is written** to the
  Log Analytics workspace and is readable by anyone with workspace read access.
* Document contents, prompts and completions are **never** written.
* The workspace is a separate destination with its own RBAC, retention and
  region. If it sits in a different region from the search service, that is an
  additional residency consideration.
* Grounding with Bing exposes **no log categories at all**, so there is no
  Azure-side record of what was sent to it.

---

## 7. What was not exercised

Stated plainly so the diagram is not over-read:

* **AMPLS placeholder** — see below. Agent VNet injection *was* subsequently
  exercised; see §7a.
* **AMPLS** for Log Analytics private ingestion — not deployed.
* **Work IQ** — blocked in this tenant: Graph replied `Tenant does not have a
  SPO license.` Gap analysis and remediation in `docs/work-iq-requirements.md`.
* **Fabric IQ** — blocked in this tenant: the Fabric data plane replied
  `UserNotLicensed`. Remediation in `docs/fabric-iq-requirements.md`.
* **Model routing** — the deployment uses `GlobalStandard`, which may route
  inference outside the EU. `DataZoneStandard` is the residency-constrained
  option and is parameterised in the Bicep but untested.

---

## 7a. Update — agent injection was exercised after all

Flows C and D above were revised once an agent was genuinely injected into
`snet-agent`. The subnet now carries a `serviceAssociationLink`
(`legionservicelink`), which subnet delegation alone never creates, and both a
Foundry IQ agent and a Web IQ agent ran from it successfully.

Testing NSG rules on that subnet produced a result that changed the conclusion:

| Configuration on `snet-agent` | Foundry IQ agent | Web IQ agent |
|---|---|---|
| Baseline | `completed` | `completed` |
| `Deny * -> Internet` | `completed` | **`completed`** |
| `Deny * -> 10.30.2.10/32` (Search PE) | **`failed`** | `completed` |

The third row is the control: it proves the NSG really is enforced against the
NIC-less injected runtime. Given that, the second row proves the Bing call does
**not** originate from the customer subnet — it is made service-side by
Microsoft.

So flow C was mis-drawn originally. Agent egress to Bing does **not** leave
through the customer's NAT Gateway; `snet-agent` has no NAT Gateway and no
route table attached at all. The NAT address `4.165.97.252` belongs to
`snet-app`, where the test VM runs.

**Consequence for ST:** Foundry IQ retrieval is controllable with customer
network policy (NSG, UDR, forced tunnelling, proxy). Web IQ is not controllable
at the network layer by any means, and must be governed by withholding the Bing
connection and enforcing that with Azure Policy.

Full diagrams: `docs/agent-network-flows.md`.
Reproduce: `./scripts/10-agent-flows.sh` then `./scripts/11-nsg-enforcement.sh`.
