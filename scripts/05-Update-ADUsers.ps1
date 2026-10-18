<#
.SYNOPSIS
    Brings existing lab users in line with the CSV: department OU, attributes, and group membership.
.DESCRIPTION
    For every user in the CSV, the script looks the account up inside the root OU only (accounts
    elsewhere in the domain are never touched) and compares three things independently:
      - the OU the account is actually in, against the OU for the CSV department
      - the Department, Title, Office, GivenName, Surname and DisplayName attributes
      - department group membership: the user must be in the CSV department's group and in none
        of the other department groups
    Only what differs is changed, so a run that finds nothing to do changes nothing, and a run that
    was interrupted part-way repairs the rest on the next run. Blank Title or Office values in the
    CSV are not treated as instructions to clear the attribute.

    Leavers: an account under the root OU that is not in the CSV is a leaver. By default it is only
    reported (Action NotInCsv) and not changed. With -ProcessLeavers the script deprovisions it:
      1. disables the account (access stops first)
      2. removes it from the department security groups
      3. stamps the Description with the leaver date
      4. moves it to the Disabled OU under the root OU (done last, so an interrupted run is retried)
    Nothing is deleted. The Disabled OU stays inside the root OU, so the disabled account stays in
    the Cloud Sync scope and the disable reaches Entra. A leaver that is already fully processed is
    reported as AlreadyLeaver. As a safeguard against a wrong or truncated CSV, the script stops
    before any change if more than -MaxLeavers accounts would be processed.

    A CSV user that is sitting in the Disabled OU (a rehire) is reported as Failed and not changed:
    re-enable the account by hand first, then run the script.

    Users in the CSV that cannot be found under the root OU are reported as NotFound.

    The script emits one result object per account (Action, Changes, Detail) and ends with a
    terminating error if any account failed or was not found.
.PARAMETER CsvPath
    Path to the users CSV. Defaults to data\users.csv in the repository.
.PARAMETER RootTargetOU
    DN of the root OU. Defaults to OU=CorpUsers under the current domain.
.PARAMETER Departments
    Department names that have OUs and groups. Defaults to the lab's ten departments.
.PARAMETER ProcessLeavers
    Deprovision accounts that are not in the CSV (see the description). Off by default.
.PARAMETER DisabledOUName
    Name of the OU, directly under the root OU, that leavers are moved to. Default: Disabled.
.PARAMETER MaxLeavers
    Safeguard: stop before any change if more than this many leavers would be processed. Default: 10.
.EXAMPLE
    .\scripts\05-Update-ADUsers.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $CsvPath = (Join-Path -Path (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'data') -ChildPath 'users.csv'),

    [string] $RootTargetOU,

    [string[]] $Departments,

    [switch] $ProcessLeavers,

    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string] $DisabledOUName = 'Disabled',

    [ValidateRange(1, 1000)]
    [int] $MaxLeavers = 10
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'LabCommon.ps1')
Import-LabActiveDirectoryModule

if (-not $PSBoundParameters.ContainsKey('Departments')) {
    $Departments = Get-LabDepartmentList
}
foreach ($department in $Departments) {
    if ($department -notmatch '^[A-Za-z0-9 _-]+$') {
        throw "Department name '$department' may only contain letters, digits, spaces, '_' and '-'."
    }
}

if ([string]::IsNullOrWhiteSpace($RootTargetOU)) {
    $RootTargetOU = "OU=CorpUsers,$((Get-ADDomain).DistinguishedName)"
}

$disabledOU = "OU=$DisabledOUName,$RootTargetOU"

# ---- Preflight: nothing is changed until all of this passes ---------------------------------
$users = @(Import-LabUserCsv -Path $CsvPath -AllowedDepartments $Departments)

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$RootTargetOU'")) {
    throw "Root OU not found: $RootTargetOU."
}

$groupDn = @{}
foreach ($department in $Departments) {
    $group = Get-ADGroup -Filter "Name -eq '$department-Security-Group'"
    if ($group) {
        $groupDn[$department] = @($group)[0].DistinguishedName
    }
}

$neededDepartments = @($users | ForEach-Object { $_.Department } | Sort-Object -Unique)
foreach ($department in $neededDepartments) {
    if (-not $groupDn.ContainsKey($department)) {
        throw "Security group '$department-Security-Group' was not found. Run 03-BulkImport-Users.ps1 first."
    }
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq 'OU=$department,$RootTargetOU'")) {
        throw "Department OU 'OU=$department,$RootTargetOU' was not found. Run 03-BulkImport-Users.ps1 first."
    }
}

