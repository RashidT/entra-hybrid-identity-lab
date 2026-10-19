# Architecture: Hybrid Identity Lab

## 1. Summary

This lab connects an on-premises Active Directory Domain Services (AD DS) forest, `rtworks.local`, to a Microsoft Entra tenant with Entra Cloud Sync. PowerShell scripts provision and maintain the users, and the lab demonstrates how the UPN suffix changes what the cloud sees: users start on `@rtworks.local`, are synced, and are then migrated to the tenant's `.onmicrosoft.com` suffix.

The forest, domain controller and Hyper-V VM were built by hand following Microsoft's *Building a basic Active Directory environment* tutorial. The Cloud Sync agent was installed and configured by hand. The scripts take over from there.

## 2. Components

```mermaid
graph TD
    subgraph Host ["Hyper-V host"]
        AD["Domain controller<br/>rtworks.local"]
        Agent["Entra Cloud Sync<br/>provisioning agent"]
        AD -->|"reads in-scope objects"| Agent
    end
    Agent -->|"outbound HTTPS (443)"| Entra["Microsoft Entra tenant<br/>yourtenant.onmicrosoft.com"]
```

The agent only makes outbound connections, so the domain controller needs no inbound port open to the internet. Script `04-Test-CloudSyncAgent.ps1` checks the agent service, its service account, TLS settings, and reachability of the Microsoft endpoints.

## 3. Directory structure

```text
DC=rtworks,DC=local
├── OU=Domain Controllers
└── OU=CorpUsers                      (created by 01; the sync scope)
    ├── OU=IT                         (created by 03, one per department)
    ├── OU=HR
    ├── OU=Finance
    ├── OU=Sales
    ├── OU=Marketing
    ├── OU=Engineering
    ├── OU=Operations
    ├── OU=Legal
    ├── OU=Product
    ├── OU=Customer Support
    └── OU=Disabled                   (created by 05 when the first leaver is processed)
```

- `OU=CorpUsers` separates lab users from the built-in containers. It is protected from accidental deletion.
- Each department OU holds the users whose CSV `Department` matches. Each department also has a security group named `<Department>-Security-Group`, created by 03.
- `OU=Disabled` holds deprovisioned leavers. It sits inside `CorpUsers` on purpose, so disabled accounts stay in the sync scope and the disabled state reaches Entra.

## 4. UPN strategy and synchronization

The lab runs in two stages so the before and after can be compared.

| Stage | On-premises UPN | UPN seen in Entra | Notes |
|-------|-----------------|-------------------|-------|
| 1. Baseline | `user@rtworks.local` | `user@<initial-domain>` | `.local` is not routable and cannot be verified in Entra, so Entra builds the cloud UPN from the user's mail nickname and the tenant's **initial** domain (the `.onmicrosoft.com` name the tenant was created with). Confirmed in the lab tenant. |
| 2. Migrated | `user@<tenant>.onmicrosoft.com` | `user@<tenant>.onmicrosoft.com` | After 02 registers the suffix and 06 changes each UPN, the two match. |

Cloud Sync matches on a source anchor, not on the UPN, so the baseline syncs without problems. Only the sign-in name differs.

**Initial domain vs. migration target.** In the lab tenant these are two different domains. The initial domain cannot be renamed or removed, and setting another domain as the tenant's default does not change the fallback: synced users only take a new suffix once their on-premises UPN uses a verified domain. The migration target, `<tenant>.onmicrosoft.com`, must show as **Verified** under Entra > Domain names before 02 runs. The initial domain is not named anywhere in this repository and is redacted in the screenshots.

**Cloud Sync scope.** The agent syncs objects from `OU=CorpUsers` and its sub-OUs, including `OU=Disabled`. The rollout was piloted on `OU=IT` (12 users) before the scope was widened to `OU=CorpUsers` (100 users).

**Attribute mappings (confirmed in the lab tenant).** The Cloud Sync mapping page uses AD-style names, so `Title` and `PhysicalDeliveryOfficeName` appear there instead of Graph's `jobTitle` and `officeLocation`. All five attributes the scripts depend on are mapped with expressions, not direct copies:

