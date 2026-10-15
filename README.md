# Hybrid Identity & Entra ID UPN Synchronization Lab

> **Automated on-premises Active Directory and Microsoft Entra ID hybrid identity lab environment featuring modular PowerShell scripts, UPN synchronization, automated user/group provisioning, dynamic department sub-OUs, and Pester infrastructure validation tests.**

## Overview
This repository provides a production-grade, automated infrastructure framework for building, configuring, and validating a hybrid identity environment. Designed for identity and access management (IAM) engineers, administrators, and professionals preparing for certifications like the Microsoft SC-300, this lab bridges on-premises Active Directory Domain Services (AD DS) with Microsoft Entra ID.

The lab utilizes modular, repeatable PowerShell scripts to automate the entire deployment lifecycle—from foundational forest and domain creation to User Principal Name (UPN) suffix routing, dynamic department sub-OU provisioning, bulk user and security group creation, and attribute synchronization updates. Infrastructure health and configuration compliance are continuously verified using automated Pester unit test suites.

## Key Features & Capabilities
* **Automated Active Directory Deployment:** Streamlined installation of AD DS, domain configuration, and hierarchical OU management (`CorpUsers`, department sub-containers like `Finance`, `Engineering`, `Sales`, and `Groups`).
* **Entra-Ready UPN Suffix Management:** Configures and maps verified custom domain UPN suffixes (`@yourdomain.onmicrosoft.com`) to eliminate default `.local` routing issues during hybrid synchronization.
* **Repeatable & Safe-to-Rerun Bulk User & Group Provisioning:** Parses CSV datasets (`C:\poshlog\users.csv`) to automatically create user objects inside dynamic department sub-OUs, construct proper full-name display attributes, and provision department-aligned security groups (`$Dept-Security-Group`) without creating duplicates if run multiple times.
* **Hybrid Identity Synchronization:** Configures local Microsoft Entra Connect Cloud Sync agents (`AADConnectProvisioningAgent`) to establish secure cloud-to-on-prem directory synchronization.
* **Infrastructure Testing with Pester:** Includes automated test suites (`tests/IdentityLab.Tests.ps1`) to validate Active Directory health, group memberships, user attribute formatting, and CSV record parity.

---

## Architecture Overview

```mermaid
graph TD
    subgraph Host ["Local Hyper-V Host"]
        AD["Active Directory DC<br/>Domain: yourdomain.local<br/>UPN Suffixes Configured"]
        Sync["Entra Connect Sync Agent<br/>Provisioning Agent"]
        AD -->|Syncs Users & Groups| Sync
    end

    Sync -->|"TLS / HTTPS (Cloud Sync)"| Entra["Microsoft Entra Tenant<br/>yourdomain.onmicrosoft.com"]

    style Host fill:#f9f9f9,stroke:#333,stroke-width:2px
    style AD fill:#e1f5fe,stroke:#01579b,stroke-width:1px
    style Sync fill:#e8f5e9,stroke:#2e7d32,stroke-width:1px
    style Entra fill:#e3f2fd,stroke:#1565c0,stroke-width:1px
  ```
## Repository Structure

```text
entra-hybrid-identity-lab/
├── docs/
│   └── architecture.md
├── scripts/
│   ├── 01-Install-ADDS.ps1
│   ├── 02-Configure-UPN.ps1
│   ├── 03-BulkImport-Users.ps1
│   ├── 04-Create-Groups.ps1
│   └── 05-Update-ADUsers.ps1
├── tests/
│   └── IdentityLab.Tests.ps1
├── data/
│   └── users.csv          # Sample CSV dataset (Press Ctrl+F to replace your domain)
├── .gitignore
├── LICENSE
└── README.md
```
## Prerequisites & Requirements 
Operating System: Windows Server 2022 or Windows 11 Enterprise (Hyper-V enabled).

Permissions: Local Administrator rights on the target domain controller / management workstation.

Modules Required: ActiveDirectory, Pester (v6.2.0+).

CSV Data Path: C:\poshlog\users.csv formatted with headers:
Name,LastName,DisplayName,UserPrincipalName,SamAccountName,Department,Title,Office,Password

## Quick Start Guide
### 1. Initialize Active Directory & Configure UPN Suffixes
Execute the foundational deployment and configure your verified Entra domain UPN suffix:

```PowerShell
# 01 - Install AD DS Forest and Domain
# Description: Installs Active Directory Domain Services, creates the forest, and promotes the server to a domain controller.
.\scripts\01-Install-ADDS.ps1
```
```PowerShell
# 02 - Configure UPN Suffixes
# Description: Configures and registers custom verified domain UPN suffixes to align with Microsoft Entra ID.
.\scripts\02-Configure-UPN.ps1
```
### 2. Bulk Import Users and Dynamic Department Sub-OUs
Run the bulk import script to automatically create the root CorpUsers container, dynamic department sub-OUs (OU=Finance, OU=Engineering, etc.), construct full display names, and provision security groups:

```PowerShell
# 03 - Bulk Import Users and Dynamic Department Sub-OUs
# Description: Parses CSV user records, creates dynamic department sub-OUs under CorpUsers, and provisions user accounts.
.\scripts\03-BulkImport-Users.ps1
```
### 3. Update Existing User Attributes and Sub-OU Placement
To apply structural updates, propagate naming standard changes, or relocate existing accounts into their proper department sub-containers uniformly:

```PowerShell
# 05 - Update Existing User Attributes and Sub-OU Placement
# Description: Propagates naming standard updates, attribute changes, and relocates existing accounts into proper sub-OUs.
.\scripts\05-Update-ADUsers.ps1
```
### 4. Run Infrastructure Validation Tests
Verify Active Directory health, group memberships, OU hierarchy, and CSV user parity using Pester:

```PowerShell
# IdentityLab - Pester Infrastructure Validation Suite
# Description: Automated unit tests to validate Active Directory health, group memberships, OU hierarchy, and CSV user attribute parity.
Invoke-Pester -Path .\tests\IdentityLab.Tests.ps1 -Output Detailed
```
### Verification Commands
To verify that user display names and attributes are correctly populated across Active Directory:

```PowerShell
Get-ADUser -Filter * -SearchBase "OU=CorpUsers,DC=yourdomain,DC=local" -Properties DisplayName, Department | Format-Table SamAccountName, Name, DisplayName, Department -AutoSize
```
## Reference & Learning Resources
This lab builds upon core Microsoft hybrid identity deployment patterns. For official documentation on setting up the foundational Active Directory and cloud sync architecture, refer to:

Microsoft Tutorial: Basic Active Directory and Entra Connect Cloud Sync

License
This project is licensed under the MIT License - see the LICENSE file for details.
