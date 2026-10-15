# Architecture Documentation: Hybrid Identity & Entra ID Lab

## 1. Executive Summary
This document outlines the architectural design for the hybrid identity laboratory environment. The lab bridges an on-premises Active Directory Domain Services (AD DS) forest with a cloud-native Microsoft Entra ID tenant, establishing secure User Principal Name (UPN) synchronization, automated user/group provisioning, and dynamic departmental isolation.

---

## 2. Component Topology

```mermaid
graph TD
    subgraph Host ["Local Hyper-V Host"]
        AD["Active Directory DC<br/>Domain: rtworks.local<br/>UPN Suffixes Configured"]
        Sync["Entra Connect Sync Agent<br/>Provisioning Agent"]
        AD -->|Syncs Users & Groups| Sync
    end

    Sync -->|"TLS / HTTPS (Cloud Sync)"| Entra["Microsoft Entra Tenant<br/>yourdomain.onmicrosoft.com"]

    style Host fill:#f9f9f9,stroke:#333,stroke-width:2px
    style AD fill:#e1f5fe,stroke:#01579b,stroke-width:1px
    style Sync fill:#e8f5e9,stroke:#2e7d32,stroke-width:1px
    style Entra fill:#e3f2fd,stroke:#1565c0,stroke-width:1px
## 3. Directory Service & Organizational Unit (OU) Hierarchy
To support enterprise-grade security targeting, delegation, and Group Policy deployment, the Active Directory directory tree is structured under domain components using a structured organizational unit model:

```text
DC=rtworks,DC=local
├── OU=Domain Controllers
└── OU=CorpUsers
    ├── OU=IT
    ├── OU=HR
    ├── OU=Finance
    ├── OU=Sales
    ├── OU=Marketing
    ├── OU=Engineering
    ├── OU=Operations
    ├── OU=Legal
    ├── OU=Product
    └── OU=Customer Support
```
`OU=Domain Controllers`: Houses domain controller computer objects and policies.

`OU=CorpUsers`: The primary root container established to isolate lab user objects from built-in system containers.

## Department Sub-OUs ##: Dynamic departmental containers (`OU=IT`, `OU=HR`, `OU=Finance`, `OU=Sales`, `OU=Marketing`, `OU=Engineering`, `OU=Operations`, `OU=Legal`, `OU=Product`, `OU=Customer Support`) that house user accounts based on their CSV department attributes.

## 4. Hybrid Identity & Synchronization Architecture
# A. UPN Routing Strategy
On-Premises Suffix (`.local`): Used strictly for internal domain services and Kerberos authentication.

Cloud Verified Suffix (`.onmicrosoft.com / Custom Domain`): Registered as an alternative UPN suffix in Active Directory. User principal names are formatted as `samaccountname@yourdomain.onmicrosoft.com` to ensure seamless routing and sign-in across the hybrid boundary.

# B. Microsoft Entra Connect Cloud Sync
Agent Model: Utilizes lightweight provisioning agents (`AADConnectProvisioningAgent`) installed locally to connect outbound via TLS/HTTPS (Port 443) directly to the Entra service.

Provisioning Scope: Synchronizes objects originating from the `CorpUsers` OU hierarchy up to the Microsoft Entra tenant, propagating attributes such as `DisplayName`, `Department`, `Title`, and `Office`.

## 5. Infrastructure Validation & Compliance
Configuration drift and infrastructure integrity are continuously validated using an automated Pester test framework (`tests/IdentityLab.Tests.ps1`), which asserts:

1.	Module availability and CSV dataset parity.

2.	Existence and correct configuration of root and department sub-OUs.

3.	Proper creation and scope of department security groups.

4.	UPN format compliance and correct hierarchical object placement.