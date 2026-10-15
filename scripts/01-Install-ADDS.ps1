<#
.SYNOPSIS
    Installs AD DS and sets up the root container structure.
.DESCRIPTION
    Validates module availability, ensures base container structure exists.
    NOTE: Replace 'rtworks.local' with your custom Active Directory domain name where applicable.
#>

[CmdletBinding()]
param(
    # TODO: Replace 'rtworks' with your own Active Directory domain component
    [string] $BaseDN = "DC=rtworks,DC=local",
    [string] $RootContainer = "CorpUsers"
)

begin {
    Write-Output "Starting Active Directory Domain Services environment setup..."
    Write-Verbose "Checking for Active Directory PowerShell module."
    
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "The Active Directory module is required but not installed."
    }
    Import-Module ActiveDirectory
}

process {
    $targetDN = "OU=$RootContainer,$BaseDN"
    Write-Output "Verifying target root container: $targetDN"

    try {
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetDN'" -ErrorAction SilentlyContinue)) {
            Write-Verbose "Root container does not exist. Creating OU=$RootContainer..."
            New-ADOrganizationalUnit -Name $RootContainer -Path $BaseDN -PassThru | Out-Null
            Write-Output "Successfully created container: $targetDN"
        } else {
            Write-Output "Root container already exists: $targetDN"
        }
    }
    catch {
        Write-Error "Failed to verify or create root container: $_"
    }
}

end {
    Write-Output "AD DS initialization script completed."
}