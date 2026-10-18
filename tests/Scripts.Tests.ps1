<#
    Unit tests for scripts 01-06. Active Directory is mocked, so these run on a GitHub-hosted runner
    and on a domain controller alike. Each test runs the real script and asserts on what it did:
    which directory commands were called, and with what.

    A test that proves a script "does nothing" asserts that the changing commands were never called.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $script:ScriptsDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'scripts'

    function Invoke-LabScript {
        param([string] $Name, [hashtable] $Parameters = @{})
        $result = [pscustomobject]@{ Output = @(); Threw = $false; Error = '' }
        $collected = New-Object -TypeName System.Collections.Generic.List[object]
        try {
            & (Join-Path -Path $script:ScriptsDir -ChildPath $Name) @Parameters | ForEach-Object { $collected.Add($_) }
        }
        catch {
            $result.Threw = $true
            $result.Error = $_.Exception.Message
        }
        $result.Output = $collected.ToArray()
        return $result
    }

    function New-TestCsv {
        param([string] $Name, [string[]] $Lines)
        $path = Join-Path -Path $TestDrive -ChildPath $Name
        Set-Content -Path $path -Value $Lines
        return $path
    }

    function New-FixtureUser {
        param(
            [string] $DistinguishedName = 'CN=James Smith,OU=IT,OU=CorpUsers,DC=rtworks,DC=local',
            [string] $Department = 'IT',
            [string] $Office = 'Building A',
            [string] $UserPrincipalName = 'jsmith@rtworks.local',
            [string[]] $MemberOf = @('CN=IT-Security-Group,OU=Groups,DC=rtworks,DC=local')
        )
        [pscustomobject]@{
            ObjectGUID        = [guid]'11111111-1111-1111-1111-111111111111'
            SamAccountName    = 'jsmith'
            DistinguishedName = $DistinguishedName
            Department        = $Department
            Title             = 'Engineer'
            Office            = $Office
            GivenName         = 'James'
            Surname           = 'Smith'
            DisplayName       = 'James Smith'
            UserPrincipalName = $UserPrincipalName
            MemberOf          = $MemberOf
        }
    }

    $script:Header = 'Name,LastName,DisplayName,UserPrincipalName,SamAccountName,Department,Title,Office'
    $script:Row1 = 'James,Smith,James Smith,jsmith@rtworks.local,jsmith,IT,Engineer,Building A'
    $script:Row2 = 'Mary,Johnson,Mary Johnson,mjohnson@rtworks.local,mjohnson,IT,Administrator,Building A'
    $script:Row3 = 'Robert,Williams,Robert Williams,rwilliams@rtworks.local,rwilliams,HR,Recruiter,Building B'
    $script:Password = ConvertTo-SecureString -String 'Unit-Test-Only-1!' -AsPlainText -Force
}

Describe '01-Initialize-OUStructure.ps1' {

    BeforeEach {
        Mock Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=rtworks,DC=local'; DNSRoot = 'rtworks.local' } }
        Mock Get-ADObject { [pscustomobject]@{ DistinguishedName = 'DC=rtworks,DC=local' } }
        Mock Get-ADOrganizationalUnit { }
        Mock New-ADOrganizationalUnit { }
    }

    It 'creates the root OU, protected from accidental deletion, when it is missing' {
        $result = Invoke-LabScript -Name '01-Initialize-OUStructure.ps1'
        $result.Threw | Should -BeFalse -Because $result.Error
        $result.Output[0].Action | Should -Be 'Created' -Because $result.Error
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 1 -Scope It -ParameterFilter {
            $Name -eq 'CorpUsers' -and $Path -eq 'DC=rtworks,DC=local' -and $ProtectedFromAccidentalDeletion -eq $true
        }
    }

    It 'does nothing when the root OU already exists' {
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = 'OU=CorpUsers,DC=rtworks,DC=local' } }
        $result = Invoke-LabScript -Name '01-Initialize-OUStructure.ps1'
        $result.Output[0].Action | Should -Be 'AlreadyExisted' -Because $result.Error
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
    }

    It 'fails, and does not try to create anything, when the domain cannot be reached' {
        Mock Get-ADObject { throw 'Unable to contact the server' }
        $result = Invoke-LabScript -Name '01-Initialize-OUStructure.ps1'
        $result.Threw | Should -BeTrue
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
    }

    It 'changes nothing with -WhatIf' {
        $result = Invoke-LabScript -Name '01-Initialize-OUStructure.ps1' -Parameters @{ WhatIf = $true }
        $result.Output[0].Action | Should -Be 'WouldCreate' -Because $result.Error
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
    }

    It 'rejects a container name containing an apostrophe' {
        $result = Invoke-LabScript -Name '01-Initialize-OUStructure.ps1' -Parameters @{ RootContainer = "Bad'Name" }
        $result.Threw | Should -BeTrue
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
    }
}

