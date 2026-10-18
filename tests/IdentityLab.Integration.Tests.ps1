<#
    Integration tests: run against the real lab domain on a domain controller or an admin workstation
    with RSAT. They are tagged 'Integration' and skipped when the ActiveDirectory module is missing,
    so the GitHub Actions workflow excludes them.

    Run locally:  Invoke-Pester -Path .\tests\IdentityLab.Integration.Tests.ps1 -Tag Integration
#>

BeforeDiscovery {
    $script:HaveAd = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scripts') -ChildPath 'LabCommon.ps1')
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Import-Module ActiveDirectory
        $script:DomainDn = (Get-ADDomain).DistinguishedName
        $script:RootOu = "OU=CorpUsers,$script:DomainDn"
        $script:Users = @(Import-LabUserCsv -Path (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'data') -ChildPath 'users.csv'))
    }
}

Describe 'Lab domain state' -Tag 'Integration' -Skip:(-not $script:HaveAd) {

    It 'has the root OU' {
        Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$script:RootOu'" | Should -Not -BeNullOrEmpty
    }

    It 'has an OU and a security group for every department in the CSV' {
        foreach ($department in ($script:Users.Department | Select-Object -Unique)) {
            Get-ADOrganizationalUnit -Filter "DistinguishedName -eq 'OU=$department,$script:RootOu'" |
                Should -Not -BeNullOrEmpty -Because "OU for $department"
            Get-ADGroup -Filter "Name -eq '$department-Security-Group'" |
                Should -Not -BeNullOrEmpty -Because "group for $department"
        }
    }

    It 'has every CSV user, enabled, in the right OU' {
        foreach ($user in $script:Users) {
            $found = Get-ADUser -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapFilterValue -Value $user.SamAccountName))" -SearchBase $script:RootOu -Properties Enabled
            $found | Should -Not -BeNullOrEmpty -Because $user.SamAccountName
            $found.Enabled | Should -BeTrue -Because $user.SamAccountName
            $found.DistinguishedName | Should -BeLike "*,OU=$($user.Department),$script:RootOu"
        }
    }

    It 'reports no pending changes when 05-Update-ADUsers.ps1 runs with -WhatIf' {
        $csv = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'data') -ChildPath 'users.csv'
        $results = @(& (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scripts') -ChildPath '05-Update-ADUsers.ps1') -CsvPath $csv -WhatIf)
        @($results | Where-Object { $_.Action -in 'WouldUpdate', 'NotFound', 'Failed' }).Count | Should -Be 0
    }
}
