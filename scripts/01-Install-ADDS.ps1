<#
.SYNOPSIS
    Installs Active Directory Domain Services and builds the forest interactively.
#>
[CmdletBinding()]
param(
    [string]$DomainName        = (Read-Host "Enter your internal Active Directory domain name (e.g., yourdomain.local)"),
    [string]$DomainNetBIOSName = (Read-Host "Enter your NetBIOS domain name (e.g., YOURDOMAIN)")
)

Write-Host "Deploying Active Directory Forest for: $DomainName ($DomainNetBIOSName)..." -ForegroundColor Cyan

# Install AD-DS Feature
Install-WindowsFeature -Name "AD-Domain-Services" -IncludeManagementTools

# Create AD Forest
Install-ADDSForest -DomainName $DomainName -DomainNetBIOSName $DomainNetBIOSName -InstallDns:$true -Force:$true