Describe '02-Configure-UPNSuffixes.ps1' {

    BeforeEach {
        $state = @{ Suffixes = @() }
        Mock Get-ADForest { [pscustomobject]@{ Name = 'rtworks.local'; UPNSuffixes = @($state.Suffixes) } }
        Mock Set-ADForest { $state.Suffixes = @($state.Suffixes) + $UPNSuffixes['Add'] }
    }

    It 'adds the suffix, normalized to lower case, and confirms it by reading the forest again' {
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = 'Contoso.OnMicrosoft.com' }
        $result.Threw | Should -BeFalse -Because $result.Error
        $result.Output[0].Action | Should -Be 'Added' -Because $result.Error
        Should -Invoke Set-ADForest -Exactly -Times 1 -Scope It -ParameterFilter { $UPNSuffixes['Add'] -eq 'contoso.onmicrosoft.com' }
        Should -Invoke Get-ADForest -Exactly -Times 2 -Scope It
    }

    It 'does nothing when the suffix is already registered' {
        $state.Suffixes = @('contoso.onmicrosoft.com')
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = 'contoso.onmicrosoft.com' }
        $result.Output[0].Action | Should -Be 'AlreadyPresent' -Because $result.Error
        Should -Invoke Set-ADForest -Exactly -Times 0 -Scope It
    }

    It 'changes nothing with -WhatIf' {
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = 'contoso.onmicrosoft.com'; WhatIf = $true }
        $result.Output[0].Action | Should -Be 'WouldAdd' -Because $result.Error
        Should -Invoke Set-ADForest -Exactly -Times 0 -Scope It
    }

    It 'fails with a useful message when the change is refused' {
        Mock Set-ADForest { throw 'Insufficient access rights' }
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = 'contoso.onmicrosoft.com' }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'Enterprise Admins'
    }

    It 'does not report success when the suffix is missing after the change' {
        Mock Set-ADForest { }
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = 'contoso.onmicrosoft.com' }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'Verification failed'
    }

    It 'rejects a suffix that includes an @ sign' {
        $result = Invoke-LabScript -Name '02-Configure-UPNSuffixes.ps1' -Parameters @{ CustomUpnSuffix = '@contoso.onmicrosoft.com' }
        $result.Threw | Should -BeTrue
        Should -Invoke Set-ADForest -Exactly -Times 0 -Scope It
    }
}

