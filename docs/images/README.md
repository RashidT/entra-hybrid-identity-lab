# Screenshots and evidence

This folder holds the sanitized screenshots and exported results that back up the lab write-up. Only sanitized files belong here.

## Rules

1. **Originals never enter the repo.** Keep unredacted captures in a folder outside the repo (this lab uses `C:\LabEvidence\raw`). `docs/images/raw/` is listed in `.gitignore` only as a backstop.
2. **Git history is permanent.** If an unredacted image is ever committed, deleting it later does not remove it. Rewrite the history and treat the exposed IDs as burned (for a lab tenant, creating a fresh one is the clean fix).
3. Name files so the stage is obvious: `01-baseline-onprem-upn.png`, `02-baseline-cloud-upn.png`, `03-after-onprem-upn.png`, `04-after-cloud-upn.png`.

## Sanitizing checklist

Capture
- [ ] Use a fresh browser profile or private window (no other tabs, bookmarks, profile photo or signed-in email).
- [ ] Crop to the panel you are documenting. Leave out the URL bar and the account menu.
- [ ] Use test users in every frame you control.

Redact (solid, opaque boxes; never blur or pixelate)
- [ ] Your real email address and any real admin or owner account names
- [ ] Tenant ID, directory ID, subscription IDs, and any other GUID that identifies the tenant
- [ ] Public IP addresses
- [ ] The agent server's hostname, if it identifies you
- [ ] A tenant name or domain that contains your name or anything personal
- [ ] Notification, recovery or alternate email fields
- [ ] GUIDs in URLs, if the URL is visible

Finish
- [ ] Redact in an editor that saves a flat image (Paint is fine). If you used layers, export a flattened PNG and delete the project file.
- [ ] Strip metadata: re-save through Paint, or run `exiftool -all= <file>`.
- [ ] Zoom to 200% and read the image as a stranger would.
- [ ] Check that the file name and any caption contain nothing sensitive.
- [ ] Only then copy it into this folder and commit it.

## Evidence to capture

| File | What it shows | Requirement |
|------|---------------|-------------|
| `01-baseline-onprem-upn.png` | A few users with `@rtworks.local` UPNs in AD | R-31 |
| `scoping-filter-pilot.png` | The Cloud Sync scoping filter during the pilot (`OU=IT` only) | R-31 (supporting) |
| `pilot-synced-users.png` | The pilot's IT users in Entra, marked as synced from on-premises | R-31 (supporting) |
| `02-baseline-cloud-upn.png` | The same users in Entra, with the cloud UPN suffix | R-31 |
| `scoping-filter.png` | The Cloud Sync scoping filter (selected OUs) | R-31 |
| `attribute-mappings-1.png`, `attribute-mappings-2.png` | The Cloud Sync attribute mappings (two parts) | `docs/architecture.md` section 4 |
| `agent-health.png` | Output of `04-Test-CloudSyncAgent.ps1` | R-13 |
| `03-after-onprem-upn.png` | The same users after script 06 | R-32 |
| `04-after-cloud-upn.png` | The cloud UPN now matching | R-32 |
| `leaver-before-after.png` | A leaver account before and after `05 -ProcessLeavers`, plus its blocked state in Entra | R-16 |
| `leaver-group-audit.png` | Entra audit log: the leaver removed from its department group | R-16 (supporting) |
| `leaver-provisioning-log.png` | Cloud Sync provisioning log: the update from AD, with `accountEnabled` set to false | R-16 (supporting) |
| `breakglass-role-audit.png` | Entra audit log (Core Directory, RoleManagement): both `Add member to role` entries with initiator and targets, plus each entry's Modified Properties showing Global Administrator (`TenantAdmins`). Evidence for the bootstrap exception | R-62, P-03 |
| `breakglass-assigned-roles.png` | Each emergency access account's **Assigned roles**, viewed as the Privileged Role Administrator, in two stacked captures (BG-Admin01, then BG-Admin02): Global Administrator, resource Directory (Organization), assignment path **Direct**, Built-in. The signed-in account's domain and tenant name are redacted. The Free view has no assignment type or end time; active and permanent is shown by the Graph eligibility check in P-03 (`AadPremiumLicenseRequired`) | R-62, P-03 |
| `breakglass-passkeys.png` | Each emergency access account's **Security info** in My Sign-Ins, signed in as that account, in two stacked captures (BG-Admin01, then BG-Admin02): Password plus one **Passkey (Device bound), Windows Hello**, and no other method. UPN domains and passkey device names redacted. Evidence for strong authentication on separate devices, replacing the phone-based methods first registered (see P-03) | P-03, R-62 |
| `admin-roles-audit.png` | Entra audit log (Core Directory, RoleManagement), filtered to Initiated by the Privileged Role Administrator and viewed as the Reports Reader account. Two stacked captures: 7 `Add member to role` entries (one role per `adm-` account, plus the mistaken add to the lab user `marcus.lee`) and 5 `Remove member from role` entries (the first roles from `maya.patel` and `elena.brooks`, Conditional Access Administrator from `marcus.lee`, and Global Administrator and Billing Administrator from the setup Global Administrator). Evidence for the role hand-off, the second deviation and the retirement | R-62 |
| `creator-ga-removal-audit.png` | Entra audit log, viewed as the Reports Reader account: `Remove member from role`, Global Administrator, from the tenant creator, initiated by the Privileged Role Administrator (2026-10-24). Evidence that only the emergency access accounts are standing Global Administrators | R-63 |
| `creator-roles-after.png` | The tenant creator's **Assigned roles**: Billing Administrator only | R-63 |
| `admin-roles.png` | **Roles & admins > All roles**, viewed as the Privileged Role Administrator: Global Administrator 2 holders, every other role in the R-62 table 1. Directory Readers 1 is the Microsoft service principal `Microsoft.Azure.SyncFabric` (see R-62) | R-62 |
| `per-user-mfa-enforced.png` | **Per-user multifactor authentication**, viewed as the Authentication Policy Administrator: all eleven admin and emergency access accounts **enforced**, in four stacked searches: the seven `adm-` accounts, the two emergency access accounts, the tenant creator and the setup Global Administrator (the last two labelled, names redacted) | R-65 |
| `cloudsync-phs.png` | The `rtworks.local` Cloud Sync configuration **Overview**, viewed as the Hybrid Identity Administrator: Configuration status **Healthy**, Password hash sync **Enabled**. The signed-in account's domain and tenant name are redacted. Why per-user MFA also covers the 100 synced users | R-65 |
| `setup-ga-retired.png` | The setup Global Administrator, viewed as the Privileged Role Administrator: **Assigned roles** showing "No directory roles assigned", then its properties showing **Account enabled: No**. Evidence that it was retired (roles removed, sign-in blocked, not deleted) | R-62 |
| `external-collab-settings.png` | **External Identities > External collaboration settings**, viewed as the Privileged Role Administrator after the change: Guest user access **restricted to properties and memberships of their own directory objects**, and Guest invite settings **Only users assigned to specific admin roles can invite guest users**. Save is greyed out: the portal page was read-only for every non-GA role tested, so the change was made through Microsoft Graph (see R-69). Account domain and tenant name redacted | R-69 |

The `06-Set-UserUPN.ps1 -LogPath` CSV and the output of `05-Update-ADUsers.ps1` are text, so they can be committed as files. Check them for real names or addresses first.
