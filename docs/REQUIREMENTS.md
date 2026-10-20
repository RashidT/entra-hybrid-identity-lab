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

## Phase 3: OIDC, Graph and Conditional Access (not built yet)

Goal: GitHub Actions signs in to Entra with no stored secret, deploys Conditional Access policies in report-only mode, and Pester reads them back through Microsoft Graph. Sources are listed at the end of this section; anything not backed by an opened page is marked *(unverified)*.

### Prerequisites (confirm in the tenant before building)

| ID | Check | Why | Confirmed |
|----|-------|-----|-----------|
| P-01 | The tenant has at least Microsoft Entra ID P1 (a trial counts). | Conditional Access needs at least P1. | Not yet |
| P-02 | The security defaults state is recorded. Security defaults are not turned off unless replacement policies are enforced the same day. | Microsoft: organizations that replace security defaults with Conditional Access must turn them off, then enable policies immediately. Report-only policies are not a replacement. | Not yet |
| P-03 | Two emergency access accounts exist: cloud-only on `<tenant>.onmicrosoft.com`, never synced (not under `OU=CorpUsers`), in a dedicated group `EmergencyAccess`. Strong auth that is different from normal admin accounts (Microsoft recommends a passkey/FIDO2). | Microsoft's emergency access guidance. | Not yet |
| P-04 | The repo's OIDC `sub` format is known: repos created after July 15, 2026 use the immutable form `repo:OWNER@OWNER-ID/REPO@REPO-ID:...`; older repos use `repo:OWNER/REPO:...`. | The federated credential subject must match the token's `sub` exactly. A wrong subject is accepted when saved and only fails at sign-in. | Not yet |

### Requirements