Describe '03-BulkImport-Users.ps1' {

    BeforeEach {
        $script:Csv = New-TestCsv -Name 'users.csv' -Lines @($script:Header, $script:Row1, $script:Row2, $script:Row3)
        $script:Single = New-TestCsv -Name 'single.csv' -Lines @($script:Header, $script:Row1)
        Mock Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=rtworks,DC=local'; DNSRoot = 'rtworks.local' } }
        Mock Get-ADForest { [pscustomobject]@{ Name = 'rtworks.local'; UPNSuffixes = @() } }
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = 'exists' } }
        Mock New-ADOrganizationalUnit { }
        Mock Get-ADGroup {
            if ($Filter -match "Name -eq '([^']+)'") {
                [pscustomobject]@{ DistinguishedName = "CN=$($Matches[1]),OU=Groups,DC=rtworks,DC=local" }
            }
        }
        Mock New-ADGroup { [pscustomobject]@{ DistinguishedName = "CN=$Name,$Path" } }
        Mock Get-ADUser { }
        Mock New-ADUser { [pscustomobject]@{ DistinguishedName = "CN=$Name,$Path" } }
        Mock Add-ADGroupMember { }
    }

    It 'creates each missing user once and adds each to the department group' {
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Csv; InitialPassword = $script:Password }
        $result.Threw | Should -BeFalse -Because $result.Error
        @($result.Output | Where-Object { $_.Action -eq 'Created' }).Count | Should -Be 3 -Because $result.Error
        Should -Invoke New-ADUser -Exactly -Times 3 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 3 -Scope It
    }

    It 'sets the name, department, UPN and OU, and requires a password change at first logon' {
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Single; InitialPassword = $script:Password }
        $result.Threw | Should -BeFalse -Because $result.Error
        Should -Invoke New-ADUser -Exactly -Times 1 -Scope It -ParameterFilter {
            $Name -eq 'James Smith' -and $GivenName -eq 'James' -and $Surname -eq 'Smith' -and
            $Department -eq 'IT' -and $Title -eq 'Engineer' -and $Office -eq 'Building A' -and
            $Path -eq 'OU=IT,OU=CorpUsers,DC=rtworks,DC=local' -and
            $UserPrincipalName -eq 'jsmith@rtworks.local' -and $ChangePasswordAtLogon -eq $true
        }
    }

    It 'changes nothing for a user that already exists and is already in the group' {
        Mock Get-ADUser {
            [pscustomobject]@{
                DistinguishedName = 'CN=James Smith,OU=IT,OU=CorpUsers,DC=rtworks,DC=local'
                MemberOf          = @('CN=IT-Security-Group,OU=Groups,DC=rtworks,DC=local')
            }
        }
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Single; InitialPassword = $script:Password }
        $result.Output[0].Action | Should -Be 'AlreadyExisted' -Because $result.Error
        $result.Output[0].GroupAction | Should -Be 'AlreadyMember' -Because $result.Error
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'adds an existing user to the group when the membership is missing' {
        Mock Get-ADUser {
            [pscustomobject]@{ DistinguishedName = 'CN=James Smith,OU=IT,OU=CorpUsers,DC=rtworks,DC=local'; MemberOf = @() }
        }
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Single; InitialPassword = $script:Password }
        $result.Output[0].GroupAction | Should -Be 'Added' -Because $result.Error
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 1 -Scope It
    }

    It 'refuses to touch an account with the same name outside the lab OU' {
        Mock Get-ADUser {
            [pscustomobject]@{ DistinguishedName = 'CN=Admin,CN=Users,DC=rtworks,DC=local'; MemberOf = @() }
        }
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Single; InitialPassword = $script:Password }
        $result.Threw | Should -BeTrue
        $result.Output[0].Action | Should -Be 'Failed' -Because $result.Error
        $result.Output[0].Detail | Should -Match 'outside the lab OU'
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'carries on after one user fails, records why, and still fails overall' {
        Mock New-ADUser {
            if ($SamAccountName -eq 'mjohnson') { throw 'The server is unwilling to process the request' }
            [pscustomobject]@{ DistinguishedName = "CN=$Name,$Path" }
        }
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Csv; InitialPassword = $script:Password }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match '1 of 3'
        $failed = @($result.Output | Where-Object { $_.Action -eq 'Failed' })
        $failed.Count | Should -Be 1
        $failed[0].SamAccountName | Should -Be 'mjohnson'
        $failed[0].Detail | Should -Match 'unwilling'
        Should -Invoke New-ADUser -Exactly -Times 3 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 2 -Scope It
    }

    It 'makes no directory change at all when the CSV is invalid' {
        $bad = New-TestCsv -Name 'bad.csv' -Lines @($script:Header, $script:Row1, $script:Row1)
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $bad; InitialPassword = $script:Password }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'CSV validation failed'
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
        Should -Invoke New-ADGroup -Exactly -Times 0 -Scope It
    }

    It 'stops before any change when a UPN suffix in the CSV is not registered in the forest' {
        $other = New-TestCsv -Name 'other.csv' -Lines @($script:Header, 'James,Smith,James Smith,jsmith@contoso.onmicrosoft.com,jsmith,IT,Engineer,Building A')
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $other; InitialPassword = $script:Password }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'contoso.onmicrosoft.com'
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
    }

    It 'accepts that suffix once it is registered' {
        Mock Get-ADForest { [pscustomobject]@{ Name = 'rtworks.local'; UPNSuffixes = @('contoso.onmicrosoft.com') } }
        $other = New-TestCsv -Name 'other.csv' -Lines @($script:Header, 'James,Smith,James Smith,jsmith@contoso.onmicrosoft.com,jsmith,IT,Engineer,Building A')
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $other; InitialPassword = $script:Password }
        $result.Threw | Should -BeFalse -Because $result.Error
        Should -Invoke New-ADUser -Exactly -Times 1 -Scope It
    }

    It 'stops when the root OU does not exist' {
        Mock Get-ADOrganizationalUnit { }
        $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Csv; InitialPassword = $script:Password }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'Root OU not found'
        Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
    }

    Context 'when the department OUs and groups do not exist yet' {
        BeforeEach {
            Mock Get-ADOrganizationalUnit {
                if ($Filter -eq "DistinguishedName -eq 'OU=CorpUsers,DC=rtworks,DC=local'") {
                    [pscustomobject]@{ DistinguishedName = 'OU=CorpUsers,DC=rtworks,DC=local' }
                }
            }
            Mock Get-ADGroup { }
        }

        It 'creates the ten department OUs and groups, then the users' {
            $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Csv; InitialPassword = $script:Password }
            $result.Threw | Should -BeFalse -Because $result.Error
            Should -Invoke New-ADOrganizationalUnit -Exactly -Times 10 -Scope It
            Should -Invoke New-ADGroup -Exactly -Times 10 -Scope It
            Should -Invoke New-ADUser -Exactly -Times 3 -Scope It
        }

        It 'changes nothing with -WhatIf' {
            $result = Invoke-LabScript -Name '03-BulkImport-Users.ps1' -Parameters @{ CsvPath = $script:Csv; InitialPassword = $script:Password; WhatIf = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'WouldCreate' }).Count | Should -Be 3 -Because $result.Error
            Should -Invoke New-ADOrganizationalUnit -Exactly -Times 0 -Scope It
            Should -Invoke New-ADGroup -Exactly -Times 0 -Scope It
            Should -Invoke New-ADUser -Exactly -Times 0 -Scope It
            Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
        }
    }
}

