<#
    R-74 gap (R-58): no tenant-specific values in any tracked text file, not just policies/.
      - no <label>.onmicrosoft.com except <tenant> and Microsoft's documentation example (contoso)
      - no GUID that isn't in data/guid-allowlist.csv, where every entry is labelled
    Generic rules only: the real domain, tenant ID and object IDs never appear here, in the rules or
    in the allow list. Planted bad values are built at run time, so this file passes its own scan.
    Screenshots (PNG) can't be scanned as text: they stay a manual check.
    No Graph connection is needed, so these run in the GitHub Actions 'test' job.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scripts') -ChildPath 'RepoScanCommon.ps1')

    $script:AllowListRelative = 'data/guid-allowlist.csv'
    $script:GitleaksRelative = '.gitleaks.toml'
    $script:AllowList = @(Import-Csv -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath $script:AllowListRelative))
    $script:AllowedGuid = [string[]]@($script:AllowList | ForEach-Object { $_.Id })

    $script:Files = @(Get-LabRepoScanFile -RepoRoot $script:RepoRoot)
    $script:TextFiles = @($script:Files | Where-Object { $_.IsText })
    $script:RequirementsText = Get-Content -LiteralPath (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'docs') -ChildPath 'REQUIREMENTS.md') -Raw
    $script:GitleaksText = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath $script:GitleaksRelative) -Raw

    # A GUID and a domain that must be flagged, built so neither appears in this file as written.
    $script:BadGuid = @('0e0e0e0e', '5678', '4bcd', '8eef', '111111111111') -join '-'
    $script:BadDomain = 'fabrikam' + '.onmicrosoft.com'
}

Describe 'R-74 whole-repo scan of the current files' {

    It 'lists the tracked files with git when running in GitHub Actions' -Skip:($env:GITHUB_ACTIONS -ne 'true') {
        @($script:Files | Where-Object { $_.Source -ne 'git' }).Count | Should -Be 0
    }

    It 'includes docs, Markdown, data and dot-folders in the scan' {
        $paths = @($script:TextFiles | ForEach-Object { $_.Path })
        foreach ($expected in @('README.md', 'docs/REQUIREMENTS.md', 'data/users.csv', '.github/workflows/pester-tests.yml', $script:GitleaksRelative)) {
            $paths | Should -Contain $expected
        }
    }

    It 'skips only PNG files as binary' {
        $skipped = @($script:Files | Where-Object { -not $_.IsText -and $_.Path -notlike '*.png' } | ForEach-Object { $_.Path })
        $skipped.Count | Should -Be 0 -Because "binary files that aren't PNG: $($skipped -join ', ')"
    }

    It 'finds no onmicrosoft.com domain other than <tenant> and no GUID off the allow list' {
        $findings = foreach ($file in $script:TextFiles) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($finding in @(Get-LabRepoScanFinding -Text $text -AllowedGuid $script:AllowedGuid)) {
                "$($file.Path) line $($finding.Line): $($finding.Message)"
            }
        }
        @($findings).Count | Should -Be 0 -Because ($findings -join '; ')
    }
}

Describe 'R-74 GUID allow list' {

    It 'has the columns Id, Label, Category, Requirement' {
        $script:AllowList[0].PSObject.Properties.Name | Should -Be @('Id', 'Label', 'Category', 'Requirement')
    }

    It 'has a lowercase GUID, a label, a known category and a requirement on every row' {
        foreach ($row in $script:AllowList) {
            $row.Id | Should -MatchExactly '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            $row.Label | Should -Not -BeNullOrEmpty
            $row.Category | Should -BeIn @('RoleTemplate', 'GuestRole', 'Aaguid', 'TestFixture')
            $row.Requirement | Should -Match '^(R|P)-\d{2}$'
        }
    }

    It 'lists each GUID once' {
        $duplicates = @($script:AllowList | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $duplicates.Count | Should -Be 0 -Because "listed more than once: $($duplicates -join ', ')"
    }

    It 'lists the 22 R-59 role template IDs' {
        @($script:AllowList | Where-Object { $_.Category -eq 'RoleTemplate' }).Count | Should -Be 22
    }

    It 'has every ID that is not a test fixture in docs/REQUIREMENTS.md' {
        $missing = @($script:AllowList | Where-Object { $_.Category -ne 'TestFixture' -and -not $script:RequirementsText.Contains("``$($_.Id)``") } | ForEach-Object { $_.Id })
        $missing.Count | Should -Be 0 -Because "not in REQUIREMENTS.md: $($missing -join ', ')"
    }

    It 'has no stale entries: every ID is used in a file other than the allow lists' {
        $used = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in ($script:TextFiles | Where-Object { $_.Path -notin @($script:AllowListRelative, $script:GitleaksRelative) })) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($match in [regex]::Matches($text, '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')) {
                [void]$used.Add($match.Value)
            }
        }
        $stale = @($script:AllowedGuid | Where-Object { -not $used.Contains($_) })
        $stale.Count | Should -Be 0 -Because "not used anywhere: $($stale -join ', ')"
    }

    It 'matches the GUID allow list in .gitleaks.toml exactly' {
        $gitleaksIds = @([regex]::Matches($script:GitleaksText, '\^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\$') | ForEach-Object { $_.Groups[1].Value })
        $difference = @(Compare-Object -ReferenceObject @($script:AllowedGuid | Sort-Object) -DifferenceObject @($gitleaksIds | Sort-Object))
        $difference.Count | Should -Be 0 -Because "differ between the CSV and .gitleaks.toml: $(($difference | ForEach-Object { "$($_.InputObject) $($_.SideIndicator)" }) -join ', ')"
    }
}

