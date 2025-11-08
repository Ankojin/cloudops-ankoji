# Local Terraform State Management Guide

## 📁 State Storage Structure

Your Terraform state files will be stored locally on the Azure DevOps agent server:

```
C:\TerraformState\
└── Project\
    ├── BaaS-Platform\
    │   ├── DEV\
    │   │   ├── terraform.tfstate
    │   │   └── .terraform.lock.hcl
    │   └── SIT\
    │       ├── terraform.tfstate
    │       └── .terraform.lock.hcl
    └── Other-Project\
        ├── DEV\
        └── PROD\
```

## 🔧 How It Works

### **Apply/Modify Operations:**
1. Pipeline creates directory: `C:\TerraformState\Project\{ProjectName}\{Environment}\`
2. If existing state exists, copies it to working directory
3. Runs Terraform with local backend
4. Copies updated state back to persistent location

### **Destroy Operations:**
1. Copies existing state from persistent location
2. Runs Terraform destroy
3. Removes state file after successful destroy

## ✅ Benefits of Local State

### **Advantages:**
- **Simple Setup**: No Azure Storage account configuration needed
- **Fast Access**: No network latency for state operations
- **Direct Control**: State files accessible directly on agent
- **Cost Effective**: No storage account costs
- **Agent Persistence**: State persists between pipeline runs

### **Considerations:**
- **Agent Dependency**: State tied to specific agent server
- **No Built-in Locking**: Manual coordination needed for concurrent runs
- **Backup Responsibility**: Need to backup agent state directory
- **Single Point**: State only exists on one agent server

## 🚨 Important Considerations

### **Agent Configuration:**
```yaml
# Ensure your pipeline uses a specific agent pool
pool:
  name: 'YourSpecificAgentPool'  # Use named pool, not 'ubuntu-latest'
  demands:
  - terraform-state-agent  # Custom capability to ensure consistent agent
```

### **State Directory Permissions:**
```bash
# Ensure agent service account has full access to state directory
sudo mkdir -p /c/TerraformState/Project
sudo chown -R vstsagent:vstsagent /c/TerraformState/
sudo chmod -R 755 /c/TerraformState/
```

### **Backup Strategy:**
```bash
# Consider setting up automated backup of state directory
# Example: Daily backup to Azure Storage or Git repository
tar -czf /backup/terraform-state-$(date +%Y%m%d).tar.gz /c/TerraformState/
```

## 🔄 Migration from Azure Storage

If you previously used Azure Storage backend:

### **1. Download Existing States:**
```bash
# Download all existing state files from Azure Storage
az storage blob download-batch \
  --account-name your-storage-account \
  --destination /c/TerraformState/Project/ \
  --source terraform-states \
  --pattern "*.tfstate"
```

### **2. Reorganize Structure:**
```bash
# Move states to new directory structure
mkdir -p /c/TerraformState/Project/BaaS-Platform/DEV/
mv BaaS-Platform-dev-tfstate/terraform.tfstate /c/TerraformState/Project/BaaS-Platform/DEV/
```

## 🛡️ Security & Best Practices

### **Access Control:**
- Restrict access to state directory to agent service account only
- Consider encrypting state files at rest
- Regular backup of state directory

### **Monitoring:**
- Monitor disk space on state directory
- Log state file access and modifications
- Alert on state file corruption or missing files

### **Disaster Recovery:**
- Regular automated backups
- Documentation of state restoration procedures
- Test restore procedures regularly

## 📋 Verification Steps

### **Check State Directory:**
```bash
# Verify state directory structure
ls -la /c/TerraformState/Project/*/
```

### **Validate State Files:**
```bash
# Check state file integrity
cd /path/to/terraform/config
terraform show /c/TerraformState/Project/BaaS-Platform/DEV/terraform.tfstate
```

## 🔧 Troubleshooting

### **Common Issues:**

1. **Permission Denied:**
   ```bash
   sudo chown -R $(whoami) /c/TerraformState/
   ```

2. **State File Not Found:**
   - Check if first deployment (expected behavior)
   - Verify PROJECT_NAME and ENVIRONMENT variables
   - Check agent has access to state directory

3. **State File Corruption:**
   - Restore from backup
   - Use `terraform force-unlock` if needed
   - Consider regenerating state with `terraform import`

This local state management approach provides simplicity and direct control while maintaining environment isolation and proper state management practices.