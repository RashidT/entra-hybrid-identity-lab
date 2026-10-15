<#
.SYNOPSIS
    Configures UPN suffixes for hybrid identity routing.
.DESCRIPTION
    Adds alternative UPN suffixes to the AD forest to support seamless Entra ID sign-in.
    NOTE: Replace the default placeholder domain with your organization's verified cloud domain.
#>

[CmdletBinding()]
param(
    # TODO: Replace 'yourdomain.onmicrosoft.com' with your actual Microsoft Entra tenant verified domain
    [Parameter(Mandatory = $true)]
    [string] $CustomUpnSuffix = "<tenant>.onmicrosoft.com"
)

begin {
    Write-Output "Initializing UPN Suffix configuration..."
    Import-Module ActiveDirectory
}

process {
    Write-Output "Checking forest configuration for UPN suffix: $CustomUpnSuffix"

    try {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        $existingSuffixes = $forest.Domains.Forest.UpnSuffixes

        if ($existingSuffixes -contains $CustomUpnSuffix) {
            Write-Output "UPN Suffix '$CustomUpnSuffix' is already registered in the forest."
        } else {
            Write-Verbose "Registering new UPN suffix..."
            (Get-ADForest).UPNSuffixes.Add($CustomUpnSuffix)
            Set-ADForest -Identity (Get-ADForest).Name -UPNSuffixes @((Get-ADForest).UPNSuffixes)
            Write-Output "Successfully added UPN suffix: $CustomUpnSuffix"
        }
    }
    catch {
        Write-Error "An error occurred while configuring UPN suffixes: $_"
    }
}

end {
    Write-Output "UPN configuration script completed."
}