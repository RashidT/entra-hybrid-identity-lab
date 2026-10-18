<#
.SYNOPSIS
    Test helper: defines stand-ins for commands that only exist on a Windows machine with RSAT.
.DESCRIPTION
    Dot-source this from a BeforeAll block. On a machine that has the real ActiveDirectory module
    (a domain controller or an admin workstation) nothing is defined and the real cmdlets are mocked.
    On a GitHub-hosted runner, which has no ActiveDirectory module, a stand-in module with the same
    cmdlet names and parameters is created so that Pester can mock the cmdlets.

    The stand-ins do nothing on their own. Every test that runs a script must mock the cmdlets
    it relies on.
#>

if (-not (Get-Module -ListAvailable -Name ActiveDirectory) -and -not (Get-Module -Name ActiveDirectory)) {
    New-Module -Name ActiveDirectory -ScriptBlock {
        function Get-ADDomain { [CmdletBinding()] param([string] $Identity) }
        function Get-ADForest { [CmdletBinding()] param([string] $Identity) }
        function Set-ADForest { [CmdletBinding()] param([string] $Identity, [hashtable] $UPNSuffixes) }
        function Get-ADObject { [CmdletBinding()] param([string] $Identity, [string] $Filter, [string] $SearchBase) }
        function Get-ADOrganizationalUnit { [CmdletBinding()] param([string] $Identity, [string] $Filter) }
        function New-ADOrganizationalUnit {
            [CmdletBinding()] param([string] $Name, [string] $Path, [bool] $ProtectedFromAccidentalDeletion)
        }
        function Get-ADGroup { [CmdletBinding()] param([string] $Identity, [string] $Filter, [string] $SearchBase) }
        function New-ADGroup {
            [CmdletBinding()] param([string] $Name, [string] $GroupScope, [string] $GroupCategory, [string] $Path, [switch] $PassThru)
        }
        function Get-ADUser {
            [CmdletBinding()]
            param([object] $Identity, [string] $Filter, [string] $LDAPFilter, [string] $SearchBase, [string] $SearchScope, [string[]] $Properties)
        }
        function New-ADUser {
            [CmdletBinding()]
            param(
                [string] $Name, [string] $GivenName, [string] $Surname, [string] $DisplayName, [string] $SamAccountName,
                [string] $UserPrincipalName, [string] $Path, [string] $Department, [string] $Title, [string] $Office,
                [securestring] $AccountPassword, [bool] $ChangePasswordAtLogon, [bool] $Enabled, [switch] $PassThru
            )
        }
        function Set-ADUser {
            [CmdletBinding()]
            param(
                [object] $Identity, [string] $Department, [string] $Title, [string] $Office, [string] $GivenName,
                [string] $Surname, [string] $DisplayName, [string] $UserPrincipalName, [string] $Description
            )
        }
        function Disable-ADAccount { [CmdletBinding()] param([object] $Identity) }
        function Move-ADObject { [CmdletBinding()] param([object] $Identity, [string] $TargetPath) }
        function Add-ADGroupMember { [CmdletBinding()] param([object] $Identity, [object[]] $Members) }
        function Remove-ADGroupMember { [CmdletBinding(SupportsShouldProcess = $true)] param([object] $Identity, [object[]] $Members) }
        Export-ModuleMember -Function '*'
    } | Import-Module -Global -Force
}

# Commands used by 04-Test-CloudSyncAgent.ps1 that do not exist on non-Windows PowerShell.
if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
    function global:Get-Service { [CmdletBinding()] param([string] $Name) }
}
if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
    function global:Get-CimInstance { [CmdletBinding()] param([string] $ClassName, [string] $Filter) }
}
if (-not (Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue)) {
    function global:Test-NetConnection { [CmdletBinding()] param([string] $ComputerName, [int] $Port) }
}
