# Fabric IQ — what is missing, and how to fulfil it

**Status in this POC: BLOCKED, root cause identified.**

## 1. The measured blocker

The ARM error alone is unhelpful:

```
PUT .../Microsoft.Fabric/capacities/iqspocfab?api-version=2023-11-01
401  "Unable to authorize with Azure Active Directory."
```

That message suggests a permissions problem on the Azure side, which sent the
first investigation down the wrong path. The Fabric **data plane** gives the
real answer:

```
GET https://api.fabric.microsoft.com/v1/capacities
401  {"errorCode":"UserNotLicensed","message":"User is not licensed"}
```

| Probe | Result |
|---|---|
| `Microsoft.Fabric` RP registration | `Registered` — so the RP is not the problem |
| Existing capacities in subscription | none |
| ARM `PUT` F2 capacity | `401 Unable to authorize with Azure Active Directory` |
| Fabric data plane `/v1/capacities` | `401 UserNotLicensed` |
| Power BI `/v1.0/myorg/groups` | `404 Not Found` |

**Root cause: no Fabric / Power BI tenant has ever been initialised in this
Entra tenant.** `Microsoft.Fabric/capacities` is an ARM resource, but the RP
delegates authorisation to the Power BI service. With no Power BI tenant
object, that delegated check fails and surfaces as a generic ARM 401.

This is the same underlying condition as the Work IQ blocker: the POC tenant
has **only** `AAD_PREMIUM_P2` and no Microsoft 365 or Power BI substrate.

> Registering the resource provider is not enough, and neither is subscription
> Owner rights. The gate is a tenant-level Fabric object that only a licensed
> interactive sign-in creates.

## 2. Requirements, in dependency order

| # | Requirement | Who provides it | Notes |
|---|---|---|---|
| 1 | A Fabric / Power BI tenant initialised in Entra | first licensed interactive sign-in | **The blocker here** |
| 2 | A Fabric (free or Pro) licence on at least one user | M365 licensing | Creates (1) |
| 3 | `Microsoft.Fabric` RP registered | Azure subscription | already done |
| 4 | An F-SKU capacity (F2 is enough to evaluate) | Azure subscription | blocked by (1) |
| 5 | A workspace bound to that capacity | Fabric admin | |
| 6 | Tenant settings for Fabric items, Ontology/Graph preview, data agents | **Fabric Admin portal only** | not scriptable |
| 7 | A lakehouse with data, and an ontology/graph over it | ST data team | the actual work |
| 8 | A Fabric data agent published over the ontology | ST data team | |
| 9 | A project connection from Foundry to the data agent | Azure AI Developer | |

## 3. Step-by-step remediation

### 3.1 Initialise the Fabric tenant — the unblocking step
Assign any Fabric-capable licence (the **free** Fabric licence is sufficient)
to one user, then have that user sign in interactively once:
```
https://app.fabric.microsoft.com
```
The first successful sign-in creates the tenant object. Re-test with:
```bash
az rest --method get --url "https://api.fabric.microsoft.com/v1/capacities" \
        --resource "https://api.fabric.microsoft.com"
```
`UserNotLicensed` must disappear before anything else will work.

### 3.2 Create the capacity
Only after 3.1:
```bash
az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Fabric/capacities/iqspocfab?api-version=2023-11-01" \
  --body '{"location":"swedencentral","sku":{"name":"F2","tier":"Fabric"},
           "properties":{"administration":{"members":["<fabric-admin-upn>"]}}}'
```
F2 costs roughly €0.36/hour and can be **paused** when idle — pause it between
workshops rather than deleting it.

### 3.3 Enable tenant settings — Fabric Admin, portal only
```
app.fabric.microsoft.com -> Settings -> Admin portal -> Tenant settings
```
Enable, **scoped to a security group rather than the whole organisation**:
* *Users can create Fabric items*
* the *Ontology* / *Graph* (preview) switches
* *Users can create and use Fabric data agents*
* *Users can share Fabric data agents*

There is no supported API for these switches, so this step cannot be automated
and must be planned as a manual change with a named owner.

### 3.4 Build the semantic layer — ST data team
Create a workspace on the capacity, add a lakehouse, load data, then define the
**ontology / graph**. This is the substance of Fabric IQ: it is not a connector
but a modelled semantic layer, and it is where most of the effort sits.

### 3.5 Publish a data agent and connect it to Foundry
Create the Fabric data agent over the ontology, then add it as a project
connection in Foundry so an agent can call it as a tool.

### 3.6 Validate
Have two users with different OneLake permissions ask the same question through
the data agent and confirm the answers differ.

## 4. Networking note for ST

Fabric IQ's flow is **not** the Foundry IQ flow measured in
`docs/agent-network-flows.md`. Fabric is a SaaS service reached over its own
public endpoints; a Foundry agent calling a Fabric data agent is a
**service-to-service** call, closer to the Web IQ pattern than the private
endpoint pattern.

The POC established empirically (`scripts/11-nsg-enforcement.sh`) that:

* traffic that traverses the injected agent subnet **is** subject to ST's NSGs;
* service-side calls made by Microsoft on the agent's behalf are **not**.

ST should therefore expect Fabric IQ to be governed by **Fabric tenant settings
and workspace RBAC**, not by network controls. Private Link for Fabric exists
but is a separate tenant-level feature that must be assessed on its own; do not
assume the Foundry IQ private posture extends to it.

## 5. Privacy and governance points for the ST meeting

* **Two audit surfaces, again.** Fabric data agent activity lands in the
  **M365 unified audit log (Purview)**, not the Log Analytics workspace used by
  Foundry IQ and AI Search. Combined with Work IQ, ST will have Azure Monitor
  *and* Purview to govern.
* **Per-user authorisation.** A Fabric data agent enforces the **calling
  user's** OneLake permissions when invoked with user identity — the opposite
  of the Foundry IQ managed-identity behaviour measured in this POC, where all
  end users collapsed into a single object ID.
* **Cross-geography processing.** The agent's language model follows Fabric
  Copilot settings, including the *"data leaves your geography"* toggle.
  Confirm that setting explicitly with ST; the default is not always what an
  EU-resident customer expects.
* **Preview status.** Ontology, graph and data agents are in preview. Preview
  terms exclude the standard SLA and may differ on data handling — this must be
  stated plainly before ST puts real engineering data into a pilot.

## 6. What ST should do before the next meeting

1. Identify who holds Fabric Admin, and whether Fabric is already initialised
   in ST's production tenant (it very likely is).
2. Decide whether ontology/graph preview features are acceptable under ST's
   preview-software policy.
3. Confirm the geography toggle in Fabric Copilot settings.
4. Nominate the data-domain owner for the first ontology — this decision, not
   the infrastructure, determines how long a Fabric IQ pilot takes.
