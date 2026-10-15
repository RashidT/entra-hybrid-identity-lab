<#
.SYNOPSIS
    Adds the Microsoft Entra tenant domain as an alternate UPN suffix in AD.
#>
[CmdletBinding()]
param(
    [string]$EntraDomain = (Read-Host "Enter your Entra verified tenant domain (e.g., yourdomain.onmicrosoft.com)")
)

Import-Module ActiveDirectory

$Forest = Get-ADForest

if ($Forest.UPNSuffixes -notcontains $EntraDomain) {
    Get-ADForest | Set-ADForest -UPNSuffixes @{ Add = $EntraDomain }
    Write-Host "Successfully added UPN Suffix: $EntraDomain" -ForegroundColor Green
} else {
    Write-Host "UPN Suffix $EntraDomain already exists." -ForegroundColor Yellow
}