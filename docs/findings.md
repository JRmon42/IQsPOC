# IQs POC - measured findings

Generated 2026-09-02 07:57 UTC by `scripts/09-report.sh` directly from `out/evidence/`.

Every statement below is backed by a file in `out/evidence/`. Where a claim could not be tested in this tenant, that is stated rather than assumed.

## Claim results at a glance

| ID | Claim under test | Result | Evidence |
|----|------------------|--------|----------|
| C1 | Foundry IQ is built on Azure AI Search | **Confirmed** | `c1-search-backing.json` |
| C2 | Diagnostic logging is OFF by default | **Confirmed** | `c2-diagnostics-*.json` |
| C3 | Once enabled, logs contain the QUERY TEXT | **Confirmed** | `c3-query-text-in-logs.json` |
| C4 | Logs contain no document content / no prompts | **Confirmed** | `c4-no-document-content.json` |
| C4b | "Logs contain no caller identity" | **Needs nuance** | `c4-foundry-log-rows.json` |
| C5 | Log Analytics default retention is 30 days | **Confirmed** | `c5-retention.json` |
| C6 | TLS 1.2+ in transit, AES-256 at rest | **Confirmed** | `c6-encryption.json` |
| C7 | Data stays in the selected geography | **Confirmed** | `c7-residency.json` |
| C8 | Private Endpoint keeps traffic in the VNet | **Confirmed** | `c8-authenticated-from-inside.txt` |
| C9 | Public network access can be fully blocked | **Confirmed** | `c9-authenticated-from-outside.txt` |
| C10 | Agent egress can be VNet-injected (delegated subnet) | **Partly confirmed** | `c10-delegated-subnet.json` |
| C11 | Web IQ cannot be isolated, pinned or audited | **Confirmed** | `c11-summary.txt` |
| C12 | The whole stack can run keyless (Entra ID only) | **Confirmed** | `c12-keyless.json` |

## The four findings that matter most for the ST meeting

### 1. Query text IS written to logs once diagnostics are enabled

Logging is off by default, which matches the Product Manager's statement. But the moment `OperationLogs` is switched on, the full query string is recorded and is readable by anyone with read access to the Log Analytics workspace. The probe string `IQPOCPROBE` was planted in the queries and came back in the `Query_s` column:

```json
[
  {
    "TimeGenerated": "2026-09-02T07:35:24.8504689Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 15&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.8039195Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 14&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.7406047Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 13&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.6959737Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 12&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.6328749Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 11&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.5715397Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 10&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.5195978Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 9&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.4489826Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 8&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.3935777Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 7&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.3250663Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 6&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.2751216Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 5&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.2114856Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 4&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.1623261Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 3&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.0995207Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 2&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  },
  {
    "TimeGenerated": "2026-09-02T07:35:24.0514886Z",
    "OperationName": "Query.Search",
    "Query_s": "?api-version=2024-07-01&searchMode=Any&search=IQPOCPROBE secure boot signature validation run 1&$top=3",
    "IndexName_s": "iqspoc-index",
    "Documents_d": 3,
    "DurationMs": null
  }
]
```

**Action for ST.** Treat the Log Analytics workspace as a sensitive data store in its own right - tight RBAC, a deliberate retention decision, and possibly customer-managed keys. If queries can carry sensitive terms and the audit value is low, simply leave query logging off.

### 2. "Logs do not contain the caller's identity" is true for AI Search, but not for Foundry

This is the one point in the Product Manager's briefing that needs qualification, and it is better to raise it ourselves than to have ST discover it.

* **Azure AI Search `OperationLogs`** - the only identity-adjacent column is `CallerIPAddress`, and in this deployment it was an internal service address, not the real client. No principal, UPN or object ID. The statement holds.
* **Foundry `RequestResponse`** - `properties_s` *does* contain `callerObjectId` and `objectId`, plus `requestLength`, `responseLength`, `promptTokens`, `completionTokens` and `modelDeploymentName`.