| ID | Pri | Requirement | Verified by (planned) |
|----|-----|-------------|-----------------------|
| R-50 | P1 | GitHub Actions authenticates with an OIDC federated credential. Issuer `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`, and a subject that matches the real token `sub` exactly (no wildcards: Entra doesn't support them). Neither app has a client secret or certificate. | Graph check that `passwordCredentials` and `keyCredentials` are empty on both apps; federated credentials screenshot |
| R-51 | P1 | Least privilege needs **two** app registrations, because Graph permissions belong to the app, not to a federated credential. `lab-ca-reader`: application permission `Policy.Read.All` only. `lab-ca-deployer`: `Policy.Read.All` + `Policy.ReadWrite.ConditionalAccess` only. Admin consent granted; no delegated permissions; no Entra directory roles assigned to either service principal. | Pester: decode each job's access token and assert the `roles` claim is exactly the expected set (needs no extra Graph permission) *(unverified)* |
| R-52 | P1 | Every lab policy is created with `state` = `enabledForReportingButNotEnforced` and excludes the `EmergencyAccess` group. The deploy script refuses any definition whose state is anything else. Exclusion is kept even though Microsoft says report-only policies don't need it, so switching a policy to On later is safe. | Pester (R-53); deploy script unit test for the refusal; policy list screenshot |
| R-53 | P2 | Pester tests (tag `Graph`) read each `LAB-` policy back through Graph v1.0 and assert state, included and excluded users/groups/roles, conditions and grant controls match the JSON definition in the repo. They fail on drift, on a missing policy, on an unexpected `LAB-` policy, and on any `LAB-` policy that is enabled. | `graph-tests` job in CI |
| R-54 | P2 | The existing `test` job is unchanged and has no `id-token` permission. `id-token: write` exists only on the two Graph jobs, which run only on `main` and never on pull requests. Pull requests keep running the AD unit tests only. | Workflow review; a PR run shows no Graph job |
| R-55 | P1 | Subjects: `graph-tests` (reader app) trusts `ref:refs/heads/main`. `ca-deploy` (deployer app) runs in a GitHub environment `ca-deploy` (deployment branches limited to `main`, required reviewer = you) and trusts `environment:ca-deploy`. A job's token only matches its own app's credential. | Federated credentials screenshot; R-56 |
| R-56 | P2 | Negative check: a run from another branch cannot get a token (the exchange fails with "no matching federated identity record" *(unverified wording)*). The error is captured as evidence. | One manual run from a test branch; screenshot of the failed step |
| R-57 | P1 | Deploy is idempotent and non-destructive: it matches policies by `displayName`, creates missing ones, updates only properties that differ, never deletes, and supports `-WhatIf`. A re-run reports every policy unchanged. | Unit tests with mocked Graph cmdlets; two real runs |
| R-58 | P1 | No tenant-specific values are committed. Policy JSON uses placeholders (for example `{{EmergencyAccessGroupId}}`, `{{PilotGroupId}}`), filled at run time from GitHub secrets or variables. Client ID and tenant ID are stored as secrets so they're masked in logs. Tokens are never written to output. | `Data.Tests.ps1`-style test: no GUIDs and no `onmicrosoft.com` in `policies/*.json`; log review |
| R-59 | P2 | Policy set (prefix `LAB-`): `LAB-001` require MFA for admin roles; `LAB-002` block legacy authentication; `LAB-003` require MFA for the synced `IT-Security-Group` (ties Phase 3 to the hybrid sync). No device compliance policies: in report-only mode they can still prompt for a certificate on macOS, iOS and Android. | R-53 |
| R-60 | P3 | Evidence (redact the tenant name, initial domain and tenant ID; app client IDs optional): federated credentials for both apps; API permissions for both apps (admin consent shown); CA policy list showing Report-only; one policy's Exclude tab showing `EmergencyAccess`; green `graph-tests` and `ca-deploy` runs; one sign-in log entry with the Report-only tab result. Unredacted originals go to `C:\LabEvidence\raw`. | Files in `docs/images/` |
| R-61 | P3 | Actions are pinned to a commit SHA, not a tag. | Workflow review |

### Setup accounts and roles (least privilege for people, not just the apps)

| Setup task | Least privileged Entra role | Notes |
|------------|-----------------------------|-------|
| Create the two app registrations | Application Developer | Creates apps and updates apps it owns. Confirm the creating account appears under **Owners** *(unverified that this is automatic)*. |
| Add the federated credentials | Owner of the app (no extra role) | Microsoft: the app owner, or Application Administrator, Cloud Application Administrator or Hybrid Identity Administrator. |
| Grant admin consent to the Graph application permissions | Privileged Role Administrator | Application Administrator and Cloud Application Administrator can't consent to Microsoft Graph application permissions. Microsoft notes Global Administrator may still be needed in practice; record which one worked. |
| Create, edit and check CA policies in the portal | Conditional Access Administrator | Narrower than Security Administrator. For read-only review: Security Reader. |
| Turn security defaults on or off (P-02) | Conditional Access Administrator | |
| Create the emergency access accounts (P-03) | User Administrator | |
| Create the `EmergencyAccess` group | Groups Administrator | |
| Assign roles, including Global Administrator on the emergency accounts | Privileged Role Administrator | |
| Enable the passkey (FIDO2) method | Authentication Policy Administrator | |
| Read sign-in logs for the report-only evidence (R-60) | Reports Reader | |

| ID | Pri | Requirement | Verified by (planned) |
|----|-----|-------------|-----------------------|
| R-62 | P1 | Each setup task uses the role in the table above, not Global Administrator. Roles go to dedicated cloud-only admin accounts on `<tenant>.onmicrosoft.com`, never to users synced from `rtworks.local`, so an on-prem compromise can't reach a cloud admin role. | Screenshot of each admin account's **Assigned roles** |
| R-63 | P2 | Roles are held only as long as needed: PIM-eligible with activation if the tenant has PIM (needs Entra ID P2 or ID Governance *(unverified)*), otherwise the active assignments are removed when Phase 3 setup is done. The emergency access accounts are the only standing Global Administrators. | Role assignments screenshot before and after setup |
| R-64 | P1 | Workload identities get no Entra roles: least privilege for the apps is the Graph permissions in R-51 only. | Pester (R-51); service principal **Roles and administrators** shows none |

Out of scope for Phase 3: enforcing any policy, sign-in risk policies (need P2), leaver session revocation, and alerting on emergency account sign-ins (Microsoft recommends this; noted as a gap).

Sources (opened 2026-10-20): Microsoft Learn: *Configure an app to trust an external identity provider*; Graph *List policies* and *Create conditionalAccessPolicy* (permissions); Graph *conditionalAccessPolicy resource* (`state` values); *Manage emergency access accounts*; *Least privileged roles by task*; *Grant tenant-wide admin consent*; *Report-only mode*; *Security defaults*. GitHub Docs: *Configuring OpenID Connect in Azure*; *OpenID Connect reference* (immutable `sub`).
