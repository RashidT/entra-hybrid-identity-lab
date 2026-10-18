<#
.SYNOPSIS
    Creates the lab's root OU in an existing Active Directory domain.
.DESCRIPTION
    The domain itself is built beforehand by following Microsoft's "Basic Active Directory environment"
    tutorial. This script only creates the root container (default: OU=CorpUsers) if it is missing.
    Running it again changes nothing. Any failure stops the script with a non-zero exit code.
.PARAMETER BaseDN
    Distinguished name of the domain. Defaults to the domain of the machine the script runs on.
.PARAMETER RootContainer
    Name of the root OU to create. Defaults to CorpUsers.
.EXAMPLE
    .\scripts\01-Initialize-OUStructure.ps1 -WhatIf
.EXAMPLE
    .\scripts\01-Initialize-OUStructure.ps1 -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^DC=[^,'']+(,DC=[^,'']+)*$')]
    [string] $BaseDN,

    [ValidatePattern('^[^,=\\''"]+$')]
    [string] $RootContainer = 'CorpUsers'
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'LabCommon.ps1')
Import-LabActiveDirectoryModule

if ([string]::IsNullOrWhiteSpace($BaseDN)) {
    $BaseDN = (Get-ADDomain).DistinguishedName
}
Write-Verbose "Using domain: $BaseDN"

# Throws if the domain cannot be reached or the DN does not exist, so a connectivity or
# permission problem can never be mistaken for "the OU does not exist".
$null = Get-ADObject -Identity $BaseDN

$targetDN = "OU=$RootContainer,$BaseDN"
$existing = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetDN'"

if ($existing) {
    Write-Verbose "Root container already exists: $targetDN"
    $action = 'AlreadyExisted'
}
elseif ($PSCmdlet.ShouldProcess($targetDN, 'Create organizational unit')) {
    New-ADOrganizationalUnit -Name $RootContainer -Path $BaseDN -ProtectedFromAccidentalDeletion $true
    $action = 'Created'
}
elseif ($WhatIfPreference) {
    $action = 'WouldCreate'
}
else {
    $action = 'Skipped'
}

[pscustomobject]@{
    DistinguishedName = $targetDN
    Action            = $action
}
