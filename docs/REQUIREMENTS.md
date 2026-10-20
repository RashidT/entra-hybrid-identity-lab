# Requirements: entra-hybrid-identity-lab

Every review finding is written as a requirement you can test. Priority: **P1** = correctness or safety (do first), **P2** = reliability and quality, **P3** = documentation and polish.
"Verified by" names the test or check that proves it. Where a test is not written yet, it says so. "DC" means a real run against the lab domain; "tenant" means checked in Entra.

## Scripts (`scripts/`)

| ID | Pri | Requirement | Verified by |
|----|-----|-------------|-------------|
| R-01 | P1 | No script reports success unless the change was confirmed (for example 02 re-reads the forest after adding a suffix). | `Scripts.Tests.ps1` (02, "does not report success...") |
| R-02 | P1 | Any failure ends the script with a terminating error (non-zero exit), after per-row results are emitted. | `Scripts.Tests.ps1` (03, 05, 06 failure cases) |
| R-03 | P1 | All input (CSV, parameters, suffix, root OU, groups) is validated before the first change. A failed validation makes zero changes. | `Scripts.Tests.ps1` (03 invalid CSV, unregistered suffix, missing root OU) |
| R-04 | P1 | Every script that changes the directory supports `-WhatIf` and changes nothing under it. | `Scripts.Tests.ps1` (`-WhatIf` case per script) |
| R-05 | P1 | Scripts are repeatable: a second run makes no change and reports `AlreadyExisted` / `NoChange`. | `Scripts.Tests.ps1`; `Integration` test runs 05 with `-WhatIf`; DC: a second real run of 06 reported `0 updated, 100 unchanged` |
| R-06 | P1 | Lookups are limited to the lab root OU. An account with the same name elsewhere is never modified. | `Scripts.Tests.ps1` (03 outside-lab, 05 search base) |
| R-07 | P1 | No password is stored in the CSV or the repo. The initial password is a mandatory `[securestring]` parameter, and users must change it at first logon. | `Data.Tests.ps1` (header has no "password"); `Scripts.Tests.ps1` (03 `ChangePasswordAtLogon`) |
| R-08 | P1 | One failing user does not stop the others, and the failure and its reason are in the output. | `Scripts.Tests.ps1` (03 carry-on case) |
| R-09 | P2 | CSV validation reports all problems at once: required columns, blanks, duplicates, Sam length and characters, UPN shape, department list. | `Data.Tests.ps1` |
| R-10 | P2 | Mover handling (05) checks OU, attributes and department-group membership independently and repairs only what differs. | `Scripts.Tests.ps1` (05 cases) |
| R-11 | P2 | Users are identified by ObjectGUID after lookup, and LDAP filter values are escaped. | `Data.Tests.ps1` (escaping); code review |
| R-12 | P2 | Accounts under the root OU that are not in the CSV (leavers) are reported, never changed. | `Scripts.Tests.ps1` (05 NotInCsv) |
| R-13 | P2 | 04 checks the agent service, updater, service account, TLS 1.2 (.NET and SCHANNEL), connectivity on 443 and certificate revocation on 80, and fails only on real failures. Service names and endpoints are confirmed against Microsoft's current documentation. | `Scripts.Tests.ps1` (04); DC: 9/9 Pass (`agent-health.png`), updater service name confirmed with `Get-Service`. Checked against Microsoft's Cloud Sync prerequisites and troubleshooting pages (2026-10-20). Known limit: the wildcard service endpoints (`*.msappproxy.net`, `*.servicebus.windows.net`) can't be tested by host name |
| R-14 | P2 | 06 changes UPN to `<Sam>@<suffix>` only for a registered suffix, reports before and after, and can write a CSV log as evidence. | `Scripts.Tests.ps1` (06); DC: real run, `100 updated` |
| R-15 | P2 | Scripts parse under Windows PowerShell 5.1 and PowerShell 7. | DC: scripts 01-06 run on Windows PowerShell 5.1.20348.5499 (Windows Server 2022 build); CI: analyzer and unit tests on PowerShell 7 (`pwsh`, `windows-latest`) |
| R-16 | P1 | Leavers (JML): with `-ProcessLeavers`, accounts under the root OU that are not in the CSV are disabled first, removed from department groups only, stamped with a leaver description, and moved last to the Disabled OU under the root OU. Nothing is deleted. | `Scripts.Tests.ps1` (05 leavers); fake-AD harness; DC + tenant: one test leaver processed, disabled in Entra by the next sync (`docs/images/leaver-*.png`) |
| R-17 | P1 | Leaver processing is opt-in, repeatable (`AlreadyLeaver`), completes an interrupted run, supports `-WhatIf`, and stops before any change if more than `-MaxLeavers` (default 10) would be processed, to guard against a wrong or truncated CSV. | `Scripts.Tests.ps1`; DC: `-WhatIf` reported `1 would process` and changed nothing |
| R-18 | P2 | A CSV user found in the Disabled OU (rehire) is reported as Failed and not moved or re-enabled. | `Scripts.Tests.ps1` |
| R-19 | P3 | Summary lines tell a preview from a real run: under `-WhatIf`, 05 and 06 report "would update" / "would process" counts; a real run reports what changed. | DC (05 and 06, both modes); unit tests in `tests/Scripts.Tests.ps1` (names end in "(R-19)") |

