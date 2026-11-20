<#
.SYNOPSIS
    Whole-repo scan for tenant-specific values (R-74 gap, R-58).
.DESCRIPTION
    Used by tests/RepoScan.Tests.ps1 in the GitHub Actions 'test' job. Generic rules only (R-74,
    agreed with entra-auth-baseline): the real domain, tenant ID and object IDs never appear in a
    rule, a test or the allow list, because committing them would publish them.
      - Domain: any <label>.onmicrosoft.com is a finding unless the label is a documentation example
        (Get-LabRepoScanAllowedDomainLabel). '<tenant>.onmicrosoft.com' never matches, because '>'
        can't be part of a domain label.
      - Guid: any GUID is a finding unless it is in data/guid-allowlist.csv.
    Findings give the line number and the rule, never the matched value, so a red run's log
    doesn't publish what it found.
    Dot-source with:
        . (Join-Path -Path $PSScriptRoot -ChildPath 'RepoScanCommon.ps1')
    No Graph or Active Directory calls, so everything here is unit tested on any machine.
#>

function Get-LabRepoScanAllowedDomainLabel {
    <#
    .SYNOPSIS
        Domain labels allowed before .onmicrosoft.com: Microsoft's documentation example tenant.
        Used in script help and unit tests; never a real tenant here.
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param()

    return [string[]]@('contoso')
}

function Get-LabRepoScanFile {
    <#
    .SYNOPSIS
        Every file to scan, with whether it is text.
    .DESCRIPTION
        Lists tracked files with 'git ls-files', so ignored local files (raw evidence) are never read.
        If git or the repository isn't there (a copy unpacked from a zip, or a test folder), every file
        under the folder is listed instead, except .git. Source says which was used.
        A file is text if its first 8000 bytes hold no NUL byte (the same test git uses).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    $root = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $source = 'filesystem'
    $relativePaths = @()

    if (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue) {
        $listing = & git -C $root ls-files -z 2>$null
        if ($LASTEXITCODE -eq 0) {
            $source = 'git'
            $relativePaths = @(($listing -join '') -split "`0" | Where-Object { $_ })
        }
    }

    if ($source -eq 'filesystem') {
        $relativePaths = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object {
                [System.IO.Path]::GetRelativePath($root, $_.FullName) -replace '\\', '/'
            } | Where-Object { $_ -notmatch '(^|/)\.git(/|$)' })
    }

    foreach ($relativePath in ($relativePaths | Sort-Object)) {
        $fullName = Join-Path -Path $root -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullName -PathType Leaf)) {
            continue    # tracked but deleted in the working tree
        }

        $isText = $true
        $stream = [System.IO.File]::OpenRead($fullName)
        try {
            $buffer = New-Object -TypeName byte[] -ArgumentList 8000
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ([System.Array]::IndexOf($buffer, [byte]0, 0, $read) -ge 0) {
                $isText = $false
            }
        }
        finally {
            $stream.Dispose()
        }

        [pscustomobject]@{
            Path     = $relativePath
            FullName = $fullName
            IsText   = $isText
            Source   = $source
        }
    }
}

function Get-LabRepoScanFinding {
    <#
    .SYNOPSIS
        Every Domain and Guid finding in one file's text. No output means it passed.
    .DESCRIPTION
        Each finding has Line, Rule and Message. The matched value is never included.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $AllowedGuid
    )

    $allowed = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $AllowedGuid) {
        [void]$allowed.Add($id)
    }
    $allowedLabels = Get-LabRepoScanAllowedDomainLabel

    # Line number of a match: newlines before its index, plus one.
    $lineOf = {
        param([int] $Index)
        return ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count + 1
    }

    # Domain labels are letters, digits and hyphens. '<tenant>' and a bare '.onmicrosoft.com' don't match.
    foreach ($match in [regex]::Matches($Text, '(?i)(?<![a-z0-9-])([a-z0-9-]+)\.onmicrosoft\.com')) {
        if ($allowedLabels -notcontains $match.Groups[1].Value.ToLowerInvariant()) {
            [pscustomobject]@{
                Line    = & $lineOf $match.Index
                Rule    = 'Domain'
                Message = 'onmicrosoft.com domain other than <tenant>'
            }
        }
    }

    # No word boundaries, so a GUID next to an underscore, a letter or a digit is still found.
    $guidPattern = '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    foreach ($match in [regex]::Matches($Text, $guidPattern)) {
        if (-not $allowed.Contains($match.Value)) {
            [pscustomobject]@{
                Line    = & $lineOf $match.Index
                Rule    = 'Guid'
                Message = 'GUID not in data/guid-allowlist.csv'
            }
        }
    }
}
