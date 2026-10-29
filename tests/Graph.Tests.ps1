<#
    Graph tests: read tenant settings back through Microsoft Graph v1.0 and fail on drift.
    Read-only. They are tagged 'Graph' and skipped unless the session is connected to Graph with
    Policy.Read.All, so the GitHub Actions 'test' job reports them as skipped (R-54: that job is unchanged).

    Run locally:
        Connect-MgGraph -Scopes 'Policy.Read.All' -NoWelcome
        (Get-MgContext).Account
        Invoke-Pester -Path .\tests\Graph.Tests.ps1 -Tag Graph -Output Detailed
#>

BeforeDiscovery {
    $script:HaveGraph = $false
    if (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue) {
        $context = Get-MgContext
        $script:HaveGraph = [bool]($context -and ($context.Scopes -contains 'Policy.Read.All'))
    }
}

Describe 'R-69 external collaboration settings' -Tag 'Graph' -Skip:(-not $script:HaveGraph) {

    BeforeAll {
        # Built-in role template ID for Restricted Guest User. Microsoft-defined, the same in every tenant.
        $script:RestrictedGuestRoleId = '2af84b1e-32c8-42b7-82bc-daa82404023b'
        $script:Policy = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/policies/authorizationPolicy' -ErrorAction Stop
    }

    It 'lets only admins and the Guest Inviter role invite guests' {
        $script:Policy.allowInvitesFrom | Should -Be 'adminsAndGuestInviters' -Because 'R-69: members and guests must not invite'
    }

    It 'limits guests to their own directory object (Restricted Guest User)' {
        $script:Policy.guestUserRoleId | Should -Be $script:RestrictedGuestRoleId -Because 'R-69: guests see only their own object'
    }
}
