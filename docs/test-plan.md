# Test plan

Each claim ST is likely to challenge is mapped to the script that tests it and
the artefact that proves it. The design rule throughout: **prefer a measurement
that could fail over an assertion that cannot.**

## Method

Two techniques do most of the work.

**Marker strings.** Queries carry `IQPOCPROBE`; indexed document bodies carry
`IQPOCPROBE-DOC-ALPHA/BRAVO/CHARLIE` plus realistic-looking terms (`ECDSA`,
`net-60`, `FD-SOI`). Afterwards the logs are searched for each marker. A hit
proves the data class *is* logged; a zero-row result across a known-good time
window proves it is *not*. This turns "logs don't contain document content"
from a claim into a negative result with a control.

**Inside/outside contrast.** The same authenticated request is issued from a VM
inside the VNet and from the WSL host outside it. Identical credentials,
identical request, only the network origin differs — so a 200/403 split isolates
the network control as the cause.

## Claim matrix

| ID | Claim | Script | Evidence | Result |
|---|---|---|---|---|
| C1 | Foundry IQ is built on Azure AI Search | `02-validate-baseline.sh` | `c1-search-backing.json` | Confirmed |
| C2 | Diagnostic logging is off by default | `02-validate-baseline.sh` | `c2-diagnostics-*.json` | Confirmed |
| C3 | Enabled logs contain query text | `03`, `06` | `c3-query-text-in-logs.json` | Confirmed |
| C4 | Logs contain no document content or prompts | `06-query-logs.sh` | `c4-no-document-content.json` | Confirmed |
| C4b | Logs contain no caller identity | `06-query-logs.sh` | `c4-foundry-log-rows.json` | **Needs nuance** |
| C5 | LAW default retention is 30 days | `02-validate-baseline.sh` | `c5-retention.json` | Confirmed |
| C6 | TLS 1.2+ / AES-256 | `02-validate-baseline.sh` | `c6-encryption.json` | Confirmed |
| C7 | Data stays in the chosen geography | `02-validate-baseline.sh` | `c7-residency.json` | Confirmed |
| C8 | Private Endpoint keeps traffic internal | `04`, `04b` | `c8-authenticated-from-inside.txt` | Confirmed |
| C9 | Public access can be fully blocked | `04`, `04b` | `c9-authenticated-from-outside.txt` | Confirmed |
| C10 | Agent egress can be VNet-injected, and an agent really runs there | `10-agent-flows.sh` | `c10-agent-subnet.json`, `c10-agent-results.json` | Confirmed |
| C13 | An NSG on the injected subnet controls Foundry IQ but NOT Web IQ | `11-nsg-enforcement.sh` | `c13-verdict.json` | Confirmed |
| G1 | Work IQ prerequisites absent in this tenant | `12-workiq-fabriciq-gaps.sh` | `gaps/sharepoint-root.txt` | Confirmed |
| G2 | Fabric IQ prerequisites absent in this tenant | `12-workiq-fabriciq-gaps.sh` | `gaps/fabric-dataplane.txt` | Confirmed |
| C11 | Web IQ cannot be isolated/pinned/audited | `07-web-iq-test.sh` | `c11-summary.txt` | Confirmed |
| C12 | The stack can run keyless | `02-validate-baseline.sh` | `c12-keyless.json` | Confirmed |

## Execution order

Order matters. C2 asserts *no diagnostic settings exist*, so it must run before
step 03 enables them.

```bash
./scripts/01-deploy.sh            # infrastructure
./scripts/02-validate-baseline.sh # C1,C2,C5,C6,C7,C12  <- BEFORE logging is on
./scripts/03-enable-search-logging.sh
./scripts/04-network-flows.sh     # C8,C9,C10 from outside
./scripts/04b-invnet-client.sh    # in-VNet vantage point
./scripts/05-run-tests-invnet.sh  # functional Foundry IQ + planted markers
./scripts/06-query-logs.sh        # C3,C4,C4b
./scripts/07-web-iq-test.sh       # C11
./scripts/08-fabric-iq.sh         # Fabric feasibility (billable; auto-suspends)
./scripts/09-report.sh            # regenerate docs/findings.md
./scripts/99-teardown.sh          # stop the spend
```

Re-running `02` after `03` will legitimately report diagnostic settings present.
That is not a regression — it reflects that logging was switched on deliberately.
To re-test C2 cleanly, redeploy into an empty resource group.

## Deliberate design choices

* **The Bicep creates no diagnostic settings.** Otherwise C2 could not be
  proved. Logging is added later, by an explicit script, which also demonstrates
  that enabling it is a conscious customer act.
* **`enablePrivateNetworking` is a parameter**, so the public/private contrast
  can be demonstrated live in front of the customer.
* **Retention is left at the 30-day default** rather than set explicitly, so C5
  measures the platform default rather than our own parameter.
* **The report is generated from evidence files**, so it cannot drift from what
  was measured.

## Known gaps

* Agent VNet injection is configured but never carried live traffic (C10).
* Work IQ and Fabric IQ untested — see `feasibility.md`.
* `GlobalStandard` model SKU may route inference outside the EU;
  `DataZoneStandard` is parameterised but untested.
* Results reflect service behaviour on the run date; these preview APIs move
  quickly.
