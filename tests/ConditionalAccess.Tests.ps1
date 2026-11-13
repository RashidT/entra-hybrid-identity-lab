<#
    Unit tests for scripts/ConditionalAccessCommon.ps1 and the committed policies/*.json.
    No Graph connection is needed, so these run in the GitHub Actions 'test' job (R-54: that job
    gets no id-token permission).
#>

BeforeDiscovery {
    $policiesDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'policies'
    $script:PolicyFiles = @(Get-ChildItem -Path $policiesDir -Filter 'LAB-*.json' | ForEach-Object {
            @{ Name = $_.Name; Path = $_.FullName }
        })
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath 'ConditionalAccessCommon.ps1')

    $script:EaId = '11111111-1111-1111-1111-111111111111'
    $script:ItId = '22222222-2222-2222-2222-222222222222'

    # A valid definition, built fresh for each test so one test can't change another's copy.
    function New-TestDefinition {
        [ordered]@{
            displayName   = 'LAB-999 Test policy'
            state         = 'enabledForReportingButNotEnforced'
            conditions    = [ordered]@{
                users          = [ordered]@{
                    includeGroups = @('{{ItSecurityGroupId}}')
                    excludeGroups = @('{{EmergencyAccessGroupId}}')
                }
                applications   = [ordered]@{ includeApplications = @('All') }
                clientAppTypes = @('all')
            }
            grantControls = [ordered]@{ operator = 'OR'; builtInControls = @('mfa') }
        }
    }

    function New-TestJsonFile {
        param([string] $Name, [string] $Content)
        $path = Join-Path -Path $TestDrive -ChildPath $Name
        Set-Content -LiteralPath $path -Value $Content
        return $path
    }
}

Describe 'Read-LabPolicyDefinition' {

    It 'reads a definition file as a hashtable' {
        $path = New-TestJsonFile -Name 'ok.json' -Content ((New-TestDefinition) | ConvertTo-Json -Depth 10)
        $definition = Read-LabPolicyDefinition -Path $path
        $definition | Should -BeOfType [System.Collections.IDictionary]
        $definition['displayName'] | Should -BeExactly 'LAB-999 Test policy'
    }

    It 'rejects a missing file' {
        { Read-LabPolicyDefinition -Path (Join-Path -Path $TestDrive -ChildPath 'none.json') } | Should -Throw '*not found*'
    }

    It 'rejects a file that is not valid JSON' {
        $path = New-TestJsonFile -Name 'bad.json' -Content '{ "displayName": '
        { Read-LabPolicyDefinition -Path $path } | Should -Throw '*not valid JSON*'
    }

    It 'rejects a JSON array' {
        $path = New-TestJsonFile -Name 'array.json' -Content '[1, 2]'
        { Read-LabPolicyDefinition -Path $path } | Should -Throw '*JSON object*'
    }
}

Describe 'Test-LabPolicyDefinition (R-52)' {

    It 'passes a valid definition' {
        @(Test-LabPolicyDefinition -Definition (New-TestDefinition) -Name 'test').Count | Should -Be 0
    }

    It 'refuses any state other than report-only' -ForEach @(
        @{ State = 'enabled' }
        @{ State = 'disabled' }
        @{ State = 'EnabledForReportingButNotEnforced' }
    ) {
        $definition = New-TestDefinition
        $definition['state'] = $State
        $problems = @(Test-LabPolicyDefinition -Definition $definition -Name 'test')
        $problems.Count | Should -Be 1
        $problems[0] | Should -Match 'report-only'
    }

    It 'refuses a definition with no state' {
        $definition = New-TestDefinition
        $definition.Remove('state')
        $problems = @(Test-LabPolicyDefinition -Definition $definition -Name 'test')
        $problems | Should -Contain "test: required key 'state' is missing."
        ($problems -join "`n") | Should -Match 'report-only'
    }

    It 'refuses read-only or extra keys' -ForEach @(
        @{ Key = 'id' }
        @{ Key = 'createdDateTime' }
        @{ Key = 'sessionControls' }
    ) {
        $definition = New-TestDefinition
        $definition[$Key] = 'x'
        $problems = @(Test-LabPolicyDefinition -Definition $definition -Name 'test')
        $problems | Should -Contain "test: key '$Key' is not allowed. Only displayName, state, conditions, grantControls."
    }

    It 'refuses a display name without the LAB- prefix' {
        $definition = New-TestDefinition
        $definition['displayName'] = 'lab-999 Test policy'
        @(Test-LabPolicyDefinition -Definition $definition -Name 'test') | Should -Contain "test: displayName must start with 'LAB-'."
    }

    It 'refuses a definition that does not exclude the emergency access group' {
        $definition = New-TestDefinition
        $definition['conditions']['users']['excludeGroups'] = @()
        @(Test-LabPolicyDefinition -Definition $definition -Name 'test') | Should -Match 'excludeGroups'
    }

    It 'checks the real group ID once the placeholders are filled' {
        $filled = Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId }
        @(Test-LabPolicyDefinition -Definition $filled -Name 'test' -EmergencyAccessGroupId $script:EaId).Count | Should -Be 0
        @(Test-LabPolicyDefinition -Definition $filled -Name 'test').Count | Should -Be 1
    }

    It 'reports every problem at once' {
        $definition = New-TestDefinition
        $definition['state'] = 'enabled'
        $definition['id'] = 'x'
        @(Test-LabPolicyDefinition -Definition $definition -Name 'test').Count | Should -Be 2
    }
}

Describe 'Resolve-LabPolicyPlaceholder (R-58)' {

    It 'fills both placeholders and leaves the original unchanged' {
        $definition = New-TestDefinition
        $filled = Resolve-LabPolicyPlaceholder -Definition $definition -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId }
        @($filled['conditions']['users']['excludeGroups']) | Should -Be @($script:EaId)
        @($filled['conditions']['users']['includeGroups']) | Should -Be @($script:ItId)
        @($definition['conditions']['users']['excludeGroups']) | Should -Be @('{{EmergencyAccessGroupId}}')
    }

    It 'keeps a one-item array as an array' {
        $filled = Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId }
        $filled['conditions']['clientAppTypes'] -is [array] | Should -BeTrue
        ($filled | ConvertTo-Json -Depth 10) | Should -Match '"clientAppTypes":\s*\[\s*"all"\s*\]'
    }

    It 'fails when a placeholder in the definition has no value' {
        { Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = $script:EaId } } |
            Should -Throw '*not filled: {{ItSecurityGroupId}}*'
    }

    It 'fails on a placeholder name that is not allowed' {
        { Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ OtherGroupId = $script:EaId } } |
            Should -Throw "*Unknown placeholder 'OtherGroupId'*"
    }

    It 'fails when a value is not a GUID' {
        { Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = 'EmergencyAccess'; ItSecurityGroupId = $script:ItId } } |
            Should -Throw '*not a GUID*'
    }

    It 'fails on an unknown placeholder written in the definition' {
        $definition = New-TestDefinition
        $definition['conditions']['users']['includeUsers'] = @('{{SomeUserId}}')
        { Resolve-LabPolicyPlaceholder -Definition $definition -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId } } |
            Should -Throw '*not filled: {{SomeUserId}}*'
    }
}

Describe 'Compare-LabPolicyValue (R-53 comparison rule)' {

    It 'returns <Result> for <Case>' -ForEach @(
        @{ Case = 'equal strings, different case'; Expected = 'ABC'; Actual = 'abc'; Result = $true }
        @{ Case = 'different strings'; Expected = 'mfa'; Actual = 'block'; Result = $false }
        @{ Case = 'arrays in a different order'; Expected = @('a', 'b'); Actual = @('b', 'a'); Result = $true }
        @{ Case = 'array with an extra item'; Expected = @('a'); Actual = @('a', 'b'); Result = $false }
        @{ Case = 'array with a duplicate instead of an item'; Expected = @('a', 'b'); Actual = @('a', 'a'); Result = $false }
        @{ Case = 'empty array against null'; Expected = @(); Actual = $null; Result = $true }
        @{ Case = 'non-empty array against null'; Expected = @('a'); Actual = $null; Result = $false }
        @{ Case = 'string against an array'; Expected = 'a'; Actual = @('a'); Result = $false }
        @{ Case = 'array against a string'; Expected = @('a'); Actual = 'a'; Result = $false }
        @{ Case = 'null against null'; Expected = $null; Actual = $null; Result = $true }
        @{ Case = 'value against null'; Expected = 'a'; Actual = $null; Result = $false }
    ) {
        Compare-LabPolicyValue -Expected $Expected -Actual $Actual | Should -Be $Result
    }

    It 'ignores keys the definition does not set (for example null conditions a GET returns)' {
        $expected = @{ users = @{ includeGroups = @('a') } }
        $actual = @{ users = @{ includeGroups = @('a'); includeUsers = @() }; locations = $null; platforms = $null }
        Compare-LabPolicyValue -Expected $expected -Actual $actual | Should -BeTrue
    }

    It 'finds a difference nested inside an object' {
        $expected = @{ users = @{ excludeGroups = @('a') } }
        $actual = @{ users = @{ excludeGroups = @('a', 'b') } }
        Compare-LabPolicyValue -Expected $expected -Actual $actual | Should -BeFalse
    }

    It 'fails when a key the definition sets is missing in the tenant' {
        Compare-LabPolicyValue -Expected @{ users = @{ includeRoles = @('a') } } -Actual @{ users = @{} } | Should -BeFalse
    }

    It 'fails when an object is expected and the tenant has something else' {
        Compare-LabPolicyValue -Expected @{ a = 1 } -Actual 'x' | Should -BeFalse
    }
}

Describe 'Get-LabPolicyDifference (R-57)' {

    BeforeEach {
        $script:Filled = Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId }
        # What a GET returns: the same values, read-only properties, extra null keys, arrays reordered.
        $script:Actual = ($script:Filled | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
        $script:Actual['id'] = '33333333-3333-3333-3333-333333333333'
        $script:Actual['createdDateTime'] = '2026-10-31T00:00:00Z'
        $script:Actual['sessionControls'] = $null
        $script:Actual['conditions']['locations'] = $null
    }

    It 'reports nothing when the tenant matches' {
        @(Get-LabPolicyDifference -Definition $script:Filled -Actual $script:Actual).Count | Should -Be 0
    }

    It 'reports only the top-level keys that differ' {
        $script:Actual['state'] = 'enabled'
        $script:Actual['conditions']['users']['excludeGroups'] = @($script:EaId, '44444444-4444-4444-4444-444444444444')
        Get-LabPolicyDifference -Definition $script:Filled -Actual $script:Actual | Should -Be @('state', 'conditions')
    }

    It 'reports every key for a policy that does not exist yet' {
        Get-LabPolicyDifference -Definition $script:Filled -Actual $null | Should -Be @('displayName', 'state', 'conditions', 'grantControls')
    }
}

Describe 'Get-LabPolicyPatchBody (R-57, Option A)' {

    It 'holds only the changed keys, each sent whole' {
        $definition = New-TestDefinition
        $body = Get-LabPolicyPatchBody -Definition $definition -ChangedKey @('state', 'conditions')
        @($body.Keys) | Should -Be @('state', 'conditions')
        $body['conditions']['applications']['includeApplications'] | Should -Be @('All')
        $body['conditions']['users']['excludeGroups'] | Should -Be @('{{EmergencyAccessGroupId}}')
    }

    It 'fails on a key that is not in the definition' {
        { Get-LabPolicyPatchBody -Definition (New-TestDefinition) -ChangedKey @('sessionControls') } | Should -Throw '*not in the definition*'
    }
}

Describe 'Committed policy definitions (R-52)' {

    It 'finds the LAB- policy files' {
        $policiesDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'policies'
        @(Get-ChildItem -Path $policiesDir -Filter 'LAB-*.json').Count | Should -BeGreaterThan 0
    }

    It '<Name> passes the deploy checks as committed' -ForEach $script:PolicyFiles {
        $definition = Read-LabPolicyDefinition -Path $Path
        $problems = @(Test-LabPolicyDefinition -Definition $definition -Name $Name)
        $problems.Count | Should -Be 0 -Because ($problems -join '; ')
    }

    It '<Name> has a display name that starts with its file name' -ForEach $script:PolicyFiles {
        $definition = Read-LabPolicyDefinition -Path $Path
        $definition['displayName'] | Should -BeLike "$([System.IO.Path]::GetFileNameWithoutExtension($Name)) *"
    }
}

Describe 'Get-LabPolicyReadbackFinding (R-53)' {

    BeforeAll {
        function New-FilledDefinition {
            param([string] $Name = 'LAB-999 Test policy')
            $filled = Resolve-LabPolicyPlaceholder -Definition (New-TestDefinition) -Value @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId }
            $filled['displayName'] = $Name
            return $filled
        }

        # What a GET returns: the same values plus read-only properties, extra null keys, arrays reordered.
        function New-TenantCopy {
            param([System.Collections.IDictionary] $Definition, [string] $Id = '33333333-3333-3333-3333-333333333333')
            $copy = ($Definition | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
            $copy['id'] = $Id
            $copy['createdDateTime'] = '2026-11-12T00:00:00Z'
            $copy['sessionControls'] = $null
            $copy['conditions']['locations'] = $null
            $copy['conditions']['users']['excludeUsers'] = @()
            return $copy
        }
    }

    It 'returns nothing when every policy matches its definition' {
        $a = New-FilledDefinition -Name 'LAB-998 A'
        $b = New-FilledDefinition -Name 'LAB-999 B'
        $tenant = @((New-TenantCopy -Definition $b), (New-TenantCopy -Definition $a))
        @(Get-LabPolicyReadbackFinding -Definition @($a, $b) -TenantPolicy $tenant).Count | Should -Be 0
    }

    It 'ignores tenant policies that are not LAB- policies' {
        $a = New-FilledDefinition
        $other = @{ displayName = 'AB-001 Require MFA'; state = 'enabled' }
        @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @((New-TenantCopy -Definition $a), $other)).Count | Should -Be 0
    }

    It 'reports Missing for a definition with no tenant policy' {
        $findings = @(Get-LabPolicyReadbackFinding -Definition @((New-FilledDefinition)) -TenantPolicy @())
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'Missing'
        $findings[0].Name | Should -BeExactly 'LAB-999 Test policy'
    }

    It 'reports Drift once per top-level key that differs, naming the key' {
        $a = New-FilledDefinition
        $actual = New-TenantCopy -Definition $a
        $actual['conditions']['users']['excludeGroups'] = @($script:EaId, '44444444-4444-4444-4444-444444444444')
        $actual['grantControls']['builtInControls'] = @('block')
        $findings = @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($actual))
        @($findings.Type | Sort-Object -Unique) | Should -Be @('Drift')
        @($findings.Key) | Should -Be @('conditions', 'grantControls')
    }

    It 'reports NotReportOnly, not Drift, when a LAB- policy is <State>' -ForEach @(
        @{ State = 'enabled' }
        @{ State = 'disabled' }
    ) {
        $a = New-FilledDefinition
        $actual = New-TenantCopy -Definition $a
        $actual['state'] = $State
        $findings = @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($actual))
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'NotReportOnly'
        $findings[0].Key | Should -BeExactly 'state'
    }

    It 'reports Unexpected for a LAB- tenant policy with no file, whatever the case of the prefix' -ForEach @(
        @{ Name = 'LAB-005 Someone added this' }
        @{ Name = 'lab-005 Someone added this' }
        @{ Name = 'Lab-005 Someone added this' }
    ) {
        $extra = @{ displayName = $Name; state = 'enabledForReportingButNotEnforced' }
        $findings = @(Get-LabPolicyReadbackFinding -Definition @() -TenantPolicy @($extra))
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'Unexpected'
        $findings[0].Name | Should -BeExactly $Name
    }

    It 'reports an unexpected LAB- policy that is enforced as both Unexpected and NotReportOnly' {
        $extra = @{ displayName = 'LAB-005 Someone added this'; state = 'enabled' }
        $findings = @(Get-LabPolicyReadbackFinding -Definition @() -TenantPolicy @($extra))
        @($findings.Type | Sort-Object) | Should -Be @('NotReportOnly', 'Unexpected')
    }

    It 'reports Duplicate and compares neither when two tenant policies share a definition name' {
        $a = New-FilledDefinition
        $first = New-TenantCopy -Definition $a
        $second = New-TenantCopy -Definition $a -Id '55555555-5555-5555-5555-555555555555'
        $second['state'] = 'enabled'
        $findings = @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($first, $second))
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'Duplicate'
    }

    It 'reports Duplicate once for an unexpected LAB- name held by two policies' {
        $extra1 = @{ displayName = 'LAB-005 X'; state = 'enabledForReportingButNotEnforced' }
        $extra2 = @{ displayName = 'LAB-005 X'; state = 'enabledForReportingButNotEnforced' }
        $findings = @(Get-LabPolicyReadbackFinding -Definition @() -TenantPolicy @($extra1, $extra2))
        @($findings | Where-Object Type -EQ 'Duplicate').Count | Should -Be 1
        @($findings | Where-Object Type -EQ 'Unexpected').Count | Should -Be 2
    }

    It 'matches the tenant policy by displayName ignoring case, as the deploy does' {
        $a = New-FilledDefinition
        $actual = New-TenantCopy -Definition $a
        $actual['displayName'] = 'lab-999 test policy'
        @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($actual)).Count | Should -Be 0
    }

    It 'treats array order and GUID case as no drift' {
        $a = New-FilledDefinition
        $a['grantControls']['builtInControls'] = @('mfa', 'compliantDevice')
        $actual = New-TenantCopy -Definition $a
        $actual['grantControls']['builtInControls'] = @('compliantDevice', 'mfa')
        $actual['conditions']['users']['excludeGroups'] = @($script:EaId.ToUpperInvariant())
        @(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($actual)).Count | Should -Be 0
    }

    It 'reports every finding in one run' {
        $a = New-FilledDefinition -Name 'LAB-998 A'
        $b = New-FilledDefinition -Name 'LAB-999 B'
        $driftB = New-TenantCopy -Definition $b
        $driftB['grantControls']['operator'] = 'AND'
        $extra = @{ displayName = 'LAB-005 X'; state = 'enabledForReportingButNotEnforced' }
        $findings = @(Get-LabPolicyReadbackFinding -Definition @($a, $b) -TenantPolicy @($driftB, $extra))
        @($findings.Type | Sort-Object) | Should -Be @('Drift', 'Missing', 'Unexpected')
    }

    It 'never puts an object ID in a finding (R-58)' {
        $a = New-FilledDefinition
        $actual = New-TenantCopy -Definition $a
        $actual['conditions']['users']['excludeGroups'] = @('44444444-4444-4444-4444-444444444444')
        $actual['state'] = 'enabled'
        $text = (@(Get-LabPolicyReadbackFinding -Definition @($a) -TenantPolicy @($actual)) | ConvertTo-Json -Depth 5)
        $text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-'
    }

    It 'refuses two definitions with the same displayName' {
        $a = New-FilledDefinition
        { Get-LabPolicyReadbackFinding -Definition @($a, (New-FilledDefinition)) -TenantPolicy @() } | Should -Throw '*more than one definition*'
    }
}

Describe 'Get-LabGroupMemberFinding (R-53, D8)' {

    BeforeAll {
        $script:BgA = 'aaaaaaaa-0000-0000-0000-000000000001'
        $script:BgB = 'aaaaaaaa-0000-0000-0000-000000000002'
        function New-Member {
            param([string] $Id, [string] $Type = '#microsoft.graph.user')
            return @{ '@odata.type' = $Type; id = $Id }
        }
    }

    It 'returns nothing when the members are exactly the expected users, in any order and case' {
        $members = @((New-Member -Id $script:BgB.ToUpperInvariant()), (New-Member -Id $script:BgA))
        @(Get-LabGroupMemberFinding -Member $members -ExpectedId @($script:BgA, $script:BgB)).Count | Should -Be 0
    }

    It 'reports MemberMissing when an expected member is gone' {
        $findings = @(Get-LabGroupMemberFinding -Member @((New-Member -Id $script:BgA)) -ExpectedId @($script:BgA, $script:BgB))
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'MemberMissing'
    }

    It 'reports MemberUnexpected when someone was added' {
        $members = @((New-Member -Id $script:BgA), (New-Member -Id $script:BgB), (New-Member -Id 'bbbbbbbb-0000-0000-0000-000000000003'))
        $findings = @(Get-LabGroupMemberFinding -Member $members -ExpectedId @($script:BgA, $script:BgB))
        $findings.Count | Should -Be 1
        $findings[0].Type | Should -BeExactly 'MemberUnexpected'
    }

    It 'catches a swapped member (same count, different person)' {
        $members = @((New-Member -Id $script:BgA), (New-Member -Id 'bbbbbbbb-0000-0000-0000-000000000003'))
        @((Get-LabGroupMemberFinding -Member $members -ExpectedId @($script:BgA, $script:BgB)).Type | Sort-Object) |
            Should -Be @('MemberMissing', 'MemberUnexpected')
    }

    It 'reports MemberNotUser for a nested group' {
        $members = @((New-Member -Id $script:BgA), (New-Member -Id $script:BgB), (New-Member -Id 'cccccccc-0000-0000-0000-000000000004' -Type '#microsoft.graph.group'))
        @((Get-LabGroupMemberFinding -Member $members -ExpectedId @($script:BgA, $script:BgB)).Type | Sort-Object) |
            Should -Be @('MemberNotUser', 'MemberUnexpected')
    }

    It 'reports MemberMissing for an empty group' {
        @((Get-LabGroupMemberFinding -Member @() -ExpectedId @($script:BgA, $script:BgB)).Type) | Should -Be @('MemberMissing')
    }

    It 'refuses expected IDs that are <Case>' -ForEach @(
        @{ Case = 'empty'; Ids = @(' ', '') ; Message = '*No expected member IDs*' }
        @{ Case = 'not GUIDs'; Ids = @('BG-Admin01'); Message = '*not a GUID*' }
        @{ Case = 'repeated'; Ids = @('aaaaaaaa-0000-0000-0000-000000000001', 'AAAAAAAA-0000-0000-0000-000000000001'); Message = '*duplicate*' }
    ) {
        { Get-LabGroupMemberFinding -Member @() -ExpectedId $Ids } | Should -Throw $Message
    }

    It 'never puts an object ID in a finding (R-58)' {
        $members = @((New-Member -Id 'bbbbbbbb-0000-0000-0000-000000000003' -Type '#microsoft.graph.group'))
        $text = (@(Get-LabGroupMemberFinding -Member $members -ExpectedId @($script:BgA)) | ConvertTo-Json -Depth 5)
        $text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-'
    }
}
