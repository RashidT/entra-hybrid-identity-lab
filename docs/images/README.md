# Screenshots and evidence

This folder holds the sanitized screenshots and exported results that back up the lab write-up. Only sanitized files belong here.

## Rules

1. **Originals never enter the repo.** Keep unredacted captures in `docs/images/raw/`, which is listed in `.gitignore`, or better, in a folder outside the repo.
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
| `02-baseline-cloud-upn.png` | The same users in Entra, with the cloud UPN suffix | R-31 |
| `scoping-filter.png` | The Cloud Sync scoping filter (selected OUs) | R-31 |
| `attribute-mappings.png` | The Cloud Sync attribute mappings | `docs/architecture.md` section 4 |
| `agent-health.png` | Output of `04-Test-CloudSyncAgent.ps1` | R-13 |
| `03-after-onprem-upn.png` | The same users after script 06 | R-32 |
| `04-after-cloud-upn.png` | The cloud UPN now matching | R-32 |
| `leaver-before-after.png` | A leaver account before and after `05 -ProcessLeavers`, plus its blocked state in Entra | R-16 |

The `06-Set-UserUPN.ps1 -LogPath` CSV and the output of `05-Update-ADUsers.ps1` are text, so they can be committed as files. Check them for real names or addresses first.