Describe '04-Test-CloudSyncAgent.ps1' {

    BeforeEach {
        Mock Get-Service -ParameterFilter { $Name -eq 'AADConnectProvisioningAgent' } {
            [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Get-Service -ParameterFilter { $Name -eq 'AADConnectProvisioningAgentUpdater' } {
            [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Get-CimInstance { [pscustomobject]@{ StartName = 'RTWORKS\provAgent$' } }
        Mock Get-ItemProperty { [pscustomobject]@{ SchUseStrongCrypto = 1 } }
        Mock Test-NetConnection { [pscustomobject]@{ TcpTestSucceeded = $true } }
    }

    It 'passes every check for a healthy agent' {
        $result = Invoke-LabScript -Name '04-Test-CloudSyncAgent.ps1'
        $result.Threw | Should -BeFalse -Because $result.Error
        @($result.Output | Where-Object { $_.Status -ne 'Pass' }).Count | Should -Be 0 -Because $result.Error
    }

    It 'fails when the agent service is stopped' {
        Mock Get-Service -ParameterFilter { $Name -eq 'AADConnectProvisioningAgent' } {
            [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' }
        }
        $result = Invoke-LabScript -Name '04-Test-CloudSyncAgent.ps1'
        $result.Threw | Should -BeTrue
        @($result.Output | Where-Object { $_.Check -eq 'Agent service' -and $_.Status -eq 'Fail' }).Count | Should -Be 1 -Because $result.Error
    }

    It 'fails when the agent service is not installed' {
        Mock Get-Service -ParameterFilter { $Name -eq 'AADConnectProvisioningAgent' } { }
        $result = Invoke-LabScript -Name '04-Test-CloudSyncAgent.ps1'
        $result.Threw | Should -BeTrue
        $result.Output[0].Detail | Should -Match 'not found'
    }

    It 'fails when an endpoint cannot be reached' {
        Mock Test-NetConnection -ParameterFilter { $ComputerName -eq 'login.windows.net' } { [pscustomobject]@{ TcpTestSucceeded = $false } }
        $result = Invoke-LabScript -Name '04-Test-CloudSyncAgent.ps1'
        $result.Threw | Should -BeTrue
        @($result.Output | Where-Object { $_.Status -eq 'Fail' -and $_.Check -match 'login.windows.net' }).Count | Should -Be 1 -Because $result.Error
    }

    It 'only warns, without failing, about a weak service account and start type' {
        Mock Get-Service -ParameterFilter { $Name -eq 'AADConnectProvisioningAgent' } {
            [pscustomobject]@{ Status = 'Running'; StartType = 'Manual' }
        }
        Mock Get-CimInstance { [pscustomobject]@{ StartName = 'LocalSystem' } }
        $result = Invoke-LabScript -Name '04-Test-CloudSyncAgent.ps1'
        $result.Threw | Should -BeFalse -Because $result.Error
        @($result.Output | Where-Object { $_.Status -eq 'Warn' }).Count | Should -Be 2 -Because $result.Error
    }
}

Describe '05-Update-ADUsers.ps1' {

    BeforeEach {
        $script:Csv = New-TestCsv -Name 'single.csv' -Lines @($script:Header, $script:Row1)
        $state = @{ Fixture = New-FixtureUser; Others = @() }
        Mock Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=rtworks,DC=local'; DNSRoot = 'rtworks.local' } }
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = 'exists' } }
        Mock Get-ADGroup {
            if ($Filter -match "Name -eq '([^']+)'") {
                [pscustomobject]@{ DistinguishedName = "CN=$($Matches[1]),OU=Groups,DC=rtworks,DC=local" }
            }
        }
        Mock Get-ADUser -ParameterFilter { $LDAPFilter } { $state.Fixture }
        Mock Get-ADUser -ParameterFilter { $Filter } { $state.Others }
        Mock Move-ADObject { }
        Mock Set-ADUser { }
        Mock Add-ADGroupMember { }
        Mock Remove-ADGroupMember { }
    }

    It 'changes nothing when the directory already matches the CSV' {
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Threw | Should -BeFalse -Because $result.Error
        $result.Output[0].Action | Should -Be 'NoChange' -Because $result.Error
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
        Should -Invoke Remove-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'looks users up inside the root OU only' {
        $null = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        Should -Invoke Get-ADUser -Scope It -ParameterFilter {
            $LDAPFilter -and $SearchBase -eq 'OU=CorpUsers,DC=rtworks,DC=local'
        }
    }

    It 'moves a mover to the new OU, updates the department, and swaps the department groups' {
        $state.Fixture = New-FixtureUser -DistinguishedName 'CN=James Smith,OU=HR,OU=CorpUsers,DC=rtworks,DC=local' `
            -Department 'HR' -MemberOf @('CN=HR-Security-Group,OU=Groups,DC=rtworks,DC=local')
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Threw | Should -BeFalse -Because $result.Error
        $result.Output[0].Action | Should -Be 'Updated' -Because $result.Error
        Should -Invoke Move-ADObject -Exactly -Times 1 -Scope It -ParameterFilter { $TargetPath -eq 'OU=IT,OU=CorpUsers,DC=rtworks,DC=local' }
        Should -Invoke Set-ADUser -Exactly -Times 1 -Scope It -ParameterFilter { $Department -eq 'IT' }
        # The real cmdlets convert -Identity into a group object, so a mock cannot match on the DN text.
        # One removal (the old group) and one addition (the new group) are what this test can prove.
        Should -Invoke Remove-ADGroupMember -Exactly -Times 1 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 1 -Scope It
    }

    It 'repairs a missing group even though the OU and Department attribute already match' {
        $state.Fixture = New-FixtureUser -MemberOf @()
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Output[0].Action | Should -Be 'Updated' -Because $result.Error
        Should -Invoke Add-ADGroupMember -Exactly -Times 1 -Scope It
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'repairs a user who is in the wrong OU even though the Department attribute matches' {
        $state.Fixture = New-FixtureUser -DistinguishedName 'CN=James Smith,OU=HR,OU=CorpUsers,DC=rtworks,DC=local'
        $null = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        Should -Invoke Move-ADObject -Exactly -Times 1 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'corrects a drifted attribute and nothing else' {
        $state.Fixture = New-FixtureUser -Office 'Wrong Building'
        $null = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        Should -Invoke Set-ADUser -Exactly -Times 1 -Scope It -ParameterFilter { $Office -eq 'Building A' }
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'leaves group memberships that are not department groups alone' {
        $state.Fixture = New-FixtureUser -MemberOf @(
            'CN=IT-Security-Group,OU=Groups,DC=rtworks,DC=local',
            'CN=VPN-Users,OU=Groups,DC=rtworks,DC=local'
        )
        $null = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        Should -Invoke Remove-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'reports a CSV user that is not under the root OU and fails overall' {
        $state.Fixture = $null
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Threw | Should -BeTrue
        $result.Output[0].Action | Should -Be 'NotFound' -Because $result.Error
    }

    It 'reports an account that is not in the CSV and does not change it' {
        $state.Others = @(
            (New-FixtureUser),
            [pscustomobject]@{ SamAccountName = 'otimer'; DistinguishedName = 'CN=Old Timer,OU=IT,OU=CorpUsers,DC=rtworks,DC=local' }
        )
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Threw | Should -BeFalse -Because $result.Error
        @($result.Output | Where-Object { $_.Action -eq 'NotInCsv' -and $_.SamAccountName -eq 'otimer' }).Count | Should -Be 1 -Because $result.Error
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'changes nothing with -WhatIf, even when there is drift' {
        $state.Fixture = New-FixtureUser -DistinguishedName 'CN=James Smith,OU=HR,OU=CorpUsers,DC=rtworks,DC=local' -Department 'HR' -MemberOf @()
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; WhatIf = $true }
        $result.Output[0].Action | Should -Be 'WouldUpdate' -Because $result.Error
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
        Should -Invoke Add-ADGroupMember -Exactly -Times 0 -Scope It
    }

    It 'stops before any change when a department group is missing' {
        Mock Get-ADGroup { }
        $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'IT-Security-Group'
        Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    Context 'leavers' {
        BeforeEach {
            Mock Disable-ADAccount { }
            $state.Leaver = [pscustomobject]@{
                ObjectGUID        = [guid]'22222222-2222-2222-2222-222222222222'
                SamAccountName    = 'otimer'
                DistinguishedName = 'CN=Old Timer,OU=IT,OU=CorpUsers,DC=rtworks,DC=local'
                Enabled           = $true
                Description       = ''
                MemberOf          = @(
                    'CN=IT-Security-Group,OU=Groups,DC=rtworks,DC=local',
                    'CN=VPN-Users,OU=Groups,DC=rtworks,DC=local'
                )
            }
            $state.Others = @($state.Fixture, $state.Leaver)
        }

        It 'only reports a leaver unless -ProcessLeavers is used' {
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'NotInCsv' }).Count | Should -Be 1 -Because $result.Error
            Should -Invoke Disable-ADAccount -Exactly -Times 0 -Scope It
            Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        }

        It 'disables the leaver, removes department groups only, stamps the description and moves to the Disabled OU' {
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; ProcessLeavers = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'LeaverProcessed' }).Count | Should -Be 1 -Because $result.Error
            Should -Invoke Disable-ADAccount -Exactly -Times 1 -Scope It
            # Exactly one removal: the department group. The VPN-Users membership is kept.
            Should -Invoke Remove-ADGroupMember -Exactly -Times 1 -Scope It
            Should -Invoke Set-ADUser -Exactly -Times 1 -Scope It -ParameterFilter { $Description -like 'Leaver *' }
            Should -Invoke Move-ADObject -Exactly -Times 1 -Scope It -ParameterFilter {
                $TargetPath -eq 'OU=Disabled,OU=CorpUsers,DC=rtworks,DC=local'
            }
        }

        It 'never deletes anything' {
            $text = Get-Content -Path (Join-Path -Path $script:ScriptsDir -ChildPath '05-Update-ADUsers.ps1') -Raw
            $text | Should -Not -Match 'Remove-ADUser|Remove-ADObject'
        }

        It 'does nothing for a leaver that is already fully processed' {
            $state.Leaver.Enabled = $false
            $state.Leaver.DistinguishedName = 'CN=Old Timer,OU=Disabled,OU=CorpUsers,DC=rtworks,DC=local'
            $state.Leaver.MemberOf = @()
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; ProcessLeavers = $true }
            @($result.Output | Where-Object { $_.Action -eq 'AlreadyLeaver' }).Count | Should -Be 1 -Because $result.Error
            Should -Invoke Disable-ADAccount -Exactly -Times 0 -Scope It
            Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
            Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
        }

        It 'changes nothing with -WhatIf' {
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; ProcessLeavers = $true; WhatIf = $true }
            @($result.Output | Where-Object { $_.Action -eq 'WouldProcessLeaver' }).Count | Should -Be 1 -Because $result.Error
            Should -Invoke Disable-ADAccount -Exactly -Times 0 -Scope It
            Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        }

        It 'stops before any change when more leavers would be processed than -MaxLeavers allows' {
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; ProcessLeavers = $true; MaxLeavers = 1 }
            $result.Threw | Should -BeFalse -Because $result.Error
            $state.Others = @($state.Fixture, $state.Leaver, [pscustomobject]@{
                    ObjectGUID = [guid]'33333333-3333-3333-3333-333333333333'; SamAccountName = 'second'
                    DistinguishedName = 'CN=Second,OU=IT,OU=CorpUsers,DC=rtworks,DC=local'; Enabled = $true; Description = ''; MemberOf = @()
                })
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv; ProcessLeavers = $true; MaxLeavers = 1 }
            $result.Threw | Should -BeTrue
            $result.Error | Should -Match 'MaxLeavers'
            Should -Invoke Disable-ADAccount -Exactly -Times 1 -Scope It
        }

        It 'refuses to touch a CSV user who is sitting in the Disabled OU' {
            $state.Fixture = New-FixtureUser -DistinguishedName 'CN=James Smith,OU=Disabled,OU=CorpUsers,DC=rtworks,DC=local'
            $result = Invoke-LabScript -Name '05-Update-ADUsers.ps1' -Parameters @{ CsvPath = $script:Csv }
            $result.Threw | Should -BeTrue
            $result.Output[0].Action | Should -Be 'Failed' -Because $result.Error
            Should -Invoke Move-ADObject -Exactly -Times 0 -Scope It
        }
    }
}

Describe '06-Set-UserUPN.ps1' {

    BeforeEach {
        $script:Csv = New-TestCsv -Name 'single.csv' -Lines @($script:Header, $script:Row1)
        $state = @{ Fixture = New-FixtureUser }
        Mock Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=rtworks,DC=local'; DNSRoot = 'rtworks.local' } }
        Mock Get-ADForest { [pscustomobject]@{ Name = 'rtworks.local'; UPNSuffixes = @('contoso.onmicrosoft.com') } }
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = 'exists' } }
        Mock Get-ADUser { $state.Fixture }
        Mock Set-ADUser { }
    }

    It 'changes the UPN to the new suffix and reports before and after' {
        $result = Invoke-LabScript -Name '06-Set-UserUPN.ps1' -Parameters @{ NewSuffix = 'contoso.onmicrosoft.com'; CsvPath = $script:Csv }
        $result.Threw | Should -BeFalse -Because $result.Error
        $result.Output[0].BeforeUpn | Should -Be 'jsmith@rtworks.local' -Because $result.Error
        $result.Output[0].AfterUpn | Should -Be 'jsmith@contoso.onmicrosoft.com' -Because $result.Error
        $result.Output[0].Action | Should -Be 'Updated' -Because $result.Error
        Should -Invoke Set-ADUser -Exactly -Times 1 -Scope It -ParameterFilter { $UserPrincipalName -eq 'jsmith@contoso.onmicrosoft.com' }
    }

    It 'does nothing when the user already has the new UPN' {
        $state.Fixture = New-FixtureUser -UserPrincipalName 'JSmith@Contoso.OnMicrosoft.com'
        $result = Invoke-LabScript -Name '06-Set-UserUPN.ps1' -Parameters @{ NewSuffix = 'contoso.onmicrosoft.com'; CsvPath = $script:Csv }
        $result.Output[0].Action | Should -Be 'NoChange' -Because $result.Error
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'refuses a suffix that is not registered in the forest, before any change' {
        $result = Invoke-LabScript -Name '06-Set-UserUPN.ps1' -Parameters @{ NewSuffix = 'unregistered.example.com'; CsvPath = $script:Csv }
        $result.Threw | Should -BeTrue
        $result.Error | Should -Match 'not registered'
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'changes nothing with -WhatIf' {
        $result = Invoke-LabScript -Name '06-Set-UserUPN.ps1' -Parameters @{ NewSuffix = 'contoso.onmicrosoft.com'; CsvPath = $script:Csv; WhatIf = $true }
        $result.Output[0].Action | Should -Be 'WouldUpdate' -Because $result.Error
        Should -Invoke Set-ADUser -Exactly -Times 0 -Scope It
    }

    It 'reports a user that cannot be found and fails overall' {
        Mock Get-ADUser { }
        $result = Invoke-LabScript -Name '06-Set-UserUPN.ps1' -Parameters @{ NewSuffix = 'contoso.onmicrosoft.com'; CsvPath = $script:Csv }
        $result.Threw | Should -BeTrue
        $result.Output[0].Action | Should -Be 'NotFound' -Because $result.Error
    }
}
