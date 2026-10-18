<#
    Tests that need no Active Directory: the shared helper functions and the real data/users.csv.
    These run for real on a GitHub-hosted runner.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath 'LabCommon.ps1')
    $script:DataFile = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'data') -ChildPath 'users.csv'

    function New-TestCsv {
        param([string] $Name, [string[]] $Lines)
        $path = Join-Path -Path $TestDrive -ChildPath $Name
        Set-Content -Path $path -Value $Lines
        return $path
    }
}

Describe 'LabCommon helpers' {

    Context 'ConvertTo-LdapFilterValue' {
        It 'escapes characters that have a meaning in an LDAP filter' {
            ConvertTo-LdapFilterValue -Value 'a*b(c)\d' | Should -Be 'a\2ab\28c\29\5cd'
        }
        It 'leaves ordinary text and apostrophes alone' {
            ConvertTo-LdapFilterValue -Value "o'brien" | Should -Be "o'brien"
        }
    }

    Context 'Get-LabParentDN' {
        It 'removes the first RDN' {
            Get-LabParentDN -DistinguishedName 'CN=A,OU=IT,DC=x,DC=y' | Should -Be 'OU=IT,DC=x,DC=y'
        }
        It 'does not stop at an escaped comma' {
            Get-LabParentDN -DistinguishedName 'CN=Smith\, James,OU=IT,DC=x,DC=y' | Should -Be 'OU=IT,DC=x,DC=y'
        }
    }

    Context 'Test-LabDnUnder' {
        It 'is true for an object below the container, ignoring case' {
            Test-LabDnUnder -DistinguishedName 'CN=A,OU=IT,OU=Root,DC=x' -ContainerDN 'ou=root,dc=x' | Should -BeTrue
        }
        It 'is false for an object elsewhere' {
            Test-LabDnUnder -DistinguishedName 'CN=A,CN=Users,DC=x' -ContainerDN 'OU=Root,DC=x' | Should -BeFalse
        }
    }

    Context 'Import-LabUserCsv' {
        It 'maps the Name and LastName columns to GivenName and Surname and ignores Password' {
            $path = New-TestCsv -Name 'ok.csv' -Lines @(
                'Name,LastName,DisplayName,UserPrincipalName,SamAccountName,Department,Title,Office,Password',
                'James,Smith,James Smith,jsmith@rtworks.local,jsmith,it,Engineer,Building A,secret'
            )
            $user = @(Import-LabUserCsv -Path $path)[0]
            $user.GivenName | Should -Be 'James'
            $user.Surname | Should -Be 'Smith'
            $user.Department | Should -Be 'IT'
            $user.PSObject.Properties.Name | Should -Not -Contain 'Password'
        }

        It 'reports every problem in one error' {
            $path = New-TestCsv -Name 'bad.csv' -Lines @(
                'GivenName,Surname,DisplayName,UserPrincipalName,SamAccountName,Department',
                'A,B,A B,ab@x.local,ab,IT',
                'A,B,A B,ab2@x.local,ab,Nowhere',
                'C,D,,cd@x.local,averyveryverylongaccountname,IT',
                'E,F,E F,not-a-upn,ef,IT'
            )
            $message = ''
            try { Import-LabUserCsv -Path $path | Out-Null } catch { $message = $_.Exception.Message }
            $message | Should -Match 'duplicates line 2'
            $message | Should -Match "department 'Nowhere'"
            $message | Should -Match "'DisplayName' is blank"
            $message | Should -Match 'longer than 20'
            $message | Should -Match 'not in the form name@domain'
        }

        It 'rejects a file with a missing required column' {
            $path = New-TestCsv -Name 'nocolumn.csv' -Lines @('Name,LastName,DisplayName', 'A,B,A B')
            { Import-LabUserCsv -Path $path } | Should -Throw "*Missing required column 'UserPrincipalName'*"
        }

        It 'rejects a missing file' {
            { Import-LabUserCsv -Path (Join-Path -Path $TestDrive -ChildPath 'nope.csv') } | Should -Throw '*not found*'
        }
    }
}

Describe 'data/users.csv' {

    It 'exists' {
        $script:DataFile | Should -Exist
    }

    It 'passes the same validation the scripts apply before they change anything' {
        { Import-LabUserCsv -Path $script:DataFile } | Should -Not -Throw
    }

    It 'has one validated user per data line' {
        $dataLines = @(Get-Content -Path $script:DataFile | Where-Object { $_.Trim() -ne '' }).Count - 1
        @(Import-LabUserCsv -Path $script:DataFile).Count | Should -Be $dataLines
    }

    It 'places every user in one of the lab departments' {
        $departments = Get-LabDepartmentList
        foreach ($user in @(Import-LabUserCsv -Path $script:DataFile)) {
            $departments | Should -Contain $user.Department
        }
    }

    It 'does not carry passwords (the scripts take a SecureString parameter instead)' {
        $header = (Get-Content -Path $script:DataFile -TotalCount 1)
        $header | Should -Not -Match '(?i)password'
    }
}
