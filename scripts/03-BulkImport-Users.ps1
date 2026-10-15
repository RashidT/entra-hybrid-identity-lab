<#
.SYNOPSIS
    Bulk imports on-premises AD users from CSV into dynamic department sub-OUs under CorpUsers.
.DESCRIPTION
    Reads a CSV file containing user attributes, automatically ensures the root CorpUsers OU 
    and department-specific sub-OUs exist, provisions department security groups, and creates 
    new user objects inside their respective department sub-containers.
#>
[CmdletBinding()]
param(
    [string] $CsvPath     = "C:\poshlog\users.csv",
    [string] $EntraDomain = (Read-Host "Enter your Entra verified tenant domain (e.g., yourdomain.onmicrosoft.com)"),
    [string] $RootOUName  = "CorpUsers",
    # TODO: Replace 'rtworks' with your own Active Directory domain name component (e.g., yourdomain)
    [string] $BaseDN      = "DC=rtworks,DC=local",
    # TODO: Replace 'rtworks' with your own Active Directory domain name component (e.g., yourdomain)
    [string] $RootTargetOU = "OU=CorpUsers,DC=rtworks,DC=local"
)

Import-Module ActiveDirectory

if (-not (Test-Path -Path $CsvPath)) {
    Throw "CSV file not found at specified path: $CsvPath"
}

# 1. Ensure Root CorpUsers OU exists
$ExistingRoot = Get-ADObject -Filter "DistinguishedName -eq '$RootTargetOU'" -ErrorAction SilentlyContinue
if ($ExistingRoot) {
    Write-Host "Root target OU '$RootTargetOU' already exists." -ForegroundColor Cyan
} else {
    Write-Host "Root target OU '$RootTargetOU' not found. Creating it automatically..." -ForegroundColor Yellow
    New-ADOrganizationalUnit -Name $RootOUName -Path $BaseDN -Description "Root container for hybrid lab users" -ProtectedFromAccidentalDeletion $false
    Write-Host "Successfully created Root OU: $RootTargetOU" -ForegroundColor Green
}

$Users = Import-Csv -Path $CsvPath
Write-Host "Importing $($Users.Count) users from $CsvPath into dynamic department OUs..." -ForegroundColor Cyan

foreach ($User in $Users) {
    $Sam = $User.SamAccountName
    if (-not $Sam) { continue }
    
    $UPN       = "$Sam@$EntraDomain"
    $Dept      = $User.Department
    if (-not $Dept) { $Dept = "General" } # Fallback if department is blank
    
    $GroupName = "$Dept-Security-Group"
    
    # Define dynamic Department Sub-OU path (e.g., OU=Finance,OU=CorpUsers,DC=rtworks,DC=local)
    $DeptTargetOU = "OU=$Dept,$RootTargetOU"
    
    # 2. Ensure Department Sub-OU exists dynamically
    $ExistingDeptOU = Get-ADObject -Filter "DistinguishedName -eq '$DeptTargetOU'" -ErrorAction SilentlyContinue
    if (-not $ExistingDeptOU) {
        Write-Host "Department OU 'OU=$Dept' not found under $RootTargetOU. Creating it..." -ForegroundColor Yellow
        New-ADOrganizationalUnit -Name $Dept -Path $RootTargetOU -Description "Auto-created sub-OU for $Dept department" -ProtectedFromAccidentalDeletion $false
        Write-Host "Successfully created Department OU: $DeptTargetOU" -ForegroundColor Green
    }
    
    # Construct proper full name and display name values uniformly
    $FullName    = "$($User.Name) $($User.LastName)"
    $DisplayName = if ($User.DisplayName) { $User.DisplayName } else { $FullName }
    
    # 3. Ensure Department Security Group exists
    if (-not (Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Description "Auto-created security group for $Dept"
        Write-Host "Created Security Group: $GroupName" -ForegroundColor Cyan
    }
    
    # 4. Check if user already exists
    $ExistingUser = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -Properties CanonicalName -ErrorAction SilentlyContinue
    if (-not $ExistingUser) {
        $PlainPassword  = if ($User.Password) { $User.Password } else { "P@ssw0rd2026!" }
        $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
        
        # New-ADUser explicitly places the user into their specific Department Sub-OU
        New-ADUser -SamAccountName   $Sam `
            -UserPrincipalName       $UPN `
            -Name                    $FullName `
            -GivenName               $User.Name `
            -Surname                 $User.LastName `
            -DisplayName             $DisplayName `
            -Department              $Dept `
            -Title                   $User.Title `
            -Office                  $User.Office `
            -Path                    $DeptTargetOU `
            -Enabled                 $true `
            -AccountPassword         $SecurePassword
        
        Write-Host "Successfully created user in ${DeptTargetOU} : $UPN ($FullName)" -ForegroundColor Green
    } else {
        Write-Host "User $Sam already exists. Skipping creation." -ForegroundColor Yellow
    }
    
    # 5. Ensure user is in the department security group
    $GroupMember = Get-ADGroupMember -Identity $GroupName -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $Sam }
    if (-not $GroupMember) {
        Add-ADGroupMember -Identity $GroupName -Members$Sam
        Write-Host "Added $Sam to group $GroupName" -ForegroundColor Green
    }
}

Write-Host "Bulk import and department OU provisioning process completed successfully." -ForegroundColor Cyan