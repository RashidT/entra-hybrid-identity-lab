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
        # Calls records every Graph request as plain strings. Tests assert on Calls instead of using
        # -ParameterFilter on Body or Uri, which didn't match on the CI runner (Pester 6.2.0, Windows).
        $fake = @{
            Tenant       = New-Object -TypeName System.Collections.Generic.List[object]
            Calls        = New-Object -TypeName System.Collections.Generic.List[object]
            NextId       = 0
            PageSize     = 0
            PatchApplies = $true
            FailPostLike = ''
            Sleeps       = 0
        }

        Mock Get-MgContext { [pscustomobject]@{ Account = $null; AppName = 'lab-ca-deployer' } }
        Mock Start-Sleep { $fake.Sleeps++ }

        # The fake tenant. GET lists (with optional paging) or reads one; POST creates; PATCH replaces
        # each top-level key sent. Any other method fails the call.
        Mock Invoke-MgGraphRequest {
            $base = 'v1.0/identity/conditionalAccess/policies'
            $m = ([string]$Method).ToUpperInvariant()
            $u = [string]$Uri
            $b = ''
            if ($null -ne $Body) { $b = [string]$Body }
            $fake.Calls.Add([pscustomobject]@{ Method = $m; Uri = $u; Body = $b })

            switch ($m) {
                'GET' {
                    if ($u -eq $base -or $u.StartsWith("$base`?page=")) {
                        $all = @($fake.Tenant | ForEach-Object { Copy-TestValue -Value $_ })
                        if ($fake.PageSize -le 0) { return @{ value = $all } }
                        $start = 0
                        if ($u -match 'page=(\d+)') { $start = [int]$Matches[1] }
                        $page = @{ value = @($all | Select-Object -Skip $start -First $fake.PageSize) }
                        if ($start + $fake.PageSize -lt $all.Count) { $page['@odata.nextLink'] = "$base`?page=$($start + $fake.PageSize)" }
                        return $page
                    }
                    $id = $u.Substring($base.Length + 1)
                    $found = @($fake.Tenant | Where-Object { $_['id'] -eq $id })
                    if ($found.Count -ne 1) { throw 'Response status code does not indicate success: NotFound (Not Found).' }
                    return (Copy-TestValue -Value $found[0])
                }
                'POST' {
                    if ($fake.FailPostLike -and $b.Contains($fake.FailPostLike)) { throw 'Forbidden' }
                    $fake.NextId++
                    $policy = New-TenantPolicy -Definition ($b | ConvertFrom-Json -AsHashtable) -Id ('bbbbbbbb-0000-0000-0000-{0:d12}' -f $fake.NextId)
                    $fake.Tenant.Add($policy)
                    return (Copy-TestValue -Value $policy)
                }
                'PATCH' {
                    $id = $u.Substring($base.Length + 1)
                    $policy = @($fake.Tenant | Where-Object { $_['id'] -eq $id })[0]
                    if ($fake.PatchApplies) {
                        $patch = $b | ConvertFrom-Json -AsHashtable
                        foreach ($key in $patch.Keys) { $policy[$key] = $patch[$key] }
                    }
                    return $null
                }
                default { throw "Unexpected Graph method $m $u" }
            }
        }

        # The recorded calls for one method (GET, POST, PATCH), or every call that isn't a GET.
        function Get-FakeCall {
            param([string] $Method, [switch] $NotGet)
            if ($NotGet) { return @($fake.Calls | Where-Object { $_.Method -ne 'GET' }) }
            return @($fake.Calls | Where-Object { $_.Method -eq $Method })
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
            $fake.Calls.Count | Should -Be 0
        }

        It 'reports every bad file at once' {
            $one = (Get-CommittedJson -Name 'LAB-001.json') -replace 'enabledForReportingButNotEnforced', 'enabled'
            $two = '{ "displayName": '
            $dir = New-TestPolicyFolder -Files @{ 'LAB-001.json' = $one; 'LAB-002.json' = $two }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Error | Should -BeLike '*LAB-001.json*'
            $result.Error | Should -BeLike '*LAB-002.json*not valid JSON*'
            $fake.Calls.Count | Should -Be 0
        }

        It 'refuses two files with the same displayName' {
            $json = Get-CommittedJson -Name 'LAB-003.json'
            $dir = New-TestPolicyFolder -Files @{ 'LAB-003.json' = $json; 'LAB-003-copy.json' = $json }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '*used by more than one file*'
            $fake.Calls.Count | Should -Be 0
        }

        It 'refuses a group ID that is not a GUID, without printing the value' {
            $result = Invoke-Deploy -Parameters @{ ItSecurityGroupId = 'not-a-guid-value' }
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike "*'ItSecurityGroupId' is not a GUID*"
            $result.Error | Should -Not -BeLike '*not-a-guid-value*'
            $fake.Calls.Count | Should -Be 0
        }

        It 'stops when the folder has no LAB- definitions' {
            $dir = New-TestPolicyFolder -Files @{ 'README.txt' = 'nothing here' }
            $result = Invoke-Deploy -Parameters @{ PolicyPath = $dir }
            $result.Error | Should -BeLike '*No LAB-*.json*'
            $fake.Calls.Count | Should -Be 0
        }

        It 'stops when there is no Graph connection' {
            Mock Get-MgContext { $null }
            $result = Invoke-Deploy
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '*Not connected to Microsoft Graph*'
            $fake.Calls.Count | Should -Be 0
        }
    }

    Context 'Create (R-57)' {

        It 'creates every missing policy once, report-only, with the placeholders filled' {
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'Created' }).Count | Should -Be $script:PolicyCount
            $posts = Get-FakeCall -Method 'POST'
            $posts.Count | Should -Be $script:PolicyCount
            foreach ($post in $posts) {
                $body = $post.Body | ConvertFrom-Json -AsHashtable
                $body['state'] | Should -BeExactly 'enabledForReportingButNotEnforced'
                $body['conditions']['users']['excludeGroups'] | Should -Contain $script:EaId
                $post.Body.Contains('{{') | Should -BeFalse -Because 'every placeholder is filled (R-58)'
            }
        }

        It 'sends only the four definition keys when creating' {
            Invoke-Deploy | Out-Null
            $posts = Get-FakeCall -Method 'POST'
            $posts.Count | Should -Be $script:PolicyCount
            foreach ($post in $posts) {
                @(($post.Body | ConvertFrom-Json -AsHashtable).Keys | Sort-Object) -join ',' |
                    Should -Be 'conditions,displayName,grantControls,state'
            }
        }

        It 'reports a re-run as unchanged and makes no change (idempotent)' {
            Invoke-Deploy | Out-Null
            $before = (Get-FakeCall -NotGet).Count
            $second = Invoke-Deploy
            $second.Threw | Should -BeFalse -Because $second.Error
            @($second.Output | Where-Object { $_.Action -eq 'NoChange' }).Count | Should -Be $script:PolicyCount
            Get-SummaryLine -Result $second | Should -BeLike '*0 created, 0 updated*unchanged*0 failed*'
            (Get-FakeCall -NotGet).Count | Should -Be $before -Because 'the second run makes no change'
            (Get-FakeCall -Method 'POST').Count | Should -Be $script:PolicyCount
            (Get-FakeCall -Method 'PATCH').Count | Should -Be 0
        }

        It 'reads each new policy back before reporting Created (R-01)' {
            Invoke-Deploy | Out-Null
            $readBacks = @(Get-FakeCall -Method 'GET' | Where-Object { $_.Uri.StartsWith('v1.0/identity/conditionalAccess/policies/') })
            $readBacks.Count | Should -Be $script:PolicyCount
        }

        It 'carries on after one create fails, then ends with an error' {
            $fake.FailPostLike = 'LAB-002'
            $result = Invoke-Deploy
            $result.Threw | Should -BeTrue
            $result.Error | Should -BeLike '1 of * failed*'
            $row = $result.Output | Where-Object { $_.Policy -like 'LAB-002*' }
            $row.Action | Should -Be 'Failed'
            $row.Detail | Should -Be 'Forbidden'
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
            $patches = Get-FakeCall -Method 'PATCH'
            $patches.Count | Should -Be 1
            $patches[0].Uri | Should -BeExactly 'v1.0/identity/conditionalAccess/policies/aaaaaaaa-0000-0000-0000-000000000001'
            $body = $patches[0].Body | ConvertFrom-Json -AsHashtable
            @($body.Keys) -join ',' | Should -Be 'grantControls'
            $body['grantControls']['operator'] | Should -Be 'OR' -Because 'the changed key is sent whole (Option A)'
            $body['grantControls']['builtInControls'] | Should -Contain 'mfa'
            (Get-FakeCall -Method 'POST').Count | Should -Be 0
        }

        It 'puts a policy someone switched On back to report-only' {
            Set-TenantInSync
            $fake.Tenant[1]['state'] = 'enabled'
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            $patches = Get-FakeCall -Method 'PATCH'
            $patches.Count | Should -Be 1
            ($patches[0].Body | ConvertFrom-Json -AsHashtable)['state'] | Should -BeExactly 'enabledForReportingButNotEnforced'
            $fake.Tenant[1]['state'] | Should -BeExactly 'enabledForReportingButNotEnforced'
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
            (Get-FakeCall -NotGet).Count | Should -Be 0
        }

        It 'reports Failed when the read-back still differs after the retries' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'disabled'
            $fake.PatchApplies = $false
            $result = Invoke-Deploy -Parameters @{ ReadBackAttempts = 3 }
            $result.Threw | Should -BeTrue
            $row = $result.Output | Where-Object { $_.Action -eq 'Failed' }
            @($row).Count | Should -Be 1
            $row.Detail | Should -BeLike '*read-back still differs in: state*'
            $fake.Sleeps | Should -Be 2 -Because 'three attempts wait twice'
        }

        It 'finds a policy on a later page of the list' {
            Set-TenantInSync
            $fake.PageSize = 1
            $result = Invoke-Deploy
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'NoChange' }).Count | Should -Be $script:PolicyCount
            (Get-FakeCall -NotGet).Count | Should -Be 0
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
            $patches = Get-FakeCall -Method 'PATCH'
            $patches.Count | Should -Be 1 -Because 'only the other drifted policy is updated'
            $patches[0].Uri | Should -BeExactly 'v1.0/identity/conditionalAccess/policies/aaaaaaaa-0000-0000-0000-000000000002'
            (Get-FakeCall -Method 'POST').Count | Should -Be 0
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
            (Get-FakeCall -NotGet).Count | Should -Be 0
            $fake.Tenant.Count | Should -Be ($script:PolicyCount + 1)
        }
    }

    Context '-WhatIf (R-04, R-19)' {

        It 'reports would-create and makes no change' {
            $result = Invoke-Deploy -Parameters @{ WhatIf = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            @($result.Output | Where-Object { $_.Action -eq 'WouldCreate' }).Count | Should -Be $script:PolicyCount
            Get-SummaryLine -Result $result | Should -BeLike "*$($script:PolicyCount) would create, 0 would update (WhatIf)*"
            (Get-FakeCall -NotGet).Count | Should -Be 0
        }

        It 'reports would-update with the changed keys and makes no change' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'enabled'
            $result = Invoke-Deploy -Parameters @{ WhatIf = $true }
            $result.Threw | Should -BeFalse -Because $result.Error
            $row = $result.Output | Where-Object { $_.Action -eq 'WouldUpdate' }
            @($row).Count | Should -Be 1
            $row.ChangedKeys | Should -Be 'state'
            (Get-FakeCall -NotGet).Count | Should -Be 0
            $fake.Tenant[0]['state'] | Should -Be 'enabled'
        }
    }

    Context 'Output (R-58)' {

        It 'never writes a group ID or policy ID to the output' {
            Set-TenantInSync
            $fake.Tenant[0]['state'] = 'enabled'
            $result = Invoke-Deploy
            $text = (@($result.Output | ForEach-Object { $_ | ConvertTo-Json -Compress }) + @($result.Information) + @($result.Error)) -join "`n"
            $text.Contains($script:EaId) | Should -BeFalse
            $text.Contains($script:ItId) | Should -BeFalse
            $text.Contains('aaaaaaaa-0000') | Should -BeFalse
        }
    }
}
