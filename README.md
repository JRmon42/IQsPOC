# IQs POC — Foundry IQ / Web IQ / Fabric IQ / Work IQ

A hands-on proof of concept that **empirically validates** the security, privacy,
data-retention and networking claims made in the STMicroelectronics briefing
(`Foundry-Work-Web-IQ-Security-Briefing.docx`), and **maps the network flows**
between the Microsoft "IQ" services and customer applications/agents.

| Item | Value |
|---|---|
| Tenant | `8181de63-3f9c-40ed-9967-94512f7a75fe` |
| Subscription | `7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa` (HighPerformanceComputing) |
| Resource group | `rg-iqs-poc-sc` |
| Region | `swedencentral` (EU data residency, matches ST's likely requirement) |
| Identity | `admin@mngenvmcap205883.onmicrosoft.com` |

---

## 1. What this POC proves

Each claim in the briefing maps to a script that produces a machine-readable
artefact under `out/evidence/`.

| # | Briefing claim | Script | Evidence artefact |
|---|---|---|---|
| C1 | Foundry IQ is backed by **Azure AI Search** | `02-validate-baseline.sh` | `c1-search-backing.json` |
| C2 | Diagnostic resource logging is **customer-configured and OFF by default** | `02-validate-baseline.sh` | `c2-diagnostics-*.json` |
| C3 | When enabled, logs capture **query text** | `03-enable-search-logging.sh` + `06-query-logs.sh` | `c3-query-text-in-logs.json` |
| C4 | Logs contain **no document contents** and no prompts/completions | `06-query-logs.sh` | `c4-no-document-content.json` |
| C4b | Logs contain **no caller user identity** — *true for AI Search, needs qualifying for Foundry* | `06-query-logs.sh` | `c4-foundry-log-rows.json` |
| C5 | Log Analytics default retention is **30 days**, configurable | `02-validate-baseline.sh` | `c5-retention.json` |
| C6 | Encryption **TLS 1.2+** in transit, **256-bit AES** at rest | `02-validate-baseline.sh` | `c6-encryption.json` |
| C7 | Data stays in the **selected Azure geography** | `02-validate-baseline.sh` | `c7-residency.json` |
| C8 | **Private Link** keeps retrieval off the public internet | `04b-invnet-client.sh` | `c8-authenticated-from-inside.txt` |
| C9 | Public network access is genuinely **blocked** when disabled | `04-network-flows.sh` | `c9-authenticated-from-outside.txt` |
| C10 | Agent egress uses a **customer-managed delegated subnet** (VNet injection) | `04-network-flows.sh` | `c10-delegated-subnet.json` |
| C11 | **Web IQ / Grounding with Bing leaves the Azure boundary** and cannot run private | `07-web-iq-test.sh` | `c11-summary.txt` |
| C12 | Keyless / Entra-only auth is enforceable (`disableLocalAuth`) | `02-validate-baseline.sh` | `c12-keyless.json` |

### Headline results

Full detail in [`docs/findings.md`](docs/findings.md). Four things are worth
knowing before the customer meeting:

1. **Query text *is* logged once diagnostics are enabled.** Logging is off by
   default (as briefed), but switching on `OperationLogs` records the full
   query string, readable by anyone with Log Analytics read access. Document
   contents and prompts are never logged.
2. **"Logs contain no caller identity" needs qualifying.** True for Azure AI
   Search. Foundry's `RequestResponse` *does* carry `callerObjectId` — though
   it is the calling service's managed identity, not a human, so the practical
   conclusion (no end-user audit trail; audit in the client layer) still holds.
3. **The Search → model hop is not covered by the customer's VNet.** Private
   endpoints govern inbound traffic only. Agentic retrieval failed with a 403
   until a **shared private link** was created *and manually approved*, using
   the `*.openai.azure.com` hostname. Easy to miss, and it breaks production.
4. **Web IQ is categorically different.** Grounding with Bing is `location:
   global`, has **no** `privateLinkResources`, exposes **zero** diagnostic log
   categories, and forces API-key auth. It cannot be controlled by networking —
   only by governance.

## 2. Service-by-service feasibility in this tenant

See [`docs/feasibility.md`](docs/feasibility.md) for the full analysis.

| Service | Status in this tenant | Why |
|---|---|---|
| **Foundry IQ** | ✅ Fully tested | Azure-native; deployed by `infra/main.bicep`. Index → ingest → semantic query → chat → knowledge base → agentic retrieval, all under private networking. |
| **Web IQ** | ✅ Tested | Grounding with Bing provisioned successfully (better than the initial assessment expected), so its residency, Private Link and logging posture were **measured** rather than assumed. |
| **Fabric IQ** | ❌ Blocked | F2 capacity create returned **HTTP 401 "Unable to authorize with Azure Active Directory"** — the Fabric/Power BI tenant has never been initialised in this directory. A tenant-setup prerequisite, not a technical limit. |
| **Work IQ** | ❌ Not testable | The tenant holds only `AAD_PREMIUM_P2`. No M365 / Copilot licences, and no Exchange/Teams/SharePoint content to ground on. Documented analytically instead. |

## 3. Architecture

```
                    Customer network boundary  (vnet 10.30.0.0/16)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │  snet-app  10.30.1.0/24        snet-pe  10.30.2.0/24                 │
  │  ┌──────────────────┐          ┌──────────────────────────────┐      │
  │  │ Customer app /   │  DNS +   │ Private Endpoints (NICs)     │      │
  │  │ test client      │─ TLS ───▶│  • AI Search   (searchService)│─────┼──▶ Azure AI Search
  │  │ (VM / container) │  1.2+    │  • Foundry     (account)      │─────┼──▶ Microsoft Foundry
  │  └──────────────────┘          │  • Blob        (blob)         │─────┼──▶ Storage (BYO docs)
  │                                │  • Cosmos DB   (Sql)          │─────┼──▶ Cosmos (BYO threads)
  │                                └──────────────────────────────┘      │
  │                                                                      │
  │  snet-agent 10.30.3.0/24  ── delegated to Microsoft.App/environments │
  │  ┌──────────────────────────────────────────┐                        │
  │  │ Foundry Agent Service (VNet injection)   │──── egress governed by │
  │  │ agent compute gets NICs in YOUR subnet   │     your NSG / UDR /   │──▶ (only if allowed)
  │  └──────────────────────────────────────────┘     firewall           │    Grounding with Bing
  │                                                                      │       = Web IQ
  └──────────────────────────────────────────────────────────────────────┘
       Private DNS zones: privatelink.search.windows.net,
       privatelink.{cognitiveservices|openai|services.ai}.azure.com,
       privatelink.blob.core.windows.net, privatelink.documents.azure.com
```

**Inbound** (Private Endpoint) and **outbound** (VNet injection into the
delegated subnet) are two different things — see `docs/network-flows.md`.

## 4. Quick start

```bash
git clone https://github.com/JRmon42/IQsPOC.git
cd IQsPOC

az login --tenant 8181de63-3f9c-40ed-9967-94512f7a75fe
az account set --subscription 7771d4f4-8927-4d73-bd3d-6e6e2ed5d2aa

# 1. Deploy (≈10 min).  Use --whatif first if you want a preview.
./scripts/01-deploy.sh

# 2. Capture the "day zero" posture BEFORE anything is switched on.
./scripts/02-validate-baseline.sh

# 3. Turn on Azure AI Search diagnostic logging and observe the delta.
./scripts/03-enable-search-logging.sh

# 4. Map the network flows (private DNS, PE IPs, delegation, public block).
./scripts/04-network-flows.sh

# 4b. Deploy the in-VNet client that provides the "inside" vantage point.
./scripts/04b-invnet-client.sh

# 5. Seed data, index it, run agentic retrieval, then read the logs back.
#    05 runs the functional test FROM the in-VNet VM, so no local pip is needed.
./scripts/05-run-tests-invnet.sh
./scripts/06-query-logs.sh

# 6. Probe Web IQ / Bing grounding: residency, Private Link, log categories.
./scripts/07-web-iq-test.sh

# 7. (Optional) Fabric IQ capacity — billable while running; auto-suspends.
./scripts/08-fabric-iq.sh
FABRIC_SKIP=1 ./scripts/08-fabric-iq.sh   # documentation only, no spend

# 8. Roll everything up into docs/findings.md.
./scripts/09-report.sh
```

Tear down with `./scripts/99-teardown.sh` (prompts for confirmation;
`FORCE=1` to skip, `KEEP_LOGS=1` to retain the Log Analytics workspace).

> **Order matters.** `02-validate-baseline.sh` asserts that *no* diagnostic
> settings exist, so it must run before `03` enables them. Re-running `02`
> afterwards will legitimately report settings present.

## 5. Repository layout

```
infra/
  main.bicep                  core network-isolated Foundry + AI Search stack
  main.parameters.json        parameters for this tenant/subscription
  vm.bicep                    in-VNet test client + NAT Gateway
  modules/private-endpoint.bicep
scripts/
  00-env.sh                   shared env + helpers (no jq dependency)
  01-deploy.sh                what-if + deploy
  02-validate-baseline.sh     C1,C2,C5,C6,C7,C12  — day-zero posture
  03-enable-search-logging.sh C3 setup — opt in to diagnostic logging
  04-network-flows.sh         C9,C10 — DNS, PE IPs, delegation, public block
  04b-invnet-client.sh        C8 — the inside-the-VNet vantage point
  05-run-tests-invnet.sh      functional Foundry IQ run with planted markers
  06-query-logs.sh            C3,C4,C4b — KQL proof of what is and is not logged
  07-web-iq-test.sh           C11 — Bing residency, Private Link, log categories
  08-fabric-iq.sh             Fabric capacity feasibility (auto-suspends)
  09-report.sh                consolidates out/evidence into docs/findings.md
  99-teardown.sh              delete the resource group
src/
  foundry_iq_test.py          index + knowledge base + agentic retrieval
  la_query.py                 Log Analytics REST client (az extension unavailable)
  network_probe.py            resolves every endpoint, reports public vs private
docs/
  feasibility.md              what can and cannot be tested in this tenant
  network-flows.md            detailed flow-by-flow analysis (the core ask)
  test-plan.md                claim → test → expected result matrix
  findings.md                 generated by 09-report.sh
out/                          gitignored - deployment outputs and evidence
```

## 6. Cost

| Resource | SKU | Approx. cost |
|---|---|---|
| Azure AI Search | `basic` | ~€70/month |
| Microsoft Foundry (AIServices) | `S0` | pay-per-token |
| `gpt-4.1-mini` deployment | GlobalStandard, 10K TPM | pay-per-token |
| Storage | Standard_LRS | negligible |
| Cosmos DB | Serverless | negligible |
| Log Analytics | PerGB2018, 30-day retention | ~€2/GB |
| Private endpoints ×4 | — | ~€6/month each |
| NAT Gateway + test VM | Standard_B2as_v2 | ~€40/month combined |
| Grounding with Bing (optional) | G1 | per-transaction |
| Fabric capacity (optional) | F2 | ~€250/month **running** — the script suspends it |

Run `./scripts/99-teardown.sh` when finished.

> **Note on `GlobalStandard`:** for a customer with strict EU residency
> requirements, redeploy with `"modelSkuName": "DataZoneStandard"` in
> `infra/main.parameters.json` so inference stays inside the EU data zone.

## 7. Known environment quirks

* The bundled Bicep CLI hard-fails without `libicu`; all scripts export
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` to work around this without root.
* `jq` is not assumed to be installed — JSON is parsed with `python3`.
* MCAPS governance policy forces storage accounts to
  `publicNetworkAccess=Disabled` and `allowSharedKeyAccess=false`. The template
  declares that posture explicitly and uses **managed identity everywhere** — no
  SAS tokens, no account keys, no API keys.
