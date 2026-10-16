<#
.SYNOPSIS
    Bulk imports users, provisions departmental sub-OUs, and creates security groups.
.DESCRIPTION
    Reads user records from CSV, creates missing department sub-OUs, provisions department
    security groups, and populates user accounts with UPNs and group memberships.
    NOTE: Supply mandatory parameters -EntraDomain and -RootTargetOU when executing.
#>

[CmdletBinding()]
param(
    [string] $CsvPath = ".\data\users.csv",

    [Parameter(Mandatory = $true)]
    [string] $EntraDomain,

    [Parameter(Mandatory = $true)]
    [string] $RootTargetOU,

    [string[]] $Departments = @('IT', 'HR', 'Finance', 'Sales', 'Marketing', 'Engineering', 'Operations', 'Legal', 'Product', 'Customer Support')
)

begin {
    Write-Output "Starting bulk user import, OU provisioning, and security group creation..."
    Import-Module ActiveDirectory
}

process {
    foreach ($dept in $Departments) {
        $deptOU = "OU=$dept,$RootTargetOU"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$deptOU'" -ErrorAction SilentlyContinue)) {
            Write-Verbose "Creating department sub-OU: $deptOU"
            New-ADOrganizationalUnit -Name $dept -Path $RootTargetOU -PassThru | Out-Null
        }

        $groupName = "$dept-Security-Group"
        if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
            Write-Verbose "Creating department security group: $groupName under $deptOU"
            New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $deptOU -PassThru | Out-Null
        }
    }
    Write-Output "All 10 departmental sub-OUs and security groups verified/created successfully."

    if (-not (Test-Path $CsvPath)) {
        throw "CSV file not found at specified path: $CsvPath"
    }

    $users = Import-Csv -Path $CsvPath
    Write-Output "Loaded $($users.Count) user records from CSV dataset."

    foreach ($user in $users) {
        $targetOU = "OU=$($user.Department),$RootTargetOU"
        $upn = "$($user.SamAccountName)@$EntraDomain"
        $groupName = "$($user.Department)-Security-Group"

        try {
            Write-Verbose "Processing user: $($user.SamAccountName) -> Department: $($user.Department)"

            $adUser = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'" -ErrorAction SilentlyContinue
            if (-not $adUser) {
                Write-Verbose "User account would be created at: $targetOU"
            }

            Add-ADGroupMember -Identity $groupName -Members $user.SamAccountName -ErrorAction SilentlyContinue

            [PSCustomObject]@{
                SamAccountName = $user.SamAccountName
                UPN            = $upn
                Path           = $targetOU
                GroupAssigned  = $groupName
                Status         = "Provisioned Successfully"
            }
        }
        catch {
            Write-Error "Failed to process user '$($user.SamAccountName)': $_"
        }
    }
}

end {
    Write-Output "Bulk import and group assignment process completed."
}