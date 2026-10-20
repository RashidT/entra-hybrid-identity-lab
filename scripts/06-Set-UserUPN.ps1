<#
.SYNOPSIS
    Moves the lab users to a new UPN suffix (for example the tenant's onmicrosoft.com domain).
.DESCRIPTION
    This is the "migrate" step of the lab: users are first created on the domain's own suffix
    (@rtworks.local), synced, and baselined; after the new suffix is registered with
    02-Configure-UPNSuffixes.ps1, this script changes each user's UPN to <SamAccountName>@<suffix>.

    The new suffix must already be registered in the forest, or the script stops before any change.
    Each user's before and after UPN is reported. A run where every user already has the new UPN
    changes nothing. Users are looked up inside the root OU only.

    The script ends with a terminating error if any user failed or was not found.
.PARAMETER NewSuffix
    The suffix to move users to, without an @ sign, for example contoso.onmicrosoft.com.
.PARAMETER CsvPath
    Path to the users CSV. Defaults to data\users.csv in the repository.
.PARAMETER RootTargetOU
    DN of the root OU. Defaults to OU=CorpUsers under the current domain.
.PARAMETER LogPath
    Optional path of a CSV file to write the per-user results to (evidence for the lab write-up).
.EXAMPLE
    .\scripts\06-Set-UserUPN.ps1 -NewSuffix 'contoso.onmicrosoft.com' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?!-)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')]
    [string] $NewSuffix,

    [string] $CsvPath = (Join-Path -Path (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'data') -ChildPath 'users.csv'),

    [string] $RootTargetOU,

    [string] $LogPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'LabCommon.ps1')
Import-LabActiveDirectoryModule

$suffix = $NewSuffix.Trim().ToLowerInvariant()
$domain = Get-ADDomain
if ([string]::IsNullOrWhiteSpace($RootTargetOU)) {
    $RootTargetOU = "OU=CorpUsers,$($domain.DistinguishedName)"
}

# ---- Preflight: nothing is changed until all of this passes ---------------------------------
$users = @(Import-LabUserCsv -Path $CsvPath)

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$RootTargetOU'")) {
    throw "Root OU not found: $RootTargetOU."
}

$validSuffixes = @(@((Get-ADForest).UPNSuffixes) + @($domain.DNSRoot)) |
    Where-Object { $_ } |
    ForEach-Object { $_.ToLowerInvariant() }
if ($validSuffixes -notcontains $suffix) {
    throw "UPN suffix '$suffix' is not registered in the forest. Run 02-Configure-UPNSuffixes.ps1 first."
}

# ---- Users ----------------------------------------------------------------------------------
$results = New-Object -TypeName System.Collections.Generic.List[object]
$failed = 0

foreach ($user in $users) {
    $desiredUpn = "$($user.SamAccountName)@$suffix"
    $result = [pscustomobject]@{
        SamAccountName = $user.SamAccountName
        BeforeUpn      = ''
        AfterUpn       = $desiredUpn
        Action         = 'Pending'
        Detail         = ''
    }

    try {
        $escapedSam = ConvertTo-LdapFilterValue -Value $user.SamAccountName
        $adUser = Get-ADUser -LDAPFilter "(sAMAccountName=$escapedSam)" -SearchBase $RootTargetOU -SearchScope Subtree -Properties UserPrincipalName

        if (-not $adUser) {
            $result.Action = 'NotFound'
            $result.Detail = "No account '$($user.SamAccountName)' under $RootTargetOU."
            $failed++
        }
        else {
            $adUser = @($adUser)[0]
            $result.BeforeUpn = [string]$adUser.UserPrincipalName

            if ($result.BeforeUpn -ieq $desiredUpn) {
                $result.Action = 'NoChange'
            }
            elseif ($PSCmdlet.ShouldProcess($user.SamAccountName, "Change UPN '$($result.BeforeUpn)' -> '$desiredUpn'")) {
                Set-ADUser -Identity "$($adUser.ObjectGUID)" -UserPrincipalName $desiredUpn
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

if ($LogPath) {
    $results | Export-Csv -Path $LogPath -NoTypeInformation
}

$updatedCount = @($results | Where-Object { $_.Action -eq 'Updated' }).Count
$unchangedCount = @($results | Where-Object { $_.Action -eq 'NoChange' }).Count
$wouldUpdateCount = @($results | Where-Object { $_.Action -eq 'WouldUpdate' }).Count
if ($WhatIfPreference) {
    $changeText = "$wouldUpdateCount would update (WhatIf)"
}
else {
    $changeText = "$updatedCount updated"
}
Write-Information -MessageData "Users: $($users.Count) in CSV, $changeText, $unchangedCount unchanged, $failed failed or not found." -InformationAction Continue

if ($failed -gt 0) {
    throw "$failed of $($users.Count) user(s) failed or were not found. See the Action and Detail columns."
}
