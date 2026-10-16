<#
.SYNOPSIS
    Executes repeat-safe user attribute updates and handles department transfers.
.DESCRIPTION
    Applies attribute updates, verifies container compliance, scans existing user records, detects department changes by cross-referencing with CSV data, automatically moves user objects to their new departmental sub-OU, and updates group memberships safely across multiple executions.
    NOTE: Supply mandatory parameter -RootTargetOU when executing.
#>

[CmdletBinding()]
param(
    [string] $CsvPath = "C:\poshlog\users.csv",

    [Parameter(Mandatory = $true)]
    [string] $RootTargetOU
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

                if ($currentDept -ne $targetDept) {
                    Write-Output "Department change detected for user '$samName': '$currentDept' -> '$targetDept'. Relocating..."

                    Move-ADObject -Identity $currentDN -TargetPath $correctOU

                    Set-ADUser -Identity $samName -Department $targetDept

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