## Tests and CI

| ID | Pri | Requirement | Verified by |
|----|-----|-------------|-------------|
| R-20 | P1 | Unit tests run on a GitHub-hosted runner with no Active Directory, using stand-in cmdlets (`tests/TestSetup.ps1`). | CI run |
| R-21 | P1 | Tests assert behavior (which commands were called and with what), not only that the script ran. | `Scripts.Tests.ps1` |
| R-22 | P2 | Integration tests are tagged `Integration`, skipped without the AD module, and excluded in CI. | `IdentityLab.Integration.Tests.ps1`, workflow |
| R-23 | P2 | The workflow pins Pester and PSScriptAnalyzer versions, uses `permissions: contents: read`, has a timeout, fails on any analyzer finding, and uploads NUnit results even on failure. | `pester-tests.yml` |
| R-24 | P2 | `data/users.csv` has no Password column. | `Data.Tests.ps1` |
| R-25 | P3 | Delete the old `tests/IdentityLab.Tests.ps1` (replaced by the three files above). | Repo listing (done: file not present) |

## Runbook: start on .local, then migrate

| ID | Pri | Requirement | Verified by |
|----|-----|-------------|-------------|
| R-30 | P1 | Order: 01 (OUs) -> 03 (users on `@rtworks.local`) -> sync -> baseline evidence -> 02 (register suffix) -> 06 (move UPNs) -> sync -> after evidence. | Write-up in `docs/`; followed in this order in the lab |
| R-31 | P2 | Baseline evidence: on-prem UPN, cloud UPN (the tenant's initial `.onmicrosoft.com` domain, not `.local`: confirmed in the lab tenant), and sync scope including `OU=CorpUsers` and its sub-OUs. | Screenshots (`docs/images/01-`, `02-`, `scoping-filter*.png`) |
| R-32 | P2 | After evidence: the on-prem and cloud UPNs match; use `06 -LogPath` for the before/after table. | `docs/images/03-`, `04-*.png`; `docs/upn-migration.csv` (rebuilt from the CSV and AD, because the real run had no `-LogPath`) |
| R-33 | P3 | Record the one-line rationale: Cloud Sync matches on the source anchor, not the UPN, so `.local` syncs; the UPN just does not match until migrated. | README and `docs/architecture.md` section 4, citing Microsoft's Cloud Sync FAQ |

## Documentation

| ID | Pri | Requirement |
|----|-----|-------------|
| R-40 | P3 | README uses the new script names (`01-Initialize-OUStructure`, `04-Test-CloudSyncAgent`, `06-Set-UserUPN`). |
| R-41 | P3 | README documents `-InitialPassword`, the optional `-RootTargetOU`, `-WhatIf`, and how to run the tests. |
| R-42 | P3 | README credits both Microsoft tutorials (basic AD environment; Cloud Sync) with corrected links. Links opened and checked 2026-10-19. |
| R-43 | P3 | README states what is simulated versus real, and which tests need a domain controller. |

## Phase 3 (not built yet)

| ID | Pri | Requirement |
|----|-----|-------------|
| R-50 | P1 | GitHub Actions authenticates to Entra with an OIDC federated credential scoped to this repo and branch. No client secret is stored. |
| R-51 | P1 | The app registration has least-privilege Graph permissions (read policy state for tests; write only for the deploy job). |
| R-52 | P1 | Conditional Access policies are deployed in report-only mode, with break-glass accounts excluded. |
| R-53 | P2 | Pester tests read policy state back from Graph and assert it matches the intended definition. |
| R-54 | P2 | The OIDC job is separate (`id-token: write` only there) and runs only on `main`. |
