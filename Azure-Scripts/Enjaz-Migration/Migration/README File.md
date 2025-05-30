Folder Structure

C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\Enjaz-Migration\Migration
│
├── Migrate-VMs.ps1
├── vm-migration.csv
├── Logs\
│   ├── VM1.log
│   └── VM2.log
├── failed.txt


# Azure VM Migration Script (Cross-Tenant)

## Description

This PowerShell script migrates Azure virtual machines between different **Azure tenants** using **service principal authentication** for both source and target environments. It supports:
- OS and data disk migration via snapshot + disk copy
- VNet/Subnet and static IP assignment
- Linux and Windows OS types
- Admin credentials for Linux VMs (password-based login)
- CSV-driven bulk automation

---

## Prerequisites

- PowerShell 7+ recommended
- Azure PowerShell Module: `Install-Module Az -Scope CurrentUser -Repository PSGallery -Force`
- Two service principals (source & target tenants) with:
  - `Contributor` role on subscription/resource group
  - Access to VMs, disks, snapshots, VNet, and NIC creation

---

## CSV Input File Format

Required headers:

```csv
VMName,TargetVMName,OSType,SourceTenantId,SourceSubscription,SourceClientId,SourceClientSecret,SourceResourceGroup,TargetTenantId,TargetSubscription,TargetClientId,TargetClientSecret,TargetResourceGroup,TargetVMSize,TargetVNetName,TargetVNetResourceGroup,TargetSubnetName,TargetStaticIP,LinuxAdminUsername,LinuxAdminPassword
