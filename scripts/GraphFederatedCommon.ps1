<#
.SYNOPSIS
    Shared helpers for the GitHub Actions Graph jobs (graph-tests, ca-deploy).
.DESCRIPTION
    Signs a job in to Microsoft Graph with the app's federated credential (R-50, D1), checks the
    tokens (aud, app-only, roles: R-51), and checks the app holds no secret or certificate (R-50 (3)).
    Dot-source with:
        . ./scripts/GraphFederatedCommon.ps1
    Tokens are masked in the GitHub log before anything else is done with them and are never
    written to output (R-58). Only role names and pass/fail lines are printed.
    Get-LabGraphCollection reads every page of a Graph list; it works with any Graph connection,
    so the R-53 read-back tests also run locally with a delegated sign-in.
    Needs PowerShell 7 and Microsoft.Graph.Authentication (Connect-MgGraph, Invoke-MgGraphRequest).
#>

function ConvertFrom-LabJwtPayload {
    <#
    .SYNOPSIS
        Decodes the payload (middle part) of a JWT into a hashtable. Does not validate the signature:
        it is only used to check claims of tokens this job just received over TLS.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Jwt
    )

    $parts = $Jwt.Split('.')
    if ($parts.Count -ne 3) {
        throw 'Not a JWT (expected three dot-separated parts).'
    }

    # Base64url to Base64: swap the two URL-safe characters back and restore the padding.
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'JWT payload has an invalid length.' }
    }

    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
    return ($json | ConvertFrom-Json -AsHashtable)
}

function Add-LabLogMask {
    <#
    .SYNOPSIS
        Tells GitHub Actions to mask a value in every later log line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    # Workflow commands are read from standard output.
    [System.Console]::Out.WriteLine("::add-mask::$Value")
}

function Test-LabTokenRole {
    <#
    .SYNOPSIS
        True when a token payload is app-only and its roles are exactly the expected set (R-51).
    .DESCRIPTION
        App-only: no scp claim, and oid equals sub (Microsoft Learn, Protected web API: Verify scopes
        and app roles). Roles are compared as sets: order is ignored, duplicates are not allowed.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Payload,

        [Parameter(Mandatory = $true)]
        [string[]] $ExpectedRole
    )

    if ($Payload.Contains('scp')) { return $false }
    if (-not $Payload['oid'] -or $Payload['oid'] -ne $Payload['sub']) { return $false }

    $actual = @(@($Payload['roles']) | Where-Object { $_ } | Sort-Object)
    $expected = @(@($ExpectedRole) | Where-Object { $_ } | Sort-Object)
    if ($actual.Count -ne $expected.Count) { return $false }
    if (@($actual | Select-Object -Unique).Count -ne $actual.Count) { return $false }

    return (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual -CaseSensitive).Count -eq 0)
}

function Get-LabGitHubOidcToken {
    <#
    .SYNOPSIS
        Requests the job's GitHub OIDC token for an audience and checks its aud claim.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string] $Audience = 'api://AzureADTokenExchange'
    )

    if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
        throw 'No OIDC request variables: the job needs permissions: id-token: write (R-54).'
    }

    $uri = '{0}&audience={1}' -f $env:ACTIONS_ID_TOKEN_REQUEST_URL, [System.Uri]::EscapeDataString($Audience)
    $headers = @{ Authorization = "bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" }
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    $token = [string] $response.value
    if (-not $token) {
        throw 'GitHub returned no OIDC token.'
    }
    Add-LabLogMask -Value $token

    $payload = ConvertFrom-LabJwtPayload -Jwt $token
    if ($payload['aud'] -ne $Audience) {
        throw "GitHub OIDC token has the wrong audience; expected $Audience."
    }
    Write-Information -MessageData "PASS: GitHub OIDC token audience is $Audience." -InformationAction Continue

    return $token
}

