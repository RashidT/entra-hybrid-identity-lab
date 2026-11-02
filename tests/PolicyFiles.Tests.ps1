<#
    R-58: no tenant-specific values in policies/. Reads every file in the folder as text, so a value
    can't hide in a key, a comment or a file with another name or extension.
      - no onmicrosoft.com domain (any case)
      - no GUID except the built-in role template IDs listed under R-59
      - no placeholder except {{EmergencyAccessGroupId}} and {{ItSecurityGroupId}}
    No Graph connection is needed, so these run in the GitHub Actions 'test' job.
#>

BeforeDiscovery {
    $policiesDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'policies'
    $script:PolicyFiles = @(Get-ChildItem -LiteralPath $policiesDir -File -Recurse | ForEach-Object {
            @{ Name = $_.Name; Path = $_.FullName }
        })
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:PoliciesDir = Join-Path -Path $repoRoot -ChildPath 'policies'
    $script:RequirementsText = Get-Content -LiteralPath (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'docs') -ChildPath 'REQUIREMENTS.md') -Raw

    # R-59: Microsoft's built-in role template IDs, the same in every tenant (R-58 exception).
    # 21 included by LAB-001, plus Directory Synchronization Accounts excluded by LAB-002.
    $script:AllowedRoleIds = @{
        '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
        'c4e39bd9-1100-46d3-8c65-fb160da0071f' = 'Authentication Administrator'
        'b0f54661-2d74-4c50-afa3-1ec803f12efe' = 'Billing Administrator'
        '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
        'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' = 'Conditional Access Administrator'
        '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
        '729827e3-9c14-49f7-bb1b-9608f156bbb8' = 'Helpdesk Administrator'
        '966707d0-3269-4727-9be2-8c3a10f19b9d' = 'Password Administrator'
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' = 'Privileged Authentication Administrator'
        'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
        '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
        'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
        '0526716b-113d-4c15-b2c8-68e3c22b9f80' = 'Authentication Policy Administrator'
        'cf1c38e5-3621-4004-a7cb-879624dced7c' = 'Application Developer'
        '4a5d8f65-41da-4de4-8968-e035b65339cf' = 'Reports Reader'
        '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2' = 'Hybrid Identity Administrator'
        '95e79109-95c0-4d8e-aee3-d01accf2d47b' = 'Guest Inviter'
        '45d8d3c5-c802-45c6-b32a-1d70b5e1e86e' = 'Identity Governance Administrator'
        '5d6b6bb7-de71-4623-b4af-96380a352509' = 'Security Reader'
        'd29b2b05-8046-44ba-8758-1e26182fcf32' = 'Directory Synchronization Accounts'
    }
    $script:AllowedPlaceholders = @('EmergencyAccessGroupId', 'ItSecurityGroupId')

    # Every R-58 problem in one file's text. No output means it passed.
    function Get-PolicyFileProblem {
        param([string] $Text)
        $problems = New-Object -TypeName System.Collections.Generic.List[string]

        if ($Text -match '(?i)onmicrosoft\.com') {
            $problems.Add('contains an onmicrosoft.com domain')
        }

        $guidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        foreach ($match in [regex]::Matches($Text, $guidPattern)) {
            if (-not $script:AllowedRoleIds.ContainsKey($match.Value.ToLowerInvariant())) {
                # The value isn't printed: it may be a real tenant ID.
                $problems.Add("GUID at offset $($match.Index) is not an R-59 role template ID")
            }
        }

        foreach ($match in [regex]::Matches($Text, '\{\{([^{}]*)\}\}')) {
            if ($script:AllowedPlaceholders -cnotcontains $match.Groups[1].Value) {
                $problems.Add("placeholder '$($match.Value)' is not allowed")
            }
        }
        $stray = [regex]::Replace($Text, '\{\{[^{}]*\}\}', '')
        if ($stray.Contains('{{') -or $stray.Contains('}}')) {
            $problems.Add('has an unclosed {{ or }}')
        }

        return [string[]]$problems.ToArray()
    }
}

Describe 'R-58 policy files hold no tenant-specific values' {

    It 'finds the policy files (listed again at run time)' {
        @(Get-ChildItem -LiteralPath $script:PoliciesDir -Filter 'LAB-*.json' -File).Count | Should -BeGreaterThan 0
    }

    It '<Name> has no domain, unknown GUID or unknown placeholder' -ForEach $script:PolicyFiles {
        $problems = @(Get-PolicyFileProblem -Text (Get-Content -LiteralPath $Path -Raw))
        $problems.Count | Should -Be 0 -Because ($problems -join '; ')
    }
}

Describe 'R-58 allow list' {

    It 'lists 22 role template IDs (21 for LAB-001, one excluded by LAB-002)' {
        $script:AllowedRoleIds.Count | Should -Be 22
    }

    It 'matches the R-59 table: every allowed ID is in docs/REQUIREMENTS.md' {
        $missing = @($script:AllowedRoleIds.Keys | Where-Object { -not $script:RequirementsText.Contains("``$_``") })
        $missing.Count | Should -Be 0 -Because "not in REQUIREMENTS.md: $($missing -join ', ')"
    }
}

Describe 'R-58 checker catches bad values' {

    It 'passes the allowed values, in any GUID case' {
        $text = '{ "includeRoles": ["62E90394-69F5-4237-9190-012177145E10"], "excludeGroups": ["{{EmergencyAccessGroupId}}"], "includeGroups": ["{{ItSecurityGroupId}}"] }'
        @(Get-PolicyFileProblem -Text $text).Count | Should -Be 0
    }

    It 'flags an onmicrosoft.com domain in any case' {
        Get-PolicyFileProblem -Text '{ "x": "admin@<tenant>.OnMicrosoft.COM" }' | Should -Contain 'contains an onmicrosoft.com domain'
    }

    It 'flags a GUID that is not a role template ID, without printing it' {
        $problems = @(Get-PolicyFileProblem -Text '{ "excludeGroups": ["0f0f0f0f-1234-4abc-9def-000000000000"] }')
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike '*not an R-59 role template ID*'
        $problems[0] | Should -Not -BeLike '*0f0f0f0f*'
    }

    It 'flags an unknown placeholder, and the right name in the wrong case' -ForEach @(
        @{ Text = '{ "x": "{{TenantId}}" }' }
        @{ Text = '{ "x": "{{emergencyAccessGroupId}}" }' }
    ) {
        Get-PolicyFileProblem -Text $Text | Should -BeLike "*placeholder*is not allowed*"
    }

    It 'flags an unclosed placeholder' {
        Get-PolicyFileProblem -Text '{ "x": "{{EmergencyAccessGroupId}" }' | Should -Contain 'has an unclosed {{ or }}'
    }
}
