<#
.SYNOPSIS
    Shared helper functions for the entra-hybrid-identity-lab scripts.
.DESCRIPTION
    Dot-source from a script with:
        . (Join-Path -Path $PSScriptRoot -ChildPath 'LabCommon.ps1')
    These helpers never write to the directory, so they can be unit tested on any machine.
#>

function Get-LabDepartmentList {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param()

    return [string[]]@('IT', 'HR', 'Finance', 'Sales', 'Marketing', 'Engineering', 'Operations', 'Legal', 'Product', 'Customer Support')
}

function Import-LabActiveDirectoryModule {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -Name ActiveDirectory)) {
        Import-Module -Name ActiveDirectory -ErrorAction Stop
    }
}

function ConvertTo-LdapFilterValue {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    # Backslash must be escaped first so the escapes added below are not escaped again.
    $escaped = $Value.Replace('\', '\5c')
    $escaped = $escaped.Replace('*', '\2a')
    $escaped = $escaped.Replace('(', '\28')
    $escaped = $escaped.Replace(')', '\29')
    $escaped = $escaped.Replace([string][char]0, '\00')
    return $escaped
}

function Get-LabParentDN {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DistinguishedName
    )

    # Removes the first RDN. An escaped comma (\,) inside the RDN does not end it.
    return [regex]::Replace($DistinguishedName, '^(?:\\.|[^,\\])+,', '')
}

function Test-LabDnUnder {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DistinguishedName,

        [Parameter(Mandatory = $true)]
        [string] $ContainerDN
    )

    return $DistinguishedName.EndsWith(",$ContainerDN", [System.StringComparison]::OrdinalIgnoreCase)
}

function Import-LabUserCsv {
    <#
    .SYNOPSIS
        Reads and validates the lab user CSV, returning normalized user objects.
    .DESCRIPTION
        Accepts the lab's current headers (Name = given name, LastName = surname) or the clearer
        GivenName / Surname headers. Any other column, including Password, is ignored and never read.
        All problems are collected and reported together in a single terminating error, so a bad file
        stops a run before any directory change is made.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string[]] $AllowedDepartments = (Get-LabDepartmentList)
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw "CSV file has no data rows: $Path"
    }

    $headers = @($rows[0].PSObject.Properties.Name)
    $givenColumn = 'Name'
    if ($headers -contains 'GivenName') { $givenColumn = 'GivenName' }
    $surnameColumn = 'LastName'
    if ($headers -contains 'Surname') { $surnameColumn = 'Surname' }

    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($column in @($givenColumn, $surnameColumn, 'DisplayName', 'UserPrincipalName', 'SamAccountName', 'Department')) {
        if ($headers -notcontains $column) {
            $problems.Add("Missing required column '$column'.")
        }
    }
    if ($problems.Count -gt 0) {
        throw ("CSV validation failed:`n" + ($problems -join "`n"))
    }

    $users = New-Object -TypeName System.Collections.Generic.List[object]
    $seenSam = @{}
    $seenUpn = @{}
    $seenName = @{}
    $lineNumber = 1

    foreach ($row in $rows) {
        $lineNumber++
        $label = "Line $lineNumber"

        $title = ''
        if ($headers -contains 'Title') { $title = ([string]$row.Title).Trim() }
        $office = ''
        if ($headers -contains 'Office') { $office = ([string]$row.Office).Trim() }

        $department = ([string]$row.Department).Trim()
        $user = [pscustomobject]@{
            Line              = $lineNumber
            GivenName         = ([string]$row.$givenColumn).Trim()
            Surname           = ([string]$row.$surnameColumn).Trim()
            DisplayName       = ([string]$row.DisplayName).Trim()
            UserPrincipalName = ([string]$row.UserPrincipalName).Trim()
            SamAccountName    = ([string]$row.SamAccountName).Trim()
            Department        = $department
            Title             = $title
            Office            = $office
        }

        foreach ($field in @('GivenName', 'Surname', 'DisplayName', 'UserPrincipalName', 'SamAccountName', 'Department')) {
            if ([string]::IsNullOrWhiteSpace($user.$field)) {
                $problems.Add("${label}: '$field' is blank.")
            }
        }

        if ($department -ne '') {
            $canonical = @($AllowedDepartments | Where-Object { $_ -ieq $department })
            if ($canonical.Count -eq 1) {
                $user.Department = $canonical[0]
            }
            else {
                $problems.Add("${label}: department '$department' is not one of: $($AllowedDepartments -join ', ').")
            }
        }

        if ($user.SamAccountName -ne '') {
            if ($user.SamAccountName.Length -gt 20) {
                $problems.Add("${label}: SamAccountName '$($user.SamAccountName)' is longer than 20 characters.")
            }
            if ($user.SamAccountName -notmatch '^[A-Za-z0-9._-]+$') {
                $problems.Add("${label}: SamAccountName '$($user.SamAccountName)' contains characters other than letters, digits, '.', '_' or '-'.")
            }
            $samKey = $user.SamAccountName.ToLowerInvariant()
            if ($seenSam.ContainsKey($samKey)) {
                $problems.Add("${label}: SamAccountName '$($user.SamAccountName)' duplicates line $($seenSam[$samKey]).")
            }
            else {
                $seenSam[$samKey] = $lineNumber
            }
        }

        if ($user.UserPrincipalName -ne '') {
            if ($user.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                $problems.Add("${label}: UserPrincipalName '$($user.UserPrincipalName)' is not in the form name@domain.")
            }
            $upnKey = $user.UserPrincipalName.ToLowerInvariant()
            if ($seenUpn.ContainsKey($upnKey)) {
                $problems.Add("${label}: UserPrincipalName '$($user.UserPrincipalName)' duplicates line $($seenUpn[$upnKey]).")
            }
            else {
                $seenUpn[$upnKey] = $lineNumber
            }
        }

        if ($user.DisplayName -ne '') {
            # The display name becomes the CN, which must be unique within one OU.
            $nameKey = ($user.Department + '|' + $user.DisplayName).ToLowerInvariant()
            if ($seenName.ContainsKey($nameKey)) {
                $problems.Add("${label}: DisplayName '$($user.DisplayName)' duplicates line $($seenName[$nameKey]) in the same department.")
            }
            else {
                $seenName[$nameKey] = $lineNumber
            }
        }

        $users.Add($user)
    }

    if ($problems.Count -gt 0) {
        throw ("CSV validation failed ($($problems.Count) problem(s)):`n" + ($problems -join "`n"))
    }

    return $users.ToArray()
}