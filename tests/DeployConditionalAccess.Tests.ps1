<#
    Unit tests for scripts/07-Deploy-ConditionalAccessPolicies.ps1 (R-52, R-57, R-58).
    Microsoft Graph is mocked: Invoke-MgGraphRequest is backed by an in-memory fake tenant, so these
    run in the GitHub Actions 'test' job with no Graph connection and no id-token permission (R-54).
    Each test runs the real script against the committed policies/*.json and asserts on the Graph
    calls it made.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:DeployScript = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath '07-Deploy-ConditionalAccessPolicies.ps1'
    $script:PoliciesDir = Join-Path -Path $repoRoot -ChildPath 'policies'
    $script:PolicyCount = @(Get-ChildItem -LiteralPath $script:PoliciesDir -Filter 'LAB-*.json' -File).Count

    # Made-up IDs. Never real tenant values (R-58).
    $script:EaId = '11111111-1111-1111-1111-111111111111'
    $script:ItId = '22222222-2222-2222-2222-222222222222'

    # Stand-ins so Pester can mock the Graph commands on a runner without Microsoft.Graph.
    $script:StandIns = @()
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) {
        function global:Get-MgContext { [CmdletBinding()] param() }
        $script:StandIns += 'Get-MgContext'
    }
    if (-not (Get-Command -Name Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest {
            [CmdletBinding()]
            param([string] $Method, [string] $Uri, [object] $Body, [string] $ContentType, [string] $OutputType)
        }
        $script:StandIns += 'Invoke-MgGraphRequest'
    }

    function Copy-TestValue {
        param([object] $Value)
        if ($null -eq $Value) { return $null }
        return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
    }

    # A tenant policy as Graph returns it: the definition plus read-only and unset properties.
    function New-TenantPolicy {
        param([System.Collections.IDictionary] $Definition, [string] $Id)
        $policy = Copy-TestValue -Value $Definition
        $policy['id'] = $Id
        $policy['createdDateTime'] = '2026-11-02T00:00:00Z'
        $policy['modifiedDateTime'] = $null
        $policy['sessionControls'] = $null
        $policy['conditions']['platforms'] = $null
        $policy['conditions']['locations'] = $null
        $policy['conditions']['signInRiskLevels'] = @()
        if ($policy['conditions']['users'] -is [System.Collections.IDictionary]) {
            $policy['conditions']['users']['excludeUsers'] = @()
        }
        return $policy
    }

    # The committed definitions with the made-up IDs filled in, keyed by displayName.
    function Get-ResolvedDefinition {
        . (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath 'ConditionalAccessCommon.ps1')
        $all = [ordered]@{}
        foreach ($file in Get-ChildItem -LiteralPath $script:PoliciesDir -Filter 'LAB-*.json' -File | Sort-Object -Property Name) {
            $resolved = Resolve-LabPolicyPlaceholder -Definition (Read-LabPolicyDefinition -Path $file.FullName) -Value @{
                EmergencyAccessGroupId = $script:EaId
                ItSecurityGroupId      = $script:ItId
            }
            $all[[string]$resolved['displayName']] = $resolved
        }
        return $all
    }

    # Fills the fake tenant with every committed policy, matching the repo.
    function Set-TenantInSync {
        $fake.Tenant.Clear()
        $n = 0
        foreach ($entry in (Get-ResolvedDefinition).GetEnumerator()) {
            $n++
            $fake.Tenant.Add((New-TenantPolicy -Definition $entry.Value -Id ("aaaaaaaa-0000-0000-0000-{0:d12}" -f $n)))
        }
    }

    function Invoke-Deploy {
        param([hashtable] $Parameters = @{})
        $all = @{ EmergencyAccessGroupId = $script:EaId; ItSecurityGroupId = $script:ItId; ReadBackDelaySeconds = 0 }
        foreach ($key in $Parameters.Keys) { $all[$key] = $Parameters[$key] }
        $result = [pscustomobject]@{ Output = @(); Information = @(); Threw = $false; Error = '' }
        $collected = New-Object -TypeName System.Collections.Generic.List[object]
        $information = New-Object -TypeName System.Collections.Generic.List[string]
        try {
            & $script:DeployScript @all 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $information.Add("$($_.MessageData)") }
                else { $collected.Add($_) }
            }
        }
        catch {
            $result.Threw = $true
            $result.Error = $_.Exception.Message
        }
        $result.Output = $collected.ToArray()
        $result.Information = $information.ToArray()
        return $result
    }

    function Get-SummaryLine {
        param([object] $Result)
        $lines = @($Result.Information | Where-Object { $_ -like 'Policies:*' })
        $lines.Count | Should -Be 1 -Because "the script writes one summary line. $($Result.Error)"
        return $lines[0]
    }

    function New-TestPolicyFolder {
        param([hashtable] $Files)
        $dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($name in $Files.Keys) {
            Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath $name) -Value $Files[$name]
        }
        return $dir
    }

    function Get-CommittedJson {
        param([string] $Name)
        return (Get-Content -LiteralPath (Join-Path -Path $script:PoliciesDir -ChildPath $Name) -Raw)
    }
}

AfterAll {
    foreach ($name in $script:StandIns) {
        Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue
    }
}

Describe '07-Deploy-ConditionalAccessPolicies.ps1' {

    BeforeEach {
        # Plain (not $script:) variable, so the mock and the helpers find the same fake tenant.
        $fake = @{
            Tenant       = New-Object -TypeName System.Collections.Generic.List[object]
            NextId       = 0
            PageSize     = 0
            PatchApplies = $true
        }

        Mock Get-MgContext { [pscustomobject]@{ Account = $null; AppName = 'lab-ca-deployer' } }
        Mock Start-Sleep { }

        # The fake tenant. GET lists (with optional paging) or reads one; POST creates; PATCH replaces
        # each top-level key sent. DELETE is never expected, and fails the test if called.
        Mock Invoke-MgGraphRequest {
            $base = 'v1.0/identity/conditionalAccess/policies'
            switch ($Method) {
                'GET' {
                    if ($Uri -eq $base -or $Uri -like "$base`?page=*") {
                        $all = @($fake.Tenant | ForEach-Object { Copy-TestValue -Value $_ })
                        if ($fake.PageSize -le 0) { return @{ value = $all } }
                        $start = 0
                        if ($Uri -match 'page=(\d+)') { $start = [int]$Matches[1] }
                        $page = @{ value = @($all | Select-Object -Skip $start -First $fake.PageSize) }
                        if ($start + $fake.PageSize -lt $all.Count) { $page['@odata.nextLink'] = "$base`?page=$($start + $fake.PageSize)" }
                        return $page
                    }
                    $id = $Uri.Substring($base.Length + 1)
                    $found = @($fake.Tenant | Where-Object { $_['id'] -eq $id })
                    if ($found.Count -ne 1) { throw "Response status code does not indicate success: NotFound (Not Found)." }
                    return (Copy-TestValue -Value $found[0])
                }
                'POST' {
                    $fake.NextId++
                    $policy = New-TenantPolicy -Definition ($Body | ConvertFrom-Json -AsHashtable) -Id ("bbbbbbbb-0000-0000-0000-{0:d12}" -f $fake.NextId)
                    $fake.Tenant.Add($policy)
                    return (Copy-TestValue -Value $policy)
                }
                'PATCH' {
                    $id = $Uri.Substring($base.Length + 1)
                    $policy = @($fake.Tenant | Where-Object { $_['id'] -eq $id })[0]
                    if ($fake.PatchApplies) {
                        $patch = $Body | ConvertFrom-Json -AsHashtable
                        foreach ($key in $patch.Keys) { $policy[$key] = $patch[$key] }
                    }
                    return $null
                }
                default { throw "Unexpected Graph method $Method $Uri" }
            }
        }
    }

    Context 'Checks before any Graph call (R-52, R-58)' {

        It 'refuses a definition that is not report-only, and calls Graph not at all' {
            $bad = (Get-CommittedJson -Name 'LAB-001.json') -replace 'enabledForReportingButNotEnforced', 'enabled'
            $dir = New-TestPolicyFolder -Files @{ 'LAB-001.json' = $bad; 'LAB-002.json' = (Get-CommittedJson -Name 'LAB-002.json') }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '*nothing was changed*'
            $result.Error | Should -BeLike "*LAB-001.json: state is 'enabled'*"
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }

        It 'reports every bad file at once' {
            $one = (Get-CommittedJson -Name 'LAB-001.json') -replace 'enabledForReportingButNotEnforced', 'enabled'
            $two = '{ "displayName": '
            $dir = New-TestPolicyFolder -Files @{ 'LAB-001.json' = $one; 'LAB-002.json' = $two }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Error | Should -BeLike '*LAB-001.json*'
            $result.Error | Should -BeLike '*LAB-002.json*not valid JSON*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }

        It 'refuses two files with the same displayName' {
            $json = Get-CommittedJson -Name 'LAB-003.json'
            $dir = New-TestPolicyFolder -Files @{ 'LAB-003.json' = $json; 'LAB-003-copy.json' = $json }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '*used by more than one file*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }

        It 'refuses a group ID that is not a GUID, without printing the value' {
            $result = Invoke-Deploy -Parameters @{ ItSecurityGroupId = 'not-a-guid-value' }
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike "*'ItSecurityGroupId' is not a GUID*"
            $result.Error | Should -Not -BeLike '*not-a-guid-value*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }

        It 'stops when the folder has no LAB- definitions' {
            $dir = New-TestPolicyFolder -Files @{ 'README.txt' = 'nothing here' }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Error | Should -BeLike '*No LAB-*.json*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }

        It 'stops when there is no Graph connection' {
            Mock Get-MgContext { $null }
            $result = Invoke-Deploy
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '*Not connected to Microsoft Graph*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It
        }
    }

    Context 'Create (R-57)' {

        It 'creates every missing policy once, report-only, with the placeholders filled' {
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'Created' }).Count | Should -Be $script:PolicyCount
            Should -Invoke Invoke-MgGraphRequest -Times $script:PolicyCount -Exactly -Scope It -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Invoke-MgGraphRequest -Times $script:PolicyCount -Exactly -Scope It -ParameterFilter {
                $Method -eq 'POST' -and $Body -like '*"enabledForReportingButNotEnforced"*' -and
                $Body -like "*$($script:EaId)*" -and $Body -notlike '*{{*'
            }
        }

        It 'sends only the four definition keys when creating' {
            Invoke-Deploy | Out-Null
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter {
                $Method -eq 'POST' -and @(($Body | ConvertFrom-Json -AsHashtable).Keys | Where-Object { $_ -notin 'displayName', 'state', 'conditions', 'grantControls' }).Count -gt 0
            }
        }

        It 'reports a re-run as unchanged and makes no change (idempotent)' {
            Invoke-Deploy | Out-Null
            $second = Invoke-Deploy
            $second.Threw | Should -BeFalse -Because $second.Error
            @($second.Output | Where-Object { $_.Action -eq 'NoChange' }).Count | Should -Be $script:PolicyCount
            Get-SummaryLine -Result $second | Should -BeLike '*0 created, 0 updated*unchanged*0 failed*'
            Should -Invoke Invoke-MgGraphRequest -Times $script:PolicyCount -Exactly -Scope It -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'reads each new policy back before reporting Created (R-01)' {
            Invoke-Deploy | Out-Null
            Should -Invoke Invoke-MgGraphRequest -Times $script:PolicyCount -Exactly -Scope It -ParameterFilter {
                $Method -eq 'GET' -and $Uri -like 'v1.0/identity/conditionalAccess/policies/*'
            }
        }

        It 'carries on after one create fails, then ends with an error' {
            Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' -and $Body -like '*LAB-002*' } { throw 'Forbidden' }
            $result = Invoke-Deploy
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '1 of * failed*'
            ($result.Output | Where-Object { $_.Policy -like 'LAB-002*' }).Action | Should -Be 'Failed'
            ($result.Output | Where-Object { $_.Policy -like 'LAB-002*' }).Detail | Should -Be 'Forbidden'
            @($result.Output | Where-Object { $_.Action -eq 'Created' }).Count | Should -Be ($script:PolicyCount - 1)
        }
    }

    Context 'Update (R-57, Option A)' {

        It 'PATCHes only the key that drifted, sent whole' {
            Set-TenantInSync
            $fake.Tenant[0]['grantControls'] = @{ operator = 'OR'; builtInControls = @('block') }
            $name = $fake.Tenant[0]['displayName']
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            $row = $result.Output | Where-Object { $_.Policy -eq $name }
            $row.Action | Should -Be 'Updated'
            $row.ChangedKeys | Should -Be 'grantControls'
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -Scope It -ParameterFilter { $Method -eq 'PATCH' }
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -Scope It -ParameterFilter {
                $Method -eq 'PATCH' -and $Uri -like '*/aaaaaaaa-0000-0000-0000-000000000001' -and
                (@(($Body | ConvertFrom-Json -AsHashtable).Keys) -join ',') -eq 'grantControls' -and
                ($Body | ConvertFrom-Json -AsHashtable)['grantControls']['operator'] -eq 'OR'
            }
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'POST' }
        }

        It 'puts a policy someone switched On back to report-only' {
            Set-TenantInSync
            $fake.Tenant[1]['state'] = 'enabled'
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -Scope It -ParameterFilter {
                $Method -eq 'PATCH' -and ($Body | ConvertFrom-Json -AsHashtable)['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'treats extra unset properties, array order and GUID case as unchanged' {
            Set-TenantInSync
            foreach ($policy in $fake.Tenant) {
                $groups = $policy['conditions']['users']['excludeGroups']
                $policy['conditions']['users']['excludeGroups'] = @($groups | ForEach-Object { $_.ToUpperInvariant() })
                [array]::Reverse($policy['conditions']['clientAppTypes'])
            }
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'NoChange' }).Count | Should -Be $script:PolicyCount
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -in 'POST', 'PATCH' }
        }

        It 'reports Failed when the read-back still differs after the retries' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'disabled'
            $fake.PatchApplies = $false
            $result = Invoke-Deploy -Parameters @{ ReadBackAttempts = 3 }
            $result.Threw | Should -BeTrue
            ($result.Output | Where-Object { $_.Action -eq 'Failed' }).Detail | Should -BeLike '*read-back still differs in: state*'
            Should -Invoke Start-Sleep -Times 2 -Exactly -Scope It
        }

        It 'finds a policy on a later page of the list' {
            Set-TenantInSync
            $fake.PageSize = 1
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'NoChange' }).Count | Should -Be $script:PolicyCount
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'POST' }
        }
    }

    Context 'Duplicate names in the tenant (R-57)' {

        It 'fails that policy, changes nothing for it, and still processes the others' {
            Set-TenantInSync
            $copy = Copy-TestValue -Value $fake.Tenant[0]
            $copy['id'] = 'cccccccc-0000-0000-0000-000000000001'
            $copy['state'] = 'enabled'
            $fake.Tenant.Add($copy)
            $fake.Tenant[1]['state'] = 'disabled'
            $name = $fake.Tenant[0]['displayName']

            $result = Invoke-Deploy
            $result.Threw | Should -BeTrue
            $row = $result.Output | Where-Object { $_.Policy -eq $name }
            $row.Action | Should -Be 'Failed'
            $row.Detail | Should -BeLike '*2 tenant policies are named*Nothing was changed*'
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -Scope It -ParameterFilter { $Method -eq 'PATCH' }
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter {
                $Method -eq 'PATCH' -and ($Uri -like '*/aaaaaaaa-0000-0000-0000-000000000001' -or $Uri -like '*/cccccccc-*')
            }
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'POST' }
        }
    }

    Context 'Never deletes (R-57)' {

        It 'reports a tenant LAB- policy with no definition and leaves it alone' {
            Set-TenantInSync
            $extra = Copy-TestValue -Value $fake.Tenant[0]
            $extra['id'] = 'dddddddd-0000-0000-0000-000000000001'
            $extra['displayName'] = 'LAB-999 Old policy'
            $fake.Tenant.Add($extra)

            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            ($result.Output | Where-Object { $_.Policy -eq 'LAB-999 Old policy' }).Action | Should -Be 'NotInRepo'
            Get-SummaryLine -Result $result | Should -BeLike '*1 LAB- in tenant not in repo*'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -notin 'GET' }
            $fake.Tenant.Count | Should -Be ($script:PolicyCount + 1)
        }
    }

    Context '-WhatIf (R-04, R-19)' {

        It 'reports would-create and makes no change' {
            $result = Invoke-Deploy -Parameters @{ WhatIf = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'WouldCreate' }).Count | Should -Be $script:PolicyCount
            Get-SummaryLine -Result $result | Should -BeLike "*$($script:PolicyCount) would create, 0 would update (WhatIf)*"
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -ne 'GET' }
        }

        It 'reports would-update with the changed keys and makes no change' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'enabled'
            $result = Invoke-Deploy -Parameters @{ WhatIf = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            $row = $result.Output | Where-Object { $_.Action -eq 'WouldUpdate' }
            @($row).Count | Should -Be 1
            $row.ChangedKeys | Should -Be 'state'
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Method -ne 'GET' }
            $fake.Tenant[0]['state'] | Should -Be 'enabled'
        }
    }

    Context 'Output (R-58)' {

        It 'never writes a group ID or policy ID to the output' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'enabled'
            $result = Invoke-Deploy
            $text = (@($result.Output | ForEach-Object { $_ | ConvertTo-Json -Compress }) + @($result.Information) + @($result.Error)) -join "`n"
            $text | Should -Not -BeLike "*$($script:EaId)*"
            $text | Should -Not -BeLike "*$($script:ItId)*"
            $text | Should -Not -BeLike '*aaaaaaaa-0000*'
        }
    }
}
