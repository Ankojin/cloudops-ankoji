# Required Additional Variables for TerraformVariables Group

## Add these variables to your existing TerraformVariables group:

```yaml
# Terraform State Management
storageAccountName: "your-terraform-state-storage-account"
storageAccountResourceGroup: "your-terraform-state-rg"
storageAccountKey: "your-storage-account-key"  # Or use managed identity

# Service Principal for Terraform (if not already present)
ARM_CLIENT_ID: "your-service-principal-id"
ARM_CLIENT_SECRET: "your-service-principal-secret"
ARM_TENANT_ID: "your-azure-tenant-id"
```

## State Storage Structure:

With the new configuration, your state files will be organized as:

```
Azure Storage Account: your-terraform-state-storage-account
└── Container: BaaS-Platform-dev-tfstate
    └── terraform.tfstate (DEV environment state)
└── Container: BaaS-Platform-sit-tfstate  
    └── terraform.tfstate (SIT environment state)
```

## Benefits of Proper Backend:

1. **Automatic State Locking**: Prevents concurrent modifications
2. **State Versioning**: Rollback capability if state gets corrupted
3. **Team Collaboration**: Multiple team members can work safely
4. **Consistent State**: No manual upload/download errors
5. **Audit Trail**: All state changes are tracked

## Security Note:

Consider using Managed Identity instead of storage account keys:
- More secure (no secrets to manage)
- Automatic credential rotation
- Fine-grained access control