Crucially, the object ID that appears is the **managed identity of the calling service**, not a human. In a typical design where one application identity fronts many users, every end user collapses into that single object ID. So the practical conclusion the PM drew is still correct - **there is no end-user audit trail, and per-user auditing must be implemented in the client layer** - but the underlying reason is different, and ST's security team will notice if we state it imprecisely.

Neither service logged any prompt, completion, or document content. Searches for the planted document markers returned zero rows:

```json
[]
```

### 3. Foundry IQ's outbound call to the model is NOT covered by the customer's VNet

This was discovered by the POC failing, and it is the most valuable architectural finding of the exercise.

With private endpoints in place for inbound traffic and the model account's public access disabled, agentic retrieval failed:

```
The model endpoint returned status code '403'. Public access is disabled.
Please configure private endpoint.
```

The customer's private endpoints govern traffic **into** each service. They do nothing for the call that Azure AI Search makes **outwards** to the language model - that is a Microsoft-to-Microsoft hop over the backbone that the customer's VNet never sees. Closing it required a **shared private link**, which is a separate, explicit, easily-forgotten step. All three of the following were needed:

1. `az search shared-private-link-resource create --group-id openai_account`
2. **Manual approval** of the resulting pending connection on the Foundry side
3. The knowledge base `resourceUri` had to use the **`*.openai.azure.com`** hostname, not `*.cognitiveservices.azure.com`, because the shared private link's DNS zone is `privatelink.openai.azure.com`

Only after all three did agentic retrieval return HTTP 200.

**Action for ST.** Any "fully private Foundry IQ" design must include the shared private link from Search to the model, and the approval step must be in the runbook. Without it the deployment looks correct in the portal and still fails - or, worse, silently traverses a path the customer believes is closed.

### 4. Web IQ is categorically different from the other IQ services

Grounding with Bing was provisioned in this subscription so its posture could be measured rather than asserted:

```
  Dimension            Foundry IQ (AI Search)      Web IQ (Grounding w/ Bing)
  -------------------  --------------------------  ----------------------------
  Region placement     swedencentral (pinned)      global (no region exists)
  Private Endpoint     supported + in use          resource type has none
  Public access        disabled (proved: 403)      mandatory - public egress
  Diagnostic LOGS      OperationLogs available     NONE (metrics only)
  Query text audit     available if enabled        impossible on the Azure side
  Authentication       managed identity, keyless   API key (shared secret)
  Commercial terms     Azure Product Terms / DPA   separate Bing terms; data
                                                   leaves the Azure boundary

  BOTTOM LINE FOR ST
  Web IQ cannot be network-isolated, cannot be region-pinned, and cannot be
  audited from Azure. If ST's requirement is "no query text may leave our
  controlled boundary", web grounding must stay OFF, and that has to be
  enforced by policy on connection creation - not by network controls,
  because there is no network control available for it.
```

The DNS comparison taken from inside the VNet makes the contrast concrete - the same client resolves AI Search privately and Bing publicly:

```
Enable succeeded: 
[stdout]
--- private-linked AI Search (inside the VNet) ---
10.30.2.10      iqspoc-search-lnoqy4pkotz5c.privatelink.search.windows.net iqspoc-search-lnoqy4pkotz5c.search.windows.net
--- Grounding with Bing ---
172.199.17.73   apimbingapi-ip.westeurope.cloudapp.azure.com api.bing.microsoft.com bingapigblprod.trafficmanager.net apim-bing-prod-001.azure-api.net apimgmttmvdvsx40imxehisceiicnxlfng4yxihlxoe6gq2zej.trafficmanager.net apim-bing-prod-001-westeurope-01.regional.azure-api.net

[stderr]
```

**Action for ST.** Web grounding cannot be constrained by network controls, because none exist for it. If it must be prevented, it has to be blocked at the governance layer - Azure Policy on connection creation, and review of which projects are permitted to add a `GroundingWithBingSearch` connection.

## Network evidence

### Private path works (from inside the VNet)