# Accounts under the root OU that are not in the CSV, and what state each is in.
$csvAccounts = @($users | ForEach-Object { $_.SamAccountName })
$departmentGroupDns = @($groupDn.Values)
$orphans = New-Object -TypeName System.Collections.Generic.List[object]
foreach ($adAccount in @(Get-ADUser -Filter * -SearchBase $RootTargetOU -SearchScope Subtree -Properties Enabled, MemberOf, Description)) {
    if ($csvAccounts -contains $adAccount.SamAccountName) { continue }
    $inDisabledOU = Test-LabDnUnder -DistinguishedName $adAccount.DistinguishedName -ContainerDN $disabledOU
    $isEnabled = $adAccount.Enabled -ne $false
    $groupsToRemove = @(@($adAccount.MemberOf) | Where-Object { $departmentGroupDns -contains $_ })
    $orphans.Add([pscustomobject]@{
            Account        = $adAccount
            InDisabledOU   = $inDisabledOU
            IsEnabled      = $isEnabled
            GroupsToRemove = $groupsToRemove
            IsDone         = ($inDisabledOU -and -not $isEnabled -and $groupsToRemove.Count -eq 0)
        })
}

if ($ProcessLeavers) {
    $pendingLeavers = @($orphans | Where-Object { -not $_.IsDone })
    if ($pendingLeavers.Count -gt $MaxLeavers) {
        throw "$($pendingLeavers.Count) leavers would be processed, which is more than -MaxLeavers ($MaxLeavers). Nothing was changed. Check that the CSV is complete, or raise -MaxLeavers."
    }
}

# ---- Users ----------------------------------------------------------------------------------
$attributeNames = @('Department', 'Title', 'Office', 'GivenName', 'Surname', 'DisplayName')
$properties = $attributeNames + @('MemberOf')
$results = New-Object -TypeName System.Collections.Generic.List[object]
$failed = 0

