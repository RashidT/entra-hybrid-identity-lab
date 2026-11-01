<#
.SYNOPSIS
    Shared helpers for the Conditional Access policy definitions in policies/*.json.
.DESCRIPTION
    Used by 07-Deploy-ConditionalAccessPolicies.ps1 (R-52, R-57, R-58) and by the Graph tests (R-53),
    so the deploy script and the drift tests apply the same rules. Dot-source with:
        . (Join-Path -Path $PSScriptRoot -ChildPath 'ConditionalAccessCommon.ps1')
    Kept separate from LabCommon.ps1 so the Active Directory scripts never load policy code.
    None of these functions call Microsoft Graph, so they are unit tested on any machine.
    Needs PowerShell 7 (ConvertFrom-Json -AsHashtable).
#>

function Get-LabPolicyAllowedKey {
    <#
    .SYNOPSIS
        The only top-level keys a policy definition may hold (R-52).
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param()

    return [string[]]@('displayName', 'state', 'conditions', 'grantControls')
}

function Get-LabPolicyPlaceholderName {
    <#
    .SYNOPSIS
        The only placeholders a policy definition may use (R-58).
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param()

    return [string[]]@('EmergencyAccessGroupId', 'ItSecurityGroupId')
}

function Read-LabPolicyDefinition {
    <#
    .SYNOPSIS
        Reads one policy definition file and returns it as a hashtable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Policy definition not found: $Path"
    }

    try {
        $definition = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Policy definition is not valid JSON: $Path. $($_.Exception.Message)"
    }

    if ($definition -isnot [System.Collections.IDictionary]) {
        throw "Policy definition must be a JSON object: $Path"
    }
    return $definition
}

function Test-LabPolicyDefinition {
    <#
    .SYNOPSIS
        Returns every reason a definition must not be deployed. No output means it passed.
    .DESCRIPTION
        R-52: only the four allowed keys; state is report-only; the display name starts with LAB-;
        the emergency access group is excluded. Run it on the file as committed (the default
        -EmergencyAccessGroupId is the placeholder) and again on the filled-in body with the real ID.
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Definition,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string] $EmergencyAccessGroupId = '{{EmergencyAccessGroupId}}'
    )

    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    $allowed = Get-LabPolicyAllowedKey

    foreach ($key in $Definition.Keys) {
        if ($allowed -cnotcontains $key) {
            $problems.Add("${Name}: key '$key' is not allowed. Only $($allowed -join ', ').")
        }
    }
    foreach ($key in $allowed) {
        if (-not $Definition.Contains($key)) {
            $problems.Add("${Name}: required key '$key' is missing.")
        }
    }

    if ($Definition['state'] -cne 'enabledForReportingButNotEnforced') {
        $problems.Add("${Name}: state is '$($Definition['state'])'. Only 'enabledForReportingButNotEnforced' (report-only) is allowed.")
    }

    if (-not ([string]$Definition['displayName']).StartsWith('LAB-', [System.StringComparison]::Ordinal)) {
        $problems.Add("${Name}: displayName must start with 'LAB-'.")
    }

    $excludeGroups = @()
    $conditions = $Definition['conditions']
    if ($conditions -is [System.Collections.IDictionary] -and $conditions['users'] -is [System.Collections.IDictionary]) {
        $excludeGroups = @($conditions['users']['excludeGroups'])
    }
    if ($excludeGroups -notcontains $EmergencyAccessGroupId) {
        $problems.Add("${Name}: conditions.users.excludeGroups must contain the emergency access group ($EmergencyAccessGroupId).")
    }

    return [string[]]$problems.ToArray()
}

function Resolve-LabPolicyPlaceholder {
    <#
    .SYNOPSIS
        Returns a copy of the definition with each {{Name}} placeholder replaced by its object ID.
    .DESCRIPTION
        R-58: only the named placeholders are accepted, each value must be a GUID, and the copy must
        have no placeholder left. The original definition is not changed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Definition,

        [Parameter(Mandatory = $true)]
        [hashtable] $Value
    )

    $known = Get-LabPolicyPlaceholderName
    foreach ($name in $Value.Keys) {
        if ($known -cnotcontains $name) {
            throw "Unknown placeholder '$name'. Only $($known -join ', ')."
        }
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse([string]$Value[$name], [ref]$parsed)) {
            throw "Value for placeholder '$name' is not a GUID."
        }
    }

    $json = $Definition | ConvertTo-Json -Depth 20
    $json = [regex]::Replace($json, '\{\{(\w+)\}\}', {
            param($match)
            $name = $match.Groups[1].Value
            if ($known -ccontains $name -and $Value.ContainsKey($name)) { return [string]$Value[$name] }
            return $match.Value
        })

    $left = @([regex]::Matches($json, '\{\{[^}]*\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($left.Count -gt 0) {
        throw "Placeholder(s) not filled: $($left -join ', ')."
    }

    return ($json | ConvertFrom-Json -AsHashtable)
}

function Compare-LabPolicyValue {
    <#
    .SYNOPSIS
        True when the actual value matches the expected value under the R-53 comparison rule.
    .DESCRIPTION
        Objects: only the keys in Expected are compared, recursively; extra keys in Actual are ignored.
        Arrays: compared as sets (order ignored, same number of items). An expected empty array
        matches a null. Strings are compared ignoring case, so a GUID in upper or lower case matches.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object] $Expected,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object] $Actual
    )

    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Expected.Keys) {
            $actualValue = $null
            if ($Actual.Contains($key)) { $actualValue = $Actual[$key] }
            if (-not (Compare-LabPolicyValue -Expected $Expected[$key] -Actual $actualValue)) { return $false }
        }
        return $true
    }

    if ($Expected -is [System.Collections.IEnumerable] -and $Expected -isnot [string]) {
        $expectedItems = @($Expected)
        if ($null -eq $Actual) { return ($expectedItems.Count -eq 0) }
        if ($Actual -is [string] -or $Actual -is [System.Collections.IDictionary] -or $Actual -isnot [System.Collections.IEnumerable]) {
            return $false
        }
        $remaining = New-Object -TypeName System.Collections.Generic.List[object]
        foreach ($item in $Actual) { $remaining.Add($item) }
        if ($expectedItems.Count -ne $remaining.Count) { return $false }
        foreach ($item in $expectedItems) {
            $index = -1
            for ($i = 0; $i -lt $remaining.Count; $i++) {
                if (Compare-LabPolicyValue -Expected $item -Actual $remaining[$i]) { $index = $i; break }
            }
            if ($index -lt 0) { return $false }
            $remaining.RemoveAt($index)
        }
        return $true
    }

    if ($null -eq $Expected) { return ($null -eq $Actual) }
    if ($null -eq $Actual) { return $false }
    if ($Actual -is [System.Collections.IEnumerable] -and $Actual -isnot [string]) { return $false }
    return ([string]$Expected -eq [string]$Actual)
}

function Get-LabPolicyDifference {
    <#
    .SYNOPSIS
        Names of the top-level definition keys whose value differs in the tenant (R-57).
    .DESCRIPTION
        No output means the tenant policy matches the definition. Pass -Actual $null for a policy
        that does not exist yet, and every key is reported.
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Definition,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Collections.IDictionary] $Actual
    )

    $changed = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($key in $Definition.Keys) {
        $actualValue = $null
        if ($null -ne $Actual -and $Actual.Contains($key)) { $actualValue = $Actual[$key] }
        if (-not (Compare-LabPolicyValue -Expected $Definition[$key] -Actual $actualValue)) {
            $changed.Add([string]$key)
        }
    }
    return [string[]]$changed.ToArray()
}

function Get-LabPolicyPatchBody {
    <#
    .SYNOPSIS
        The PATCH body for an existing policy: each changed top-level key, sent whole (decided 2026-10-31).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Definition,

        [Parameter(Mandatory = $true)]
        [string[]] $ChangedKey
    )

    $body = [ordered]@{}
    foreach ($key in $ChangedKey) {
        if (-not $Definition.Contains($key)) {
            throw "Changed key '$key' is not in the definition."
        }
        $body[$key] = $Definition[$key]
    }
    return $body
}
