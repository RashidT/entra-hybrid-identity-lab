<#
.SYNOPSIS
    Deploys the LAB- Conditional Access policies in policies/*.json, in report-only mode only.
.DESCRIPTION
    R-57: idempotent and non-destructive.
      1. Every file in -PolicyPath is checked (R-52) and its placeholders filled (R-58) before any
         Graph call. If any file fails, the script stops and nothing is changed.
      2. The tenant's Conditional Access policies are listed once (read-only).
      3. Each definition is matched to a tenant policy by displayName:
           none    -> created (POST)
           one     -> compared with the shared R-53 rule; the top-level keys that differ are sent
                      whole in one PATCH (Option A); no difference means NoChange
           several -> Failed, and nothing is changed for that policy
      4. Every create and update is read back and compared again; it only counts as done if the
         read-back matches.
    Nothing is ever deleted. A tenant LAB- policy with no definition is reported as NotInRepo and
    left alone. One failing policy does not stop the others; the script ends with a terminating
    error if any policy failed.

    Object IDs are never written to the output (R-58): results name policies by displayName only.

    Needs PowerShell 7 and an existing Microsoft Graph connection (Connect-MgGraph) with
    Policy.Read.All and Policy.ReadWrite.ConditionalAccess.
.PARAMETER EmergencyAccessGroupId
    Object ID of the EmergencyAccess group. Fills {{EmergencyAccessGroupId}}.
.PARAMETER ItSecurityGroupId
    Object ID of the synced IT-Security-Group. Fills {{ItSecurityGroupId}}.
.PARAMETER PolicyPath
    Folder holding the LAB-*.json definitions. Defaults to policies\ in the repository.
.PARAMETER ReadBackAttempts
    How many times a create or update is read back before it is reported as Failed.
.PARAMETER ReadBackDelaySeconds
    Seconds to wait between read-back attempts.
.EXAMPLE
    Connect-MgGraph -Scopes 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess' -NoWelcome
    (Get-MgContext).Account
    .\scripts\07-Deploy-ConditionalAccessPolicies.ps1 -EmergencyAccessGroupId $ea -ItSecurityGroupId $it -WhatIf
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $EmergencyAccessGroupId,

    [Parameter(Mandatory = $true)]
    [string] $ItSecurityGroupId,

    [string] $PolicyPath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'policies'),

    [ValidateRange(1, 10)]
    [int] $ReadBackAttempts = 3,

    [ValidateRange(0, 60)]
    [int] $ReadBackDelaySeconds = 5
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'ConditionalAccessCommon.ps1')

$policiesUri = 'v1.0/identity/conditionalAccess/policies'

function Get-LabPolicyReadBackDifference {
    <#
    .SYNOPSIS
        Reads one policy back by ID and returns the top-level keys that still differ.
        Retries, because a change may take a moment to show.
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Definition,
        [Parameter(Mandatory = $true)] [string] $PolicyId,
        [Parameter(Mandatory = $true)] [int] $Attempts,
        [Parameter(Mandatory = $true)] [int] $DelaySeconds
    )

    $lastError = ''
    $difference = @()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds $DelaySeconds }
        try {
            $actual = Invoke-MgGraphRequest -Method GET -Uri "$policiesUri/$PolicyId" -OutputType HashTable
            $difference = @(Get-LabPolicyDifference -Definition $Definition -Actual $actual)
            $lastError = ''
            if ($difference.Count -eq 0) { return [string[]]@() }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }
    if ($lastError) { throw "Read-back failed after $Attempts attempt(s): $lastError" }
    return [string[]]$difference
}

# ---- Preflight: every file is checked before any Graph call ---------------------------------
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Container)) {
    throw "Policy folder not found: $PolicyPath"
}
$files = @(Get-ChildItem -LiteralPath $PolicyPath -Filter 'LAB-*.json' -File | Sort-Object -Property Name)
if ($files.Count -eq 0) {
    throw "No LAB-*.json policy definitions found in $PolicyPath."
}

$placeholderValues = @{
    EmergencyAccessGroupId = $EmergencyAccessGroupId
    ItSecurityGroupId      = $ItSecurityGroupId
}

$problems = New-Object -TypeName System.Collections.Generic.List[string]
$definitions = New-Object -TypeName System.Collections.Generic.List[object]

foreach ($file in $files) {
    try {
        $raw = Read-LabPolicyDefinition -Path $file.FullName
        $found = @(Test-LabPolicyDefinition -Definition $raw -Name $file.Name)
        if ($found.Count -gt 0) {
            foreach ($problem in $found) { $problems.Add($problem) }
            continue
        }
        $resolved = Resolve-LabPolicyPlaceholder -Definition $raw -Value $placeholderValues
        foreach ($problem in @(Test-LabPolicyDefinition -Definition $resolved -Name $file.Name -EmergencyAccessGroupId $EmergencyAccessGroupId)) {
            $problems.Add($problem)
        }
        $definitions.Add([pscustomobject]@{
                File        = $file.Name
                DisplayName = [string]$resolved['displayName']
                Definition  = $resolved
            })
    }
    catch {
        # Placeholder errors never contain the values, so this message is safe to print.
        $problems.Add("$($file.Name): $($_.Exception.Message)")
    }
}

$duplicateNames = @($definitions | Group-Object -Property DisplayName | Where-Object { $_.Count -gt 1 })
foreach ($group in $duplicateNames) {
    $problems.Add("displayName '$($group.Name)' is used by more than one file: $(($group.Group.File) -join ', ').")
}

if ($problems.Count -gt 0) {
    throw "Policy definitions failed the checks; nothing was changed.`n$($problems -join "`n")"
}

# ---- Graph connection -----------------------------------------------------------------------
$context = $null
if (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue) { $context = Get-MgContext }
if (-not $context) {
    throw 'Not connected to Microsoft Graph. Run Connect-MgGraph first; nothing was changed.'
}
if ($context.Account) {
    Write-Information -MessageData "Graph account: $($context.Account)" -InformationAction Continue
}
else {
    Write-Information -MessageData 'Graph account: app-only (workload identity)' -InformationAction Continue
}

# ---- Tenant policies (read-only, every page) -----------------------------------------------
$tenantPolicies = New-Object -TypeName System.Collections.Generic.List[object]
$uri = $policiesUri
while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType HashTable
    foreach ($policy in @($page['value'])) {
        if ($null -ne $policy) { $tenantPolicies.Add($policy) }
    }
    $uri = $page['@odata.nextLink']
}

# ---- Policies -------------------------------------------------------------------------------
$results = New-Object -TypeName System.Collections.Generic.List[object]
$failed = 0

foreach ($item in $definitions) {
    $result = [pscustomobject]@{
        Policy      = $item.DisplayName
        File        = $item.File
        Action      = 'Pending'
        ChangedKeys = ''
        Detail      = ''
    }

    try {
        $matched = @($tenantPolicies | Where-Object { [string]$_['displayName'] -eq $item.DisplayName })

        if ($matched.Count -gt 1) {
            $result.Action = 'Failed'
            $result.Detail = "$($matched.Count) tenant policies are named '$($item.DisplayName)'. Nothing was changed for it; remove or rename the extra ones."
            $failed++
        }
        elseif ($matched.Count -eq 0) {
            $result.ChangedKeys = ($item.Definition.Keys -join ', ')
            if ($PSCmdlet.ShouldProcess($item.DisplayName, 'Create Conditional Access policy (report-only)')) {
                $body = $item.Definition | ConvertTo-Json -Depth 20
                $created = Invoke-MgGraphRequest -Method POST -Uri $policiesUri -Body $body -ContentType 'application/json' -OutputType HashTable
                if (-not $created -or [string]::IsNullOrWhiteSpace([string]$created['id'])) {
                    throw 'Graph did not return the new policy ID.'
                }
                $left = @(Get-LabPolicyReadBackDifference -Definition $item.Definition -PolicyId $created['id'] -Attempts $ReadBackAttempts -DelaySeconds $ReadBackDelaySeconds)
                if ($left.Count -gt 0) {
                    $result.Action = 'Failed'
                    $result.Detail = "Created, but the read-back still differs in: $($left -join ', ')."
                    $failed++
                }
                else {
                    $result.Action = 'Created'
                }
            }
            elseif ($WhatIfPreference) {
                $result.Action = 'WouldCreate'
            }
            else {
                $result.Action = 'Skipped'
            }
        }
        else {
            $tenantPolicy = $matched[0]
            $changed = @(Get-LabPolicyDifference -Definition $item.Definition -Actual $tenantPolicy)
            if ($changed.Count -eq 0) {
                $result.Action = 'NoChange'
            }
            else {
                $result.ChangedKeys = ($changed -join ', ')
                if ($PSCmdlet.ShouldProcess($item.DisplayName, "Update Conditional Access policy: $($result.ChangedKeys)")) {
                    $patch = Get-LabPolicyPatchBody -Definition $item.Definition -ChangedKey $changed
                    $body = $patch | ConvertTo-Json -Depth 20
                    Invoke-MgGraphRequest -Method PATCH -Uri "$policiesUri/$($tenantPolicy['id'])" -Body $body -ContentType 'application/json' | Out-Null
                    $left = @(Get-LabPolicyReadBackDifference -Definition $item.Definition -PolicyId $tenantPolicy['id'] -Attempts $ReadBackAttempts -DelaySeconds $ReadBackDelaySeconds)
                    if ($left.Count -gt 0) {
                        $result.Action = 'Failed'
                        $result.Detail = "Updated, but the read-back still differs in: $($left -join ', ')."
                        $failed++
                    }
                    else {
                        $result.Action = 'Updated'
                    }
                }
                elseif ($WhatIfPreference) {
                    $result.Action = 'WouldUpdate'
                }
                else {
                    $result.Action = 'Skipped'
                }
            }
        }
    }
    catch {
        $result.Action = 'Failed'
        $result.Detail = $_.Exception.Message
        $failed++
    }

    $results.Add($result)
    $result
}

# ---- Tenant LAB- policies with no definition: reported, never changed -----------------------
$repoNames = @($definitions | ForEach-Object { $_.DisplayName })
$notInRepo = @($tenantPolicies | Where-Object {
        $name = [string]$_['displayName']
        $name.StartsWith('LAB-', [System.StringComparison]::OrdinalIgnoreCase) -and ($repoNames -notcontains $name)
    } | ForEach-Object { [string]$_['displayName'] } | Sort-Object -Unique)
foreach ($name in $notInRepo) {
    $extra = [pscustomobject]@{
        Policy      = $name
        File        = ''
        Action      = 'NotInRepo'
        ChangedKeys = ''
        Detail      = 'Tenant LAB- policy with no definition in the repo. Left unchanged (nothing is deleted).'
    }
    $results.Add($extra)
    $extra
}

# ---- Summary --------------------------------------------------------------------------------
$count = @{}
foreach ($action in 'Created', 'Updated', 'WouldCreate', 'WouldUpdate', 'NoChange') {
    $count[$action] = @($results | Where-Object { $_.Action -eq $action }).Count
}
if ($WhatIfPreference) {
    $changeText = "$($count.WouldCreate) would create, $($count.WouldUpdate) would update (WhatIf)"
}
else {
    $changeText = "$($count.Created) created, $($count.Updated) updated"
}
Write-Information -MessageData "Policies: $($definitions.Count) in repo, $changeText, $($count.NoChange) unchanged, $failed failed, $($notInRepo.Count) LAB- in tenant not in repo." -InformationAction Continue

if ($failed -gt 0) {
    throw "$failed of $($definitions.Count) policy(ies) failed. See the Action and Detail columns."
}