| Target (Entra) | Expression | Used by |
|---|---|---|
| `UserPrincipalName` | `IIF(IsPresent([userPrincipalName]), [userPrincipalName], IIF(IsPresent([sAMAccountName]), Join("@", [sAMAccountName], %DomainFQDN%), Error("AccountName is not present")))` | 06 (UPN migration) |
| `DisplayName` | `IIF(IsPresent([displayName]), [displayName], [cn])` | 03, 05 |
| `Department` | `Trim([department])` | 03, 05 (movers) |
| `Title` | `Trim([title])` | 03, 05 |
| `PhysicalDeliveryOfficeName` | `Trim([physicalDeliveryOfficeName])` | 03, 05 |

What the expressions mean for the lab:

- **UPN:** the on-premises `userPrincipalName` is used whenever it is set; `sAMAccountName@<domain FQDN>` is only a fallback. Every lab user has a UPN, so the new suffix set by 06 is what reaches Entra (Entra then substitutes the initial domain if that suffix is not verified, as above).
- **Display name:** falls back to the object's `cn` if `displayName` is empty. 03 always sets `displayName`, so the fallback is not used.
- **Department, title, office:** leading and trailing spaces are trimmed on the way to Entra. `Import-LabUserCsv` already trims every CSV value before 03 or 05 writes it, so for script-managed accounts the AD and Entra values are identical. Only a value padded by hand in AD would differ between the two.

Values were also checked on a synced user in Entra (job title and office location populated). Evidence: `docs/images/attribute-mappings-1.png` and `attribute-mappings-2.png`.

## 5. Identity lifecycle (joiner, mover, leaver)

The CSV (`data/users.csv`) is the source of truth. The scripts compare the directory with it and fix the difference.

```mermaid
flowchart LR
    CSV["data/users.csv"] --> J["Joiner<br/>03-BulkImport-Users"]
    CSV --> M["Mover<br/>05-Update-ADUsers"]
    CSV --> L["Leaver<br/>05-Update-ADUsers<br/>-ProcessLeavers"]
    J --> D["OU=Department<br/>+ department group"]
    M --> D
    L --> X["Disabled account<br/>OU=Disabled<br/>no department groups"]
    D --> S["Cloud Sync"]
    X --> S
    S --> E["Entra user<br/>created / updated / blocked"]
```

| Event | Trigger | What happens |
|-------|---------|--------------|
| Joiner | New row in the CSV | 03 creates the user in the department OU with the initial password (change required at first logon) and adds it to the department group. |
| Mover | Department, title or office changed in the CSV | 05 moves the user to the new department OU, updates attributes, removes the old department group and adds the new one. |
| Leaver | Row removed from the CSV | With `-ProcessLeavers`, 05 disables the account, removes department groups, stamps the description, and moves it to `OU=Disabled`. Nothing is deleted. |
| Rehire | Leaver row returns to the CSV | 05 reports it as `Failed` and changes nothing. Re-enable and move the account by hand, then run 05. |

Safeguards: every script supports `-WhatIf`, validates all input before changing anything, and is safe to rerun. Leaver processing is opt-in and stops before any change if more than `-MaxLeavers` accounts would be processed.

## 6. Script map

| Script | Purpose |
|--------|---------|
| `01-Initialize-OUStructure.ps1` | Create `OU=CorpUsers` |
| `02-Configure-UPNSuffixes.ps1` | Register a UPN suffix in the forest |
| `03-BulkImport-Users.ps1` | Create department OUs, groups and users from the CSV |
| `04-Test-CloudSyncAgent.ps1` | Read-only health check of the sync agent |
| `05-Update-ADUsers.ps1` | Movers and leavers |
| `06-Set-UserUPN.ps1` | Move users to a new UPN suffix |
| `LabCommon.ps1` | Shared helpers, including CSV validation |

## 7. Validation

- **PSScriptAnalyzer** runs on `scripts/` in CI and fails on any finding.
- **Unit tests** (`tests/Data.Tests.ps1`, `tests/Scripts.Tests.ps1`) run in GitHub Actions without a domain controller. Active Directory is mocked, so they check which commands each script calls and with what, not the state of a real directory.
- **Integration tests** (`tests/IdentityLab.Integration.Tests.ps1`, tagged `Integration`) run on a domain controller and check the real OUs, groups and users. They also confirm that `05 -WhatIf` finds nothing to change.

Requirements and how each is verified are listed in `docs/REQUIREMENTS.md`.

## 8. Planned: Phase 3

GitHub Actions authenticates to Entra with an OIDC federated credential (no stored secret), deploys Conditional Access policies in report-only mode with break-glass accounts excluded, and Pester tests read the policy state back through Microsoft Graph.