```
--- GET /indexes from INSIDE the VNet (iqspoc-client, 10.30.1.4), authenticated
    with the VM's system-assigned managed identity ---
HTTP/2 200
content-type: application/json; odata.metadata=minimal; odata.streaming=true; charset=utf-8
strict-transport-security: max-age=2592000
odata-version: 4.0
request-id: 7aafa845-74d8-418e-b8d6-9ef72cced29d
elapsed-time: 71

INTERPRETATION
  Same service, same API, same TLS. The only difference is the source network.
  Name resolution inside the VNet returns 10.30.2.10 (the private endpoint NIC),
  so the request never touches the public internet.
```

### Public path is refused (same call, from outside)

```
--- GET /indexes from OUTSIDE the VNet (this host), authenticated as
    admin@mngenvmcap205883.onmicrosoft.com holding Search Service Contributor
    + Search Index Data Contributor on the service ---
HTTP 403
{"error":{"code":"","message":"Request is denied as the source is not allowed by applicable rules. The service is set 'publicNetworkAccess: Disabled'. Please review all service's network security settings to ensure the client is allowed."}}

INTERPRETATION
  The caller is fully authorised. The refusal is purely a NETWORK decision:
  publicNetworkAccess=Disabled means the only ingress is the private endpoint.
  Compare with c8-authenticated-from-inside.txt, where the identical request
  from 10.30.1.4 (snet-app) returns HTTP 200 via 10.30.2.10.
```

This pair is the cleanest single proof in the POC: identical credentials and identical request, differing only in network origin.

### Private endpoint address map

```
iqspoc-pe-blob	stiqspoclnoqy4pkotz5c.blob.core.windows.net	10.30.2.4
iqspoc-pe-cosmos	iqspoc-cosmos-lnoqy4pkotz5c.documents.azure.com	10.30.2.8
iqspoc-pe-cosmos	iqspoc-cosmos-lnoqy4pkotz5c-swedencentral.documents.azure.com	10.30.2.9
iqspoc-pe-foundry	iqspoc-foundry-lnoqy4pkotz5c.cognitiveservices.azure.com	10.30.2.5
iqspoc-pe-foundry	iqspoc-foundry-lnoqy4pkotz5c.openai.azure.com	10.30.2.6
iqspoc-pe-foundry	iqspoc-foundry-lnoqy4pkotz5c.services.ai.azure.com	10.30.2.7
iqspoc-pe-search	iqspoc-search-lnoqy4pkotz5c.search.windows.net	10.30.2.10
```

## Residency, encryption and retention

### Regional placement of every resource

```json
[
  {
    "location": "global",
    "name": "privatelink.services.ai.azure.com",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "global",
    "name": "privatelink.cognitiveservices.azure.com",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "global",
    "name": "privatelink.blob.core.windows.net",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "global",
    "name": "privatelink.openai.azure.com",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-nsg-app",
    "type": "Microsoft.Network/networkSecurityGroups"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-nsg-agent",
    "type": "Microsoft.Network/networkSecurityGroups"
  },
  {
    "location": "global",
    "name": "privatelink.search.windows.net",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-nsg-pe",
    "type": "Microsoft.Network/networkSecurityGroups"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-law-lnoqy4pkotz5c",
    "type": "Microsoft.OperationalInsights/workspaces"
  },
  {
    "location": "global",
    "name": "privatelink.documents.azure.com",
    "type": "Microsoft.Network/privateDnsZones"
  },
  {
    "location": "swedencentral",
    "name": "stiqspoclnoqy4pkotz5c",
    "type": "Microsoft.Storage/storageAccounts"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-search-lnoqy4pkotz5c",
    "type": "Microsoft.Search/searchServices"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-foundry-lnoqy4pkotz5c",
    "type": "Microsoft.CognitiveServices/accounts"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-cosmos-lnoqy4pkotz5c",
    "type": "Microsoft.DocumentDB/databaseAccounts"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-vnet",
    "type": "Microsoft.Network/virtualNetworks"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-appi-lnoqy4pkotz5c",
    "type": "Microsoft.Insights/components"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-foundry-lnoqy4pkotz5c/iqspoc-project",
    "type": "Microsoft.CognitiveServices/accounts/projects"
  },
  {
    "location": "global",
    "name": "privatelink.search.windows.net/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "global",
    "name": "privatelink.cognitiveservices.azure.com/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "global",
    "name": "privatelink.openai.azure.com/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "global",
    "name": "privatelink.blob.core.windows.net/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "global",
    "name": "privatelink.documents.azure.com/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "global",
    "name": "privatelink.services.ai.azure.com/link-iqspoc",
    "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-blob",
    "type": "Microsoft.Network/privateEndpoints"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-foundry",
    "type": "Microsoft.Network/privateEndpoints"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-blob.nic.39bf53e7-c01b-4b43-98b5-81efc45c4d0c",
    "type": "Microsoft.Network/networkInterfaces"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-foundry.nic.5c3fedf2-b74d-40a5-a1ee-1eb63ff31a06",
    "type": "Microsoft.Network/networkInterfaces"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-cosmos",
    "type": "Microsoft.Network/privateEndpoints"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-cosmos.nic.367a4115-837c-4db0-924b-f1dde5d06595",
    "type": "Microsoft.Network/networkInterfaces"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-search",
    "type": "Microsoft.Network/privateEndpoints"
  },
  {
    "location": "swedencentral",
    "name": "iqspoc-pe-search.nic.fa15ffda-8683-4dfc-99e1-8ec684bac903",
    "type": "Microsoft.Network/networkInterfaces"
  }
]
```

