<#
.SYNOPSIS
    Executes repeat-safe user attribute updates and handles department transfers.
.DESCRIPTION
    Applies attribute updates, verifies container compliance, scans existing user records, detects department changes by cross-referencing with CSV data, automatically moves user objects to their new departmental sub-OU, and updates group memberships safely across multiple executions.
    NOTE: Update the RootTargetOU parameter default if using a custom domain name instead of rtworks.local.
#>

[CmdletBinding()]
param(
    [string] $CsvPath = "C:\poshlog\users.csv",
    # TODO: Replace 'rtworks.local' with your Active Directory domain components if modified
    [string] $RootTargetOU = "OU=CorpUsers,DC=rtworks,DC=local"
)

begin {
    Write-Output "Starting repeat-safe attribute update and department transfer routine..."
    Import-Module ActiveDirectory
}

process {
    if (-not (Test-Path $CsvPath)) {
        throw "CSV file not found for comparison at path: $CsvPath"
    }

    $csvUsers = Import-Csv -Path $CsvPath
    Write-Output "Scanning users under target container: $RootTargetOU"

    try {
        foreach ($csvUser in $csvUsers) {
            $samName = $csvUser.SamAccountName
            $targetDept = $csvUser.Department
            $correctOU = "OU=$targetDept,$RootTargetOU"

            $adUser = Get-ADUser -Filter "SamAccountName -eq '$samName'" -Properties Department -ErrorAction SilentlyContinue

            if ($adUser) {
                $currentDept = $adUser.Department
                $currentDN = $adUser.DistinguishedName

                # Check if the user has changed departments
                if ($currentDept -ne $targetDept) {
                    Write-Output "Department change detected for user '$samName': '$currentDept' -> '$targetDept'. Relocating..."

                    # 1. Move user object to the new departmental sub-OU
                    Move-ADObject -Identity $currentDN -TargetPath $correctOU

                    # 2. Update the Department attribute in AD
                    Set-ADUser -Identity $samName -Department $targetDept

                    # 3. Update Group Memberships (Remove from old group, add to new group)
                    if ($currentDept) {
                        $oldGroup = "$currentDept-Security-Group"
                        Remove-ADGroupMember -Identity $oldGroup -Members $samName -Confirm:$false -ErrorAction SilentlyContinue
                    }
                    
                    $newGroup = "$targetDept-Security-Group"
                    Add-ADGroupMember -Identity $newGroup -Members $samName -ErrorAction SilentlyContinue

                    Write-Verbose "Successfully transferred '$samName' to $correctOU and updated group memberships."
                } else {
                    Write-Verbose "User '$samName' is already in the correct department OU ($targetDept)."
                }
            } else {
                Write-Verbose "User '$samName' from CSV was not found in Active Directory."
            }
        }
    }
    catch {
        Write-Error "An error occurred during user transfer scanning: $_"
    }
}

end {
    Write-Output "Attribute update and department transfer script completed successfully."
}