foreach ($user in $users) {
    $result = [pscustomobject]@{
        SamAccountName = $user.SamAccountName
        Action         = 'Pending'
        Changes        = ''
        Detail         = ''
    }

    try {
        $escapedSam = ConvertTo-LdapFilterValue -Value $user.SamAccountName
        $adUser = Get-ADUser -LDAPFilter "(sAMAccountName=$escapedSam)" -SearchBase $RootTargetOU -SearchScope Subtree -Properties $properties

        if (-not $adUser) {
            $result.Action = 'NotFound'
            $result.Detail = "No account '$($user.SamAccountName)' under $RootTargetOU."
            $failed++
        }
        else {
            $adUser = @($adUser)[0]
            if (Test-LabDnUnder -DistinguishedName $adUser.DistinguishedName -ContainerDN $disabledOU) {
                throw "Account is in the Disabled OU ($disabledOU) but is in the CSV. Re-enable it by hand and move it out first. Not changed."
            }
            $changes = New-Object -TypeName System.Collections.Generic.List[string]

            # 1. OU placement
            $expectedOU = "OU=$($user.Department),$RootTargetOU"
            $currentOU = Get-LabParentDN -DistinguishedName $adUser.DistinguishedName
            $needsMove = $currentOU -ine $expectedOU
            if ($needsMove) {
                $changes.Add("OU: '$currentOU' -> '$expectedOU'")
            }

            # 2. Attributes
            $setParameters = @{}
            foreach ($name in $attributeNames) {
                $wanted = [string]$user.$name
                $current = [string]$adUser.$name
                if ([string]::IsNullOrEmpty($wanted)) { continue }
                if ($wanted -cne $current) {
                    $setParameters[$name] = $wanted
                    $changes.Add("${name}: '$current' -> '$wanted'")
                }
            }

            # 3. Department group membership
            $targetGroupDn = $groupDn[$user.Department]
            $memberOf = @($adUser.MemberOf)
            $needsAdd = $memberOf -notcontains $targetGroupDn
            $groupsToRemove = @($memberOf | Where-Object { ($groupDn.Values -contains $_) -and ($_ -ne $targetGroupDn) })
            if ($needsAdd) {
                $changes.Add("Group: add $targetGroupDn")
            }
            foreach ($groupToRemove in $groupsToRemove) {
                $changes.Add("Group: remove $groupToRemove")
            }

            $result.Changes = $changes -join '; '

            if ($changes.Count -eq 0) {
                $result.Action = 'NoChange'
            }
            elseif ($PSCmdlet.ShouldProcess($user.SamAccountName, $result.Changes)) {
                $identity = "$($adUser.ObjectGUID)"
                # The Department attribute is set last, so an interrupted run is still detectable.
                if ($needsMove) {
                    Move-ADObject -Identity $identity -TargetPath $expectedOU
                }
                foreach ($groupToRemove in $groupsToRemove) {
                    Remove-ADGroupMember -Identity $groupToRemove -Members $identity -Confirm:$false
                }
                if ($needsAdd) {
                    Add-ADGroupMember -Identity $targetGroupDn -Members $identity
                }
                if ($setParameters.Count -gt 0) {
                    Set-ADUser -Identity $identity @setParameters
                }
                $result.Action = 'Updated'
            }
            elseif ($WhatIfPreference) {
                $result.Action = 'WouldUpdate'
            }
            else {
                $result.Action = 'Skipped'
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

# ---- Leavers: accounts under the root OU that are not in the CSV -----------------------------
$leaverNote = "Leaver $(Get-Date -Format 'yyyy-MM-dd') (05-Update-ADUsers.ps1)"
$disabledOuChecked = $false

foreach ($orphan in $orphans) {
    $adAccount = $orphan.Account
    $result = [pscustomobject]@{
        SamAccountName = $adAccount.SamAccountName
        Action         = 'Pending'
        Changes        = ''
        Detail         = ''
    }

    if ($orphan.IsDone) {
        $result.Action = 'AlreadyLeaver'
    }
    elseif (-not $ProcessLeavers) {
        $result.Action = 'NotInCsv'
        $result.Detail = "Account is under $RootTargetOU but is not in the CSV. Not changed (use -ProcessLeavers to deprovision)."
    }
    else {
        try {
            $changes = New-Object -TypeName System.Collections.Generic.List[string]
            if ($orphan.IsEnabled) { $changes.Add('Disable account') }
            foreach ($groupToRemove in $orphan.GroupsToRemove) { $changes.Add("Group: remove $groupToRemove") }
            if ("$($adAccount.Description)" -notlike 'Leaver *') { $changes.Add("Description: '$leaverNote'") }
            if (-not $orphan.InDisabledOU) { $changes.Add("OU: -> '$disabledOU'") }
            $result.Changes = $changes -join '; '

            if ($PSCmdlet.ShouldProcess($adAccount.SamAccountName, "Leaver: $($result.Changes)")) {
                if (-not $disabledOuChecked) {
                    $disabledOuChecked = $true
                    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$disabledOU'")) {
                        New-ADOrganizationalUnit -Name $DisabledOUName -Path $RootTargetOU -ProtectedFromAccidentalDeletion $true
                    }
                }
                $identity = "$($adAccount.ObjectGUID)"
                if ($orphan.IsEnabled) {
                    Disable-ADAccount -Identity $identity
                }
                foreach ($groupToRemove in $orphan.GroupsToRemove) {
                    Remove-ADGroupMember -Identity $groupToRemove -Members $identity -Confirm:$false
                }
                if ("$($adAccount.Description)" -notlike 'Leaver *') {
                    Set-ADUser -Identity $identity -Description $leaverNote
                }
                if (-not $orphan.InDisabledOU) {
                    Move-ADObject -Identity $identity -TargetPath $disabledOU
                }
                $result.Action = 'LeaverProcessed'
            }
            elseif ($WhatIfPreference) {
                $result.Action = 'WouldProcessLeaver'
            }
            else {
                $result.Action = 'Skipped'
            }
        }
        catch {
            $result.Action = 'Failed'
            $result.Detail = $_.Exception.Message
            $failed++
        }
    }

    $results.Add($result)
    $result
}

$updatedCount = @($results | Where-Object { $_.Action -eq 'Updated' }).Count
$unchangedCount = @($results | Where-Object { $_.Action -eq 'NoChange' }).Count
$notInCsvCount = @($results | Where-Object { $_.Action -eq 'NotInCsv' }).Count
$leaverCount = @($results | Where-Object { $_.Action -eq 'LeaverProcessed' }).Count
Write-Information -MessageData "Users: $($users.Count) in CSV, $updatedCount updated, $unchangedCount unchanged. Leavers: $leaverCount processed, $notInCsvCount reported only. $failed failed or not found." -InformationAction Continue

if ($failed -gt 0) {
    throw "$failed account(s) failed or were not found. See the Action and Detail columns."
}