function Get-LabFederatedGraphToken {
    <#
    .SYNOPSIS
        Exchanges a GitHub OIDC token for a Microsoft Graph app-only access token
        (client credentials with a federated credential).
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TenantId,

        [Parameter(Mandatory = $true)]
        [string] $ClientId,

        [Parameter(Mandatory = $true)]
        [string] $Assertion
    )

    $body = @{
        client_id             = $ClientId
        scope                 = 'https://graph.microsoft.com/.default'
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $Assertion
    }
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $response = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    $token = [string] $response.access_token
    if (-not $token) {
        throw 'Microsoft Entra returned no access token.'
    }
    Add-LabLogMask -Value $token

    return $token
}

function Connect-LabGraphFederated {
    <#
    .SYNOPSIS
        Signs the job in to Microsoft Graph with the federated credential and checks the token.
    .DESCRIPTION
        GitHub OIDC token (aud checked) -> Entra token exchange -> app-only and roles checked (R-51)
        -> Connect-MgGraph -AccessToken. Throws on any failed check, before connecting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TenantId,

        [Parameter(Mandatory = $true)]
        [string] $ClientId,

        [Parameter(Mandatory = $true)]
        [string[]] $ExpectedRole
    )

    $assertion = Get-LabGitHubOidcToken
    $accessToken = Get-LabFederatedGraphToken -TenantId $TenantId -ClientId $ClientId -Assertion $assertion

    $payload = ConvertFrom-LabJwtPayload -Jwt $accessToken
    $roles = @($payload['roles']) | Sort-Object
    Write-Information -MessageData "Token roles: $($roles -join ', ')" -InformationAction Continue
    if (-not (Test-LabTokenRole -Payload $payload -ExpectedRole $ExpectedRole)) {
        throw "Token is not app-only with exactly these roles: $(($ExpectedRole | Sort-Object) -join ', ') (R-51)."
    }
    Write-Information -MessageData 'PASS: app-only token with exactly the expected roles (R-51).' -InformationAction Continue

    # SecureString without ConvertTo-SecureString -AsPlainText (PSScriptAnalyzer rule).
    $secureToken = [System.Net.NetworkCredential]::new('', $accessToken).SecurePassword
    Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
}

function Assert-LabAppHasNoCredential {
    <#
    .SYNOPSIS
        Throws unless the signed-in app's application and service principal hold no secret
        and no certificate (R-50 (3)). A service principal can read its own objects with no
        extra permission (Graph, Get servicePrincipal, Permissions for specific scenarios).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClientId
    )

    $select = '$select=passwordCredentials,keyCredentials'
    $objects = [ordered]@{
        application      = Invoke-MgGraphRequest -Method GET -Uri "v1.0/applications(appId='$ClientId')?$select" -OutputType HashTable -ErrorAction Stop
        servicePrincipal = Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals(appId='$ClientId')?$select" -OutputType HashTable -ErrorAction Stop
    }

    $problems = foreach ($name in $objects.Keys) {
        $secrets = @($objects[$name]['passwordCredentials']).Where({ $_ }).Count
        $certs = @($objects[$name]['keyCredentials']).Where({ $_ }).Count
        Write-Information -MessageData "$name : secrets $secrets, certificates $certs" -InformationAction Continue
        if ($secrets -gt 0 -or $certs -gt 0) { $name }
    }

    if (@($problems).Count -gt 0) {
        throw "Credentials found on: $(@($problems) -join ', '). R-50: the app must have no secret or certificate."
    }
    Write-Information -MessageData 'PASS: no secret or certificate on the application or service principal (R-50).' -InformationAction Continue
}

function Get-LabGraphCollection {
    <#
    .SYNOPSIS
        Returns every item of a Graph list, following @odata.nextLink to the last page.
    .DESCRIPTION
        Items are returned as hashtables (-OutputType HashTable). Stops with an error after
        -MaxPage pages, so a looping nextLink can't hang the job. The URI is never written to
        output, because it can hold an object ID (R-58).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [ValidateRange(1, 1000)]
        [int] $MaxPage = 100
    )

    $next = $Uri
    $pages = 0
    while ($next) {
        $pages++
        if ($pages -gt $MaxPage) {
            throw "Graph list has more than $MaxPage pages; stopped."
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType HashTable -ErrorAction Stop
        foreach ($item in @($page['value'])) {
            if ($null -ne $item) { $item }
        }
        $next = [string]$page['@odata.nextLink']
    }
}