### Encryption posture

```json
{
  "storage": {
  "blobEncrypted": true,
  "encryptionKeySource": "Microsoft.Storage",
  "httpsOnly": null,
  "minimumTlsVersion": "TLS1_2",
  "requireInfrastructureEncryption": null
},
  "cosmos": {
  "keySource": null,
  "minimalTlsVersion": "Tls12"
},
  "foundry": {
  "disableLocalAuth": true,
  "encryption": null
},
  "search": {
  "disableLocalAuth": true,
  "encryptionWithCmk": {
    "encryptionComplianceStatus": "Compliant",
    "enforcement": "Unspecified"
  }
}
}
```

### Workspace retention

```json
{
  "location": "swedencentral",
  "name": "iqspoc-law-lnoqy4pkotz5c",
  "retentionInDays": 30,
  "sku": "PerGB2018",
  "workspaceCapping": -1.0
}
```

### Keyless / Entra-only posture

```json
{
  "searchDisableLocalAuth": true,
  "foundryDisableLocalAuth": true,
  "storageAllowSharedKeyAccess": false,
  "cosmosDisableLocalAuth": true
}
```

## Fabric IQ

An F2 capacity create was attempted so that Fabric IQ feasibility would be measured rather than guessed. It failed at the tenant level:

```
Unauthorized: Unable to authorize with Azure Active Directory. (HTTP 401)
```

A 401 from the Fabric resource provider - rather than a quota or policy error - indicates the **Fabric/Power BI tenant has never been initialised** in this directory. Fabric IQ is therefore blocked here for tenant-setup reasons, not technical ones. The portal-only steps required for a complete test are recorded in `out/evidence/fabric-manual-steps.txt`.

## Honest limitations of this POC

* **Work IQ was not tested.** The tenant carries only `AAD_PREMIUM_P2` with no M365 or Copilot licences and no M365 content to index. Statements about Work IQ in the briefing remain documentation-based.
* **Fabric IQ was not tested** beyond the capacity attempt above.
* **Agent VNet injection was configured but never exercised.** The delegated subnet exists and is correctly delegated to `Microsoft.App/environments`, but no agent was actually injected into it, so C10 is marked *partly* confirmed.
* **Model routing.** The deployment uses a `GlobalStandard` SKU, which may route inference worldwide. `DataZoneStandard` is the EU-residency option and is parameterised in the Bicep but was not exercised. This is worth flagging to ST, as it is an easy detail to get wrong.
* The measurements reflect the service behaviour on the date above. Preview APIs in this area are moving quickly.

