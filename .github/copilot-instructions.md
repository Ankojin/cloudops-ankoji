# BAB CloudOps AI Assistant Guidelines

## Project Overview
This is an Azure cloud operations repository focused on VM migration, automation, and infrastructure management across multiple Azure tenants and subscriptions.

## 🚨 CRITICAL Security Requirements
- **NEVER commit sensitive data**: Azure subscription IDs, tenant IDs, client secrets, SAS tokens, or passwords must NEVER be hardcoded
- **Use Azure Key Vault**: Reference secrets via Key Vault for all automation scripts
- **CSV sanitization**: Always review CSV files for sensitive data before commits
- **Service Principal security**: Use managed identities or environment variables, never embed client secrets

## Architecture & Components

### Core Directory Structure
- `Azure-Scripts/`: Multi-subscription PowerShell automation (VM tagging, snapshots, ASR management)
- `Pipelines/`: Azure DevOps YAML pipelines for infrastructure deployment
- `autoshutdown/`: Terraform modules for cost optimization
- `ARI-main/`: Azure Resource Inventory tool (fork) for compliance reporting
- `VM-Creation/`: CSV-driven VM deployment with custom configurations

### Key Patterns

#### PowerShell Script Standards
All scripts follow this pattern:
```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    [string]$LogPath = ".\operation-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

# Standard logging function with levels (Info, Warning, Error, Success)
function Write-Log { }
```

#### CSV-Driven Operations
Most operations use CSV files with these conventions:
- VM operations: Include subscription, resource group, VM name columns
- Cross-tenant migrations: Use service principal authentication columns
- Always validate CSV headers before processing

#### Multi-Subscription Handling
Scripts typically iterate through subscriptions:
```powershell
# Switch context pattern used throughout
Set-AzContext -SubscriptionId $subscriptionId
```

## Development Workflows

### Testing Scripts
- Use `-WhatIf` parameters for dry runs when available
- Test with single VM/resource before bulk operations
- Always verify subscription context before executing

### Migration Scripts (Enjaz-Migration/)
- Cross-tenant VM migration using snapshot → VHD → new VM workflow
- Supports resume functionality for failed migrations
- Handles both Windows and Linux VMs with different authentication methods

### Automation Pipelines
- Located in `Pipelines/` directory
- Use Azure DevOps YAML format
- Include variable groups for environment-specific values

## Integration Points
- **Azure Resource Manager**: All scripts use Az PowerShell module
- **Azure DevOps**: Pipelines integrate with Azure subscriptions via service connections
- **Terraform**: Infrastructure as Code for repeatable deployments
- **Key Vault**: Centralized secret management (should be used more extensively)

## Common Operations
- `Add-VMTags-MultiSub.ps1`: Bulk VM tagging across subscriptions
- `Remove-AllSnapshots.ps1`: Cost optimization through snapshot cleanup
- `Get-UnattachedDisks.ps1`: Identify orphaned resources
- Migration scripts: Cross-tenant VM moves with network configuration

## Security Best Practices
- Always use `Get-AzKeyVaultSecret` instead of hardcoded values
- Implement proper RBAC for service principals
- Use managed identities when running in Azure
- Sanitize all CSV files before version control commits
- Enable audit logging for all subscription-level operations