Describe 'R-74 scan rules catch bad values' {

    It 'passes <tenant>, a bare suffix, a wildcard and the documentation example in any case' {
        $text = "user@<tenant>.onmicrosoft.com`nthe tenant's .onmicrosoft.com suffix`nany *.onmicrosoft.com`nadmin@Contoso.OnMicrosoft.com"
        @(Get-LabRepoScanFinding -Text $text -AllowedGuid $script:AllowedGuid).Count | Should -Be 0
    }

    It 'flags another onmicrosoft.com domain in any case, with its line, without printing it' {
        $text = "first line`nuser@" + $script:BadDomain.ToUpperInvariant()
        $findings = @(Get-LabRepoScanFinding -Text $text -AllowedGuid $script:AllowedGuid)
        $findings.Count | Should -Be 1
        $findings[0].Rule | Should -Be 'Domain'
        $findings[0].Line | Should -Be 2
        $findings[0].Message | Should -Not -BeLike '*fabrikam*'
    }

    It 'flags a domain after an underscore or a URL-encoded @' {
        foreach ($prefix in @('x_', 'user%40')) {
            @(Get-LabRepoScanFinding -Text ($prefix + $script:BadDomain) -AllowedGuid $script:AllowedGuid).Count | Should -Be 1
        }
    }

    It 'passes an allow-listed GUID in upper case' {
        @(Get-LabRepoScanFinding -Text '62E90394-69F5-4237-9190-012177145E10' -AllowedGuid $script:AllowedGuid).Count | Should -Be 0
    }

    It 'flags a GUID off the allow list in upper case or next to other characters, without printing it' -ForEach @(
        @{ Case = 'upper case' ; Prefix = ''; Upper = $true }
        @{ Case = 'after an underscore'; Prefix = 'id_'; Upper = $false }
        @{ Case = 'after a hex digit'; Prefix = 'a'; Upper = $false }
    ) {
        $guid = if ($Upper) { $script:BadGuid.ToUpperInvariant() } else { $script:BadGuid }
        $findings = @(Get-LabRepoScanFinding -Text ($Prefix + $guid) -AllowedGuid $script:AllowedGuid)
        $findings.Count | Should -Be 1 -Because $Case
        $findings[0].Rule | Should -Be 'Guid'
        $findings[0].Message | Should -Not -BeLike '*0e0e0e0e*'
    }

    It 'reports every bad GUID with its own line' {
        $text = "$($script:BadGuid)`nfine`n$($script:BadGuid)"
        $findings = @(Get-LabRepoScanFinding -Text $text -AllowedGuid $script:AllowedGuid)
        $findings.Line | Should -Be @(1, 3)
    }

    It 'flags every GUID when the allow list is empty' {
        @(Get-LabRepoScanFinding -Text '62e90394-69f5-4237-9190-012177145e10' -AllowedGuid @()).Count | Should -Be 1
    }
}

Describe 'R-74 file listing' {

    It 'falls back to the file system outside a repository, skipping .git and marking NUL files as binary' {
        $root = Join-Path -Path $TestDrive -ChildPath 'scan'
        New-Item -Path (Join-Path -Path $root -ChildPath '.git') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'notes.md') -Value 'plain text'
        Set-Content -LiteralPath (Join-Path -Path (Join-Path -Path $root -ChildPath '.git') -ChildPath 'config') -Value 'not scanned'
        [System.IO.File]::WriteAllBytes((Join-Path -Path $root -ChildPath 'image.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 0x00, 0x01))

        # A folder that isn't a repository makes git ls-files fail, so the file system is listed.
        # Not run when TestDrive is inside a repository, where git would list nothing.
        & git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Set-ItResult -Skipped -Because 'TestDrive is inside a git repository'
            return
        }

        $files = @(Get-LabRepoScanFile -RepoRoot $root)
        ($files | ForEach-Object { $_.Path }) | Should -Be @('image.png', 'notes.md')
        ($files | Where-Object { $_.Path -eq 'notes.md' }).IsText | Should -BeTrue
        ($files | Where-Object { $_.Path -eq 'image.png' }).IsText | Should -BeFalse
        $files[0].Source | Should -Be 'filesystem'
    }
}
