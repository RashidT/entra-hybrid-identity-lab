<#
.SYNOPSIS
    Pester v6 test suite for validating the Hybrid Identity & Entra ID Lab environment.
.DESCRIPTION
    Dynamically validates CSV parity, Active Directory module availability, CorpUsers root OU, 
    department sub-OUs, security groups, and user attribute formatting (UPN, DisplayName, OU placement).
#>

Describe "Hybrid Identity Lab - Active Directory Infrastructure Validation" {
    
    Context "Prerequisites and Module Availability" {
        It "Should have the ActiveDirectory module available" {
            { Import-Module ActiveDirectory -ErrorAction Stop } | Should -Not -Throw
        }

        It "Should locate the user CSV data file" {
            "C:\poshlog\users.csv" | Should -Exist
        }
    }

    Context "Organizational Unit Structure" {
        It "Should contain the root CorpUsers OU" {
            $BaseDN      = "DC=rtworks,DC=local"
            $CorpUsersDN = "OU=CorpUsers,$BaseDN"
            
            $OU = Get-ADOrganizationalUnit -Identity $CorpUsersDN -ErrorAction SilentlyContinue
            $OU | Should -Not -BeNullOrEmpty
            $OU.Name | Should -Be "CorpUsers"
        }

        $Departments = @("Finance", "Engineering", "Sales")
        foreach ($DeptName in $Departments) {
            It "Should contain the department sub-OU: <DeptName> under CorpUsers" -ForEach @(@{DeptName = $DeptName}) {
                param($DeptName)
                $BaseDN      = "DC=rtworks,DC=local"
                $CorpUsersDN = "OU=CorpUsers,$BaseDN"
                $DeptDN      = "OU=$DeptName,$CorpUsersDN"
                
                $SubOU       = Get-ADOrganizationalUnit -Identity $DeptDN -ErrorAction SilentlyContinue
                $SubOU | Should -Not -BeNullOrEmpty
                $SubOU.Name | Should -Be $DeptName
            }
        }
    }

    Context "Department Security Groups" {
        $Departments = @("Finance", "Engineering", "Sales")
        
        foreach ($GrpDept in $Departments) {
            It "Should contain the security group: <GrpDept>-Security-Group" -ForEach @(@{GrpDept = $GrpDept}) {
                param($GrpDept)
                $GroupName = "$GrpDept-Security-Group"
                $Group     = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue
                $Group | Should -Not -BeNullOrEmpty
                $Group.GroupCategory | Should -Be "Security"
                $Group.GroupScope | Should -Be "Global"
            }
        }
    }

    Context "User Attributes and CSV Parity Validation" {
        It "Should match CSV user count and verify attribute formatting" {
            $CsvData = Import-Csv -Path "C:\poshlog\users.csv"
            $AdUsers = Get-ADUser -Filter * -SearchBase "OU=CorpUsers,DC=rtworks,DC=local" -Properties DisplayName, UserPrincipalName

            # Assert total user count matches CSV records
            $AdUsers.Count | Should -Be $CsvData.Count

            foreach ($User in $AdUsers) {
                # Verify UPN format contains domain suffix
                $User.UserPrincipalName | Should -Match "@"
                
                # Verify DisplayName is populated
                $User.DisplayName | Should -Not -BeNullOrEmpty
                
                # Verify user object resides within the CorpUsers hierarchy
                $User.DistinguishedName | Should -Match "OU=CorpUsers"
            }
        }
    }
}