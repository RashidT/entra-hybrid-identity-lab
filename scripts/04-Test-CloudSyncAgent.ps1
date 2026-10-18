<#
.SYNOPSIS
    Checks the local half of an Entra Cloud Sync setup: the provisioning agent and its prerequisites.
.DESCRIPTION
    Run this on the server where the provisioning agent is installed. The agent itself is installed
    from the Microsoft Entra admin center, following Microsoft's Cloud Sync tutorials; this script
    does not install anything.

    Checks, each reported as one result object (Check, Status, Detail):
      - the agent service exists and is running (Fail otherwise), and starts automatically (Warn)
      - the agent updater service exists (Warn if missing)
      - the account the agent service runs as is a group managed service account (Warn if not)
      - .NET strong cryptography (TLS 1.2) is enabled in the registry (Warn if not confirmed)
      - outbound TCP connectivity to each endpoint (Fail if unreachable)

    The script ends with a terminating error if any check failed. A passing result only proves the
    local side. Whether users actually arrive in Entra must be confirmed separately in the tenant.
.PARAMETER ServiceName
    Name of the provisioning agent service. Verify it with Get-Service on your agent server.
.PARAMETER UpdaterServiceName
    Name of the agent updater service. Verify it with Get-Service on your agent server.
.PARAMETER Endpoint
    Host names to test for outbound connectivity. The defaults are a minimum; extend the list from
    the endpoint list in Microsoft's Cloud Sync prerequisites documentation, which changes over time.
.PARAMETER Port
    TCP port to test. Defaults to 443.
.EXAMPLE
    .\scripts\04-Test-CloudSyncAgent.ps1
#>

[CmdletBinding()]
param(
    [string] $ServiceName = 'AADConnectProvisioningAgent',

    [string] $UpdaterServiceName = 'AADConnectProvisioningAgentUpdater',

    [string[]] $Endpoint = @('login.microsoftonline.com', 'login.windows.net'),

    [int] $Port = 443
)

$ErrorActionPreference = 'Stop'

function ConvertTo-CheckResult {
    param(
        [string] $Check,
        [string] $Status,
        [string] $Detail
    )

    [pscustomobject]@{
        Check  = $Check
        Status = $Status
        Detail = $Detail
    }
}

$checks = New-Object -TypeName System.Collections.Generic.List[object]

# ---- Agent service --------------------------------------------------------------------------
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    $checks.Add((ConvertTo-CheckResult -Check 'Agent service' -Status 'Fail' -Detail "Service '$ServiceName' was not found. Run this on the server where the agent is installed."))
}
else {
    if ($service.Status -eq 'Running') {
        $checks.Add((ConvertTo-CheckResult -Check 'Agent service' -Status 'Pass' -Detail "Service '$ServiceName' is running."))
    }
    else {
        $checks.Add((ConvertTo-CheckResult -Check 'Agent service' -Status 'Fail' -Detail "Service '$ServiceName' is $($service.Status)."))
    }

    if ("$($service.StartType)" -eq 'Automatic') {
        $checks.Add((ConvertTo-CheckResult -Check 'Agent start type' -Status 'Pass' -Detail 'Starts automatically.'))
    }
    else {
        $checks.Add((ConvertTo-CheckResult -Check 'Agent start type' -Status 'Warn' -Detail "Start type is $($service.StartType); the agent will not come back after a reboot."))
    }

    $cimService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    $logonAccount = "$(@($cimService)[0].StartName)"
    if ($logonAccount.EndsWith('$')) {
        $checks.Add((ConvertTo-CheckResult -Check 'Service account' -Status 'Pass' -Detail "Runs as $logonAccount (group managed service account)."))
    }
    else {
        $checks.Add((ConvertTo-CheckResult -Check 'Service account' -Status 'Warn' -Detail "Runs as '$logonAccount', which is not a group managed service account."))
    }
}

# ---- Updater service ------------------------------------------------------------------------
$updater = Get-Service -Name $UpdaterServiceName -ErrorAction SilentlyContinue
if ($updater) {
    $checks.Add((ConvertTo-CheckResult -Check 'Updater service' -Status 'Pass' -Detail "Service '$UpdaterServiceName' is $($updater.Status)."))
}
else {
    $checks.Add((ConvertTo-CheckResult -Check 'Updater service' -Status 'Warn' -Detail "Service '$UpdaterServiceName' was not found. Confirm the service name on this server."))
}

# ---- TLS 1.2 --------------------------------------------------------------------------------
try {
    $strongCrypto = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -ErrorAction Stop
    if ($strongCrypto.SchUseStrongCrypto -eq 1) {
        $checks.Add((ConvertTo-CheckResult -Check 'TLS 1.2 (.NET strong crypto)' -Status 'Pass' -Detail 'SchUseStrongCrypto is 1.'))
    }
    else {
        $checks.Add((ConvertTo-CheckResult -Check 'TLS 1.2 (.NET strong crypto)' -Status 'Warn' -Detail "SchUseStrongCrypto is $($strongCrypto.SchUseStrongCrypto), not 1."))
    }
}
catch {
    $checks.Add((ConvertTo-CheckResult -Check 'TLS 1.2 (.NET strong crypto)' -Status 'Warn' -Detail "Could not read the setting: $($_.Exception.Message)"))
}

# ---- Outbound connectivity ------------------------------------------------------------------
foreach ($hostName in $Endpoint) {
    try {
        $connection = Test-NetConnection -ComputerName $hostName -Port $Port -WarningAction SilentlyContinue
        if (@($connection)[0].TcpTestSucceeded) {
            $checks.Add((ConvertTo-CheckResult -Check "Connectivity $hostName`:$Port" -Status 'Pass' -Detail 'TCP connection succeeded.'))
        }
        else {
            $checks.Add((ConvertTo-CheckResult -Check "Connectivity $hostName`:$Port" -Status 'Fail' -Detail 'TCP connection failed.'))
        }
    }
    catch {
        $checks.Add((ConvertTo-CheckResult -Check "Connectivity $hostName`:$Port" -Status 'Fail' -Detail $_.Exception.Message))
    }
}

$checks

$failedCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
if ($failedCount -gt 0) {
    throw "$failedCount check(s) failed."
}
