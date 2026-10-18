<#
.SYNOPSIS
    Registers an alternative UPN suffix in the Active Directory forest.
.DESCRIPTION
    Adds the suffix to the forest's UPN suffix list so that user accounts can later be moved to it
    (see 06-Set-UserUPN.ps1). Registering a suffix does not change any user's UPN.
    The suffix is re-read from the forest after the change; the script reports success only if it is
    really present. Running it again with the same suffix changes nothing.
    Changing forest UPN suffixes needs forest-level rights, typically Enterprise Admins.
.PARAMETER CustomUpnSuffix
    The suffix to register, without an @ sign, for example contoso.onmicrosoft.com.
.EXAMPLE
    .\scripts\02-Configure-UPNSuffixes.ps1 -CustomUpnSuffix 'contoso.onmicrosoft.com' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?!-)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')]
    [string] $CustomUpnSuffix
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'LabCommon.ps1')
Import-LabActiveDirectoryModule

$suffix = $CustomUpnSuffix.Trim().ToLowerInvariant()
$forest = Get-ADForest
$existing = @($forest.UPNSuffixes)

if ($existing -contains $suffix) {
    Write-Verbose "UPN suffix '$suffix' is already registered in forest '$($forest.Name)'."
    $action = 'AlreadyPresent'
}
elseif ($PSCmdlet.ShouldProcess($forest.Name, "Add UPN suffix '$suffix'")) {
    try {
        Set-ADForest -Identity $forest.Name -UPNSuffixes @{ Add = $suffix }
    }
    catch {
        throw "Could not add UPN suffix '$suffix' to forest '$($forest.Name)'. Forest-level rights (for example Enterprise Admins) are required. Details: $($_.Exception.Message)"
    }

    $after = @((Get-ADForest).UPNSuffixes)
    if ($after -notcontains $suffix) {
        throw "Verification failed: '$suffix' is not in the forest's UPN suffix list after the change."
    }
    $action = 'Added'
}
elseif ($WhatIfPreference) {
    $action = 'WouldAdd'
}
else {
    $action = 'Skipped'
}

[pscustomobject]@{
    Forest = $forest.Name
    Suffix = $suffix
    Action = $action
}
