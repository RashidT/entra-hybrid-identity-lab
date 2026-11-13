<#
    Unit tests for Get-LabGraphCollection in scripts/GraphFederatedCommon.ps1 (R-53 paging).
    Invoke-MgGraphRequest is mocked, so these run in the GitHub Actions 'test' job with no Graph
    connection and no id-token permission (R-54).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -ChildPath 'GraphFederatedCommon.ps1')

    # Stand-in so Pester can mock the Graph command on a runner without Microsoft.Graph.
    if (-not (Get-Command -Name Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest {
            [CmdletBinding()]
            param([string] $Method, [string] $Uri, [object] $Body, [string] $ContentType, [string] $OutputType)
        }
        $script:StandIn = $true
    }
}

AfterAll {
    if ($script:StandIn) { Remove-Item -Path 'Function:\Invoke-MgGraphRequest' -ErrorAction SilentlyContinue }
}

Describe 'Get-LabGraphCollection (R-53)' {

    It 'returns every item of a single page' {
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'a' }, @{ id = 'b' }) } }
        $items = @(Get-LabGraphCollection -Uri 'v1.0/identity/conditionalAccess/policies')
        @($items.id) | Should -Be @('a', 'b')
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $OutputType -eq 'HashTable' }
    }

    It 'follows @odata.nextLink to the last page, in order' {
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'page2' } } -ParameterFilter { $Uri -eq 'start' }
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'b' }); '@odata.nextLink' = 'page3' } } -ParameterFilter { $Uri -eq 'page2' }
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'c' }) } } -ParameterFilter { $Uri -eq 'page3' }
        @((Get-LabGraphCollection -Uri 'start').id) | Should -Be @('a', 'b', 'c')
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
    }

    It 'returns nothing for an empty list' {
        Mock Invoke-MgGraphRequest { @{ value = @() } }
        @(Get-LabGraphCollection -Uri 'start').Count | Should -Be 0
    }

    It 'returns a one-item list as one hashtable' {
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'a'; displayName = 'LAB-001' }) } }
        $items = @(Get-LabGraphCollection -Uri 'start')
        $items.Count | Should -Be 1
        $items[0] | Should -BeOfType [System.Collections.IDictionary]
    }

    It 'stops after -MaxPage pages without printing the URI' {
        Mock Invoke-MgGraphRequest { @{ value = @(); '@odata.nextLink' = 'v1.0/groups/11111111-1111-1111-1111-111111111111/members?next' } }
        { Get-LabGraphCollection -Uri 'v1.0/groups/11111111-1111-1111-1111-111111111111/members' -MaxPage 3 } |
            Should -Throw -ExpectedMessage 'Graph list has more than 3 pages; stopped.'
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
    }
}
