<#
.SYNOPSIS
    Creates the department OUs and security groups, then creates the users listed in the CSV.
.DESCRIPTION
    Before any change is made, the CSV is validated (columns, blanks, duplicates, department names,
    account-name length) and the environment is checked (root OU exists, every UPN suffix in the CSV
    is registered in the forest or is the domain's own name). If anything fails, nothing is changed.

    Each user is then handled on its own: a failure is recorded in the Detail column and the run
    continues. The script emits one result object per user and ends with a terminating error if any
    user failed, so a calling script or pipeline sees a non-zero exit code.

    Users are created with the UPN from the CSV and are required to change their password at first
    logon. This script does not move, rename, or update existing users; use 05-Update-ADUsers.ps1.
.PARAMETER CsvPath
    Path to the users CSV. Defaults to data\users.csv in the repository.
.PARAMETER RootTargetOU
    DN of the root OU. Defaults to OU=CorpUsers under the current domain.
.PARAMETER InitialPassword
    Initial password given to every newly created account, as a SecureString.
.PARAMETER Departments
    Department names to create OUs and groups for. Defaults to the lab's ten departments.
.EXAMPLE
    $pw = Read-Host -AsSecureString -Prompt 'Initial password'
    .\scripts\03-BulkImport-Users.ps1 -InitialPassword $pw -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $CsvPath = (Join-Path -Path (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'data') -ChildPath 'users.csv'),

    [string] $RootTargetOU,

    [Parameter(Mandatory = $true)]
    [securestring] $InitialPassword,

    [string[]] $Departments
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

$domain = Get-ADDomain
if ([string]::IsNullOrWhiteSpace($RootTargetOU)) {
    $RootTargetOU = "OU=CorpUsers,$($domain.DistinguishedName)"
}

# ---- Preflight: nothing is changed until all of this passes ---------------------------------
$users = @(Import-LabUserCsv -Path $CsvPath -AllowedDepartments $Departments)

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$RootTargetOU'")) {
    throw "Root OU not found: $RootTargetOU. Run 01-Initialize-OUStructure.ps1 first."
}

$forest = Get-ADForest
$validSuffixes = @(@($forest.UPNSuffixes) + @($domain.DNSRoot)) |
    Where-Object { $_ } |
    ForEach-Object { $_.ToLowerInvariant() }
$unregistered = @($users | Where-Object { $_.UserPrincipalName.Split('@')[-1].ToLowerInvariant() -notin $validSuffixes })
if ($unregistered.Count -gt 0) {
    $suffixes = ($unregistered | ForEach-Object { $_.UserPrincipalName.Split('@')[-1].ToLowerInvariant() } | Sort-Object -Unique) -join ', '
    throw "UPN suffix(es) not registered in the forest: $suffixes. Run 02-Configure-UPNSuffixes.ps1 first, or fix the CSV."
}

# ---- Department OUs and security groups -----------------------------------------------------
$groupDn = @{}
foreach ($department in $Departments) {
    $departmentOU = "OU=$department,$RootTargetOU"
    $groupName = "$department-Security-Group"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$departmentOU'")) {
        if ($PSCmdlet.ShouldProcess($departmentOU, 'Create department OU')) {
            New-ADOrganizationalUnit -Name $department -Path $RootTargetOU -ProtectedFromAccidentalDeletion $true
        }
    }

    $group = Get-ADGroup -Filter "Name -eq '$groupName'"
    if (-not $group) {
        if ($PSCmdlet.ShouldProcess($groupName, "Create security group in $departmentOU")) {
            $group = New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $departmentOU -PassThru
        }
    }
    if ($group) {
        $groupDn[$department] = @($group)[0].DistinguishedName
    }
}

# ---- Users ----------------------------------------------------------------------------------
$results = New-Object -TypeName System.Collections.Generic.List[object]
$failed = 0

foreach ($user in $users) {
    $result = [pscustomobject]@{
        SamAccountName = $user.SamAccountName
        Department     = $user.Department
        Action         = 'Pending'
        GroupAction    = 'None'
        Detail         = ''
    }

    try {
        $targetOU = "OU=$($user.Department),$RootTargetOU"
        $escapedSam = ConvertTo-LdapFilterValue -Value $user.SamAccountName
        $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$escapedSam)" -Properties MemberOf

        $userDn = $null
        $memberOf = @()

        if ($existing) {
            $existing = @($existing)[0]
            if (-not (Test-LabDnUnder -DistinguishedName $existing.DistinguishedName -ContainerDN $RootTargetOU)) {
                throw "An account named '$($user.SamAccountName)' already exists outside the lab OU ($($existing.DistinguishedName)). It was not touched."
            }
            $userDn = $existing.DistinguishedName
            $memberOf = @($existing.MemberOf)
            $result.Action = 'AlreadyExisted'
        }
        elseif ($PSCmdlet.ShouldProcess($user.SamAccountName, "Create user in $targetOU")) {
            $newUserParameters = @{
                Name                  = $user.DisplayName
                GivenName             = $user.GivenName
                Surname               = $user.Surname
                DisplayName           = $user.DisplayName
                SamAccountName        = $user.SamAccountName
                UserPrincipalName     = $user.UserPrincipalName
                Path                  = $targetOU
                Department            = $user.Department
                AccountPassword       = $InitialPassword
                ChangePasswordAtLogon = $true
                Enabled               = $true
                PassThru              = $true
            }
            if ($user.Title) { $newUserParameters['Title'] = $user.Title }
            if ($user.Office) { $newUserParameters['Office'] = $user.Office }

            $newUser = New-ADUser @newUserParameters
            $userDn = @($newUser)[0].DistinguishedName
            $result.Action = 'Created'
        }
        elseif ($WhatIfPreference) {
            $result.Action = 'WouldCreate'
        }
        else {
            $result.Action = 'Skipped'
        }

        $targetGroupDn = $groupDn[$user.Department]
        if ($userDn) {
            if (-not $targetGroupDn) {
                throw "Security group '$($user.Department)-Security-Group' was not found."
            }
            if ($memberOf -contains $targetGroupDn) {
                $result.GroupAction = 'AlreadyMember'
            }
            elseif ($PSCmdlet.ShouldProcess($user.SamAccountName, "Add to $targetGroupDn")) {
                Add-ADGroupMember -Identity $targetGroupDn -Members $userDn
                $result.GroupAction = 'Added'
            }
            elseif ($WhatIfPreference) {
                $result.GroupAction = 'WouldAdd'
            }
        }
        elseif ($WhatIfPreference) {
            $result.GroupAction = 'WouldAdd'
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

$createdCount = @($results | Where-Object { $_.Action -eq 'Created' }).Count
$existedCount = @($results | Where-Object { $_.Action -eq 'AlreadyExisted' }).Count
Write-Information -MessageData "Users: $($users.Count) in CSV, $createdCount created, $existedCount already existed, $failed failed." -InformationAction Continue

if ($failed -gt 0) {
    throw "$failed of $($users.Count) user(s) failed. See the Detail column of the results."
}
