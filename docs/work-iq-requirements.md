# Work IQ — what is missing, and how to fulfil it

**Status in this POC: BLOCKED, root cause identified.**

## 1. The measured blocker

`./scripts/12-workiq-fabriciq-gaps.sh` asked the services themselves rather
than inferring from documentation:

| Probe | Result |
|---|---|
| `GET /v1.0/subscribedSkus` | one SKU only: `AAD_PREMIUM_P2` |
| `GET /v1.0/sites/root` | `BadRequest: Tenant does not have a SPO license.` |
| `GET /v1.0/external/connections` | `Unauthenticated` (no Graph app permission consented) |

The POC tenant `mngenvmcap205883.onmicrosoft.com` is a **bare Azure tenant**.
It has Entra ID but no Microsoft 365 workloads at all.

This is not a configuration mistake that could be corrected inside the POC.
Work IQ retrieves from the **Microsoft 365 substrate** — SharePoint, OneDrive,
Exchange, Teams and Graph connector content. If that substrate does not exist,
there is nothing to retrieve and no amount of Azure-side configuration helps.

> Note this is a *POC-tenant* limitation, not a product limitation. ST's
> production tenant already has the M365 substrate, so for ST the gap list
> below is mostly "confirm" rather than "acquire".

## 2. Requirements, in dependency order

| # | Requirement | Who provides it | ST's likely status |
|---|---|---|---|
| 1 | A Microsoft 365 tenant with SharePoint Online | M365 licensing | **Already have** |
| 2 | Content in the substrate (SPO/OneDrive/Exchange/Teams) | ST business units | Already have |
| 3 | Microsoft 365 Copilot licences for each user who will query Work IQ | M365 add-on SKU | **Verify — usually the gap** |
| 4 | Graph connectors for non-M365 content (file shares, Confluence, ServiceNow, …) | ST IT | Optional |
| 5 | Semantic index provisioned over the tenant | Automatic after (3) | Follows from (3) |
| 6 | An Entra app registration with the right Graph scopes | ST identity team | To do |
| 7 | Admin consent for those scopes | Global Admin / Privileged Role Admin | To do |
| 8 | The Work IQ / M365 Copilot Retrieval API or MCP endpoint enabled | Preview enrolment | **Verify availability** |

The one that most often stalls a pilot is **(3)**. Work IQ honours per-user
licensing: an unlicensed caller gets no results even if the content and the
app registration are perfect.

## 3. Step-by-step remediation

### 3.1 Confirm the substrate — M365 admin
```
https://admin.microsoft.com -> Billing -> Licenses
```
Confirm an M365 E3/E5 base SKU **and** the `Microsoft_365_Copilot` add-on.
Verify programmatically:
```bash
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --resource "https://graph.microsoft.com" \
  --query "value[].skuPartNumber" -o tsv
```
Expect `SPE_E3` or `SPE_E5`, plus `Microsoft_365_Copilot`.

### 3.2 Assign Copilot licences — M365 admin
Assign to the pilot group only. Work IQ retrieval is evaluated **as the calling
user**, so an unlicensed pilot user silently returns empty results rather than
an error — budget time for this confusing failure mode.

### 3.3 Register the calling application — ST identity team
```bash
az ad app create --display-name "ST-WorkIQ-Client"
```
Add delegated Microsoft Graph permissions:
`Files.Read.All`, `Sites.Read.All`, `Mail.Read`, `ExternalItem.Read.All`
(scope to what the use case genuinely needs — see §4).

### 3.4 Grant admin consent — Global Admin
```
Entra portal -> App registrations -> API permissions -> Grant admin consent
```
This is a **tenant-wide** action and will need ST's change process. Start it
early; it is usually the long pole.

### 3.5 Optional — Graph connectors for non-M365 content
```
https://admin.microsoft.com -> Settings -> Search & intelligence -> Connections
```
Each connector has its own ACL mapping. **Verify that source ACLs are mapped to
Entra identities**, otherwise trimming silently fails open or closed.

### 3.6 Validate
Call the retrieval endpoint with a **delegated** user token (not app-only) and
confirm that two users with different SharePoint permissions get different
results. That single test is the whole security model.

## 4. Privacy and governance points for the ST meeting

* **Permission trimming is the control, and it is per-user.** Work IQ never
  returns content the calling user cannot already open in SharePoint. This is
  the strongest privacy statement available for any of the four IQs.
* **Contrast with the Foundry IQ finding in this POC.** There, retrieval used a
  single managed identity, so every end user collapsed into one object ID in
  the logs and every user saw the same index content. Work IQ is the opposite.
  If ST needs per-user authorisation and per-user audit, Work IQ gives it
  natively and Foundry IQ requires it to be built in the client layer.
* **Audit lands in Purview, not Log Analytics.** Work IQ activity is recorded
  in the **Microsoft 365 unified audit log**, not in the Log Analytics
  workspace that Foundry IQ and AI Search use. ST will therefore operate **two
  separate audit surfaces**; this should be an explicit agenda item.
* **Data boundary.** Work IQ operates under the **M365 Data Protection
  Addendum** and the EU Data Boundary, not the Azure DPA. Both are acceptable
  to ST, but they are different contracts with different commitments.
* **App-only tokens defeat the model.** If ST uses application permissions
  instead of delegated ones, per-user trimming is bypassed. Insist on
  delegated flow for anything touching human-readable content.
* **Retention.** Work IQ adds no new copy of the content — it indexes in place,
  so ST's existing SharePoint retention, sensitivity labels and DLP continue to
  apply unchanged. Labels are honoured at retrieval time.

## 5. What ST should do before the next meeting

1. Confirm the `Microsoft_365_Copilot` SKU count and who holds it.
2. Decide whether the pilot needs Graph connectors or M365-native content only.
3. Identify the Global Admin who can grant consent, and open the change ticket.
4. Decide who owns the Purview audit surface, since it is a different team from
   the one that owns Log Analytics.
