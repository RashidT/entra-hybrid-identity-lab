<#
    R-53 read-back: every LAB- policy in the tenant matches its file in policies/, and EmergencyAccess
    has exactly the expected members. Read-only. Tagged 'Graph' and 'CAReadback'.

    In CI (graph-tests), 'CAReadback' is excluded until the repository variable LAB_TRIAL_ACTIVE is
    'true' (D2), so before T these tests are left out, not skipped. Like the other Graph tests, they
    skip themselves when the session has no Graph connection with Policy.Read.All, so the 'test'
    job reports them as skipped (R-54).

    Needs these environment variables (repository secrets in CI, from T: D6, D8). The values are
    object IDs; nothing here prints them (R-58):
        EMERGENCY_ACCESS_GROUP_ID     EmergencyAccess object ID
        IT_SECURITY_GROUP_ID          IT-Security-Group object ID (synced)
        EMERGENCY_ACCESS_MEMBER_IDS   the two break-glass object IDs, comma-separated

    Run locally (Policy.Read.All and GroupMember.ReadBasic.All, delegated):
        Connect-MgGraph -Scopes 'Policy.Read.All', 'GroupMember.ReadBasic.All' -NoWelcome
        (Get-MgContext).Account
        $env:EMERGENCY_ACCESS_GROUP_ID = '<object ID>'   # and the other two
        Invoke-Pester -Path .\tests\ConditionalAccessReadback.Tests.ps1 -Tag CAReadback -Output Detailed
#>

BeforeDiscovery {
    $script:HaveGraph = $false
    if (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue) {
        $context = Get-MgContext
        $script:HaveGraph = [bool]($context -and ($context.Scopes -contains 'Policy.Read.All'))
    }

    $script:FindingTypes = @(
        @{ Type = 'Missing' }
        @{ Type = 'Duplicate' }
        @{ Type = 'NotReportOnly' }
        @{ Type = 'Drift' }
        @{ Type = 'Unexpected' }
    )
}

Describe 'R-53 Conditional Access read-back' -Tag 'Graph', 'CAReadback' -Skip:(-not $script:HaveGraph) {

    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scripts = Join-Path -Path $repoRoot -ChildPath 'scripts'
        . (Join-Path -Path $scripts -ChildPath 'ConditionalAccessCommon.ps1')
        . (Join-Path -Path $scripts -ChildPath 'GraphFederatedCommon.ps1')

        # A missing value fails the run: once these tests are included, they must not pass on nothing.
        foreach ($name in 'EMERGENCY_ACCESS_GROUP_ID', 'IT_SECURITY_GROUP_ID', 'EMERGENCY_ACCESS_MEMBER_IDS') {
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                throw "Environment variable $name is not set (R-53, D6, D8)."
            }
        }
        $values = @{
            EmergencyAccessGroupId = $env:EMERGENCY_ACCESS_GROUP_ID
            ItSecurityGroupId      = $env:IT_SECURITY_GROUP_ID
        }

        $files = @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'policies') -Filter 'LAB-*.json' -File | Sort-Object -Property Name)
        if ($files.Count -eq 0) { throw 'No LAB- policy files in policies/.' }
        $script:Definitions = @(foreach ($file in $files) {
                Resolve-LabPolicyPlaceholder -Definition (Read-LabPolicyDefinition -Path $file.FullName) -Value $values
            })

        $script:TenantPolicies = @(Get-LabGraphCollection -Uri 'v1.0/identity/conditionalAccess/policies')
        $script:PolicyFindings = @(Get-LabPolicyReadbackFinding -Definition $script:Definitions -TenantPolicy $script:TenantPolicies)

        $members = @(Get-LabGraphCollection -Uri "v1.0/groups/$($env:EMERGENCY_ACCESS_GROUP_ID)/members")
        $expected = @($env:EMERGENCY_ACCESS_MEMBER_IDS -split ',')
        $script:MemberFindings = @(Get-LabGroupMemberFinding -Member $members -ExpectedId $expected)

        function Format-Finding {
            param([object[]] $Finding)
            return (@($Finding | ForEach-Object { "$($_.Name)$(if ($_.Key) { " [$($_.Key)]" }): $($_.Message)" }) -join '; ')
        }
    }

    It 'reads the LAB- definitions and the tenant policy list' {
        $script:Definitions.Count | Should -BeGreaterThan 0
        Write-Information -MessageData "Definitions: $($script:Definitions.Count); tenant policies: $($script:TenantPolicies.Count)" -InformationAction Continue
    }

    It 'has no <Type> findings' -ForEach $script:FindingTypes {
        $found = @($script:PolicyFindings | Where-Object { $_.Type -ceq $Type })
        $found.Count | Should -Be 0 -Because (Format-Finding -Finding $found)
    }

    It 'EmergencyAccess has exactly the expected members, all users' {
        $script:MemberFindings.Count | Should -Be 0 -Because (Format-Finding -Finding $script:MemberFindings)
    }
}
