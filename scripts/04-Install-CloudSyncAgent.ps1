<#
.SYNOPSIS
    Installs the Microsoft Entra Connect Cloud Provisioning Agent from a local path.
#>
[CmdletBinding()]
param(
    [string]$InstallerPath = "C:\poshlog\AADConnectProvisioningAgentSetup.exe"
)

# Verify Administrator Privileges
$Identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Throw "This script must be executed in an elevated PowerShell session."
}

if (Test-Path -Path $InstallerPath) {
    Write-Host "Launching silent agent installation..." -ForegroundColor Green
    
    Start-Process -FilePath $InstallerPath -ArgumentList "/quiet /norestart" -Wait
    
    Write-Host "Provisioning Agent installed successfully." -ForegroundColor Green
    Write-Host "ACTION REQUIRED: Open the configuration wizard in the Entra admin center to complete pairing." -ForegroundColor Yellow
} else {
    Throw "Installer not found at path: $InstallerPath. Please download it from the Entra admin center and place it in C:\poshlog\"
}