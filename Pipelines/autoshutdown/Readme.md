# Azure VM Auto-Shutdown Pipelines

This folder contains Azure DevOps pipelines to configure auto-shutdown schedules for Azure VMs using Terraform.

## 📋 Available Pipelines

### 1. **Single Resource Group Pipeline** (`autoshutdown-single.yml`)
Configure auto-shutdown for VMs in a single resource group.

**Use this when:**
- You need to configure one resource group at a time
- You prefer a simple UI form

**Parameters:**
- Subscription (BAB_DEV, BAB_SIT, BAB_CORE)
- Resource Group Name
- DB VM Names (optional)
- DB Shutdown Time
- App VM Names (optional)
- App Shutdown Time
- Time Zone

**State File Location:**
- Path: `C:\TerraformState\autoshutdown\<subscription>-<resource-group>.tfstate`
- Example: `C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate`

### 2. **Multiple Resource Groups Pipeline** (`autoshutdown-multiple-csv.yml`)
Configure auto-shutdown for multiple resource groups across different subscriptions using a CSV file.

**Use this when:**
- You need to configure multiple resource groups at once
- You want to manage configurations in Excel/CSV
- You need to apply settings across different subscriptions

**Setup:**
1. Edit `multiple_csv.csv` with your configuration
2. Commit the file to the repository
3. Run the pipeline

**State File Location:**
- Path: `C:\TerraformState\autoshutdown\<subscription>-<resource-group>.tfstate`
- Each resource group gets its own state file
- Example: `C:\TerraformState\autoshutdown\BAB_SIT-rg-sit-app.tfstate`

**CSV Format:**
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-dev-app,sql-dev-01,2200,web-dev-01,2000
```

## 🚀 Quick Start

### Single Resource Group
1. Navigate to Pipelines in Azure DevOps
2. Select `autoshutdown-single` pipeline
3. Click "Run pipeline"
4. Fill in the parameters
5. Click "Run"

### Multiple Resource Groups
1. Edit `Pipelines/autoshutdown/multiple_csv.csv`
2. Add your resource group configurations
3. Commit and push to repository
4. Navigate to Pipelines in Azure DevOps
5. Select `autoshutdown-multiple-csv` pipeline
6. Click "Run pipeline"

## 📊 CSV File Format

| Column | Required | Description | Example |
|--------|----------|-------------|---------|
| Subscription | Yes | Subscription name (BAB_DEV, BAB_SIT, BAB_CORE) | BAB_DEV |
| ResourceGroupName | Yes | Name of the resource group | rg-prod-app |
| DBVMs | No | Comma-separated DB VM names | sql-vm-01,sql-vm-02 |
| DBShutdownTime | No | Shutdown time for DB VMs (HHmm) | 2200 |
| AppVMs | No | Comma-separated App VM names | web-vm-01,api-vm-01 |
| AppShutdownTime | No | Shutdown time for App VMs (HHmm) | 2000 |

**Notes:**
- At least one VM type (DBVMs or AppVMs) must be specified per row
- Leave columns empty if not needed (e.g., if you only have DB VMs, leave AppVMs empty)
- Time format: HHmm (24-hour format, e.g., 2200 for 10:00 PM)

## 🔧 Terraform State Management

### State File Location
All Terraform state files are stored locally on the Azure DevOps agent:
- **Base Directory:** `C:\TerraformState\autoshutdown\`
- **Naming Convention:** `<Subscription>-<ResourceGroupName>.tfstate`

### State File Benefits
✅ **Isolated State per Resource Group** - Each resource group has its own state file, preventing conflicts  
✅ **Fast State Operations** - Local storage provides faster read/write operations  
✅ **No Azure Storage Costs** - No need for Azure Storage Account for state  
✅ **Agent-based** - State persists on the agent machine between runs  

### State File Examples

**Single Resource Group:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate
```

**Multiple Resource Groups:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-data.tfstate
C:\TerraformState\autoshutdown\BAB_SIT-rg-sit-app.tfstate
C:\TerraformState\autoshutdown\BAB_CORE-rg-prod-app.tfstate
```

### State File Lifecycle

1. **First Run:** State file is created in `C:\TerraformState\autoshutdown\`
2. **Subsequent Runs:** Terraform reads existing state and updates it
3. **Updates:** State is updated with current configuration
4. **Concurrent Runs:** Each resource group has isolated state, allowing parallel execution

### Important Considerations

⚠️ **Agent Persistence:**
- State files persist on the agent machine
- If the agent is rebuilt, state files are lost
- Consider backing up the state directory regularly

⚠️ **Concurrent Execution:**
- Safe for different resource groups (isolated state files)
- Do NOT run the same resource group configuration simultaneously
- Pipeline locks prevent concurrent runs for the same resource group

⚠️ **State File Cleanup:**
- State files accumulate over time
- Periodically review and clean up unused state files
- Keep state files for active resource groups

### Backup Recommendations

```powershell
# Manual backup script (run on agent)
$source = "C:\TerraformState\autoshutdown"
$destination = "C:\TerraformState\backups\autoshutdown-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -Path $source -Destination $destination -Recurse
```

Consider setting up automated backups:
- Schedule: Daily or weekly
- Retention: 30 days
- Location: Network share or Azure Blob Storage

## ✅ Best Practices

### General Best Practices
1. **Test in BAB_DEV first** before applying to BAB_SIT or BAB_CORE
2. **Use CSV pipeline for bulk operations** to save time
3. **Keep CSV file in source control** for audit trail
4. **Document changes** in commit messages
5. **Review Terraform plan output** before applying

### State Management Best Practices
6. **Monitor state file growth** - Large state files may indicate issues
7. **Don't manually edit state files** - Always use Terraform commands
8. **Back up state files** before major changes
9. **Use unique resource group names** to avoid state conflicts
10. **Clean up old state files** for decommissioned resource groups

### Pipeline Execution Best Practices
11. **Avoid concurrent runs** for the same resource group
12. **Check state file existence** before major operations
13. **Verify agent disk space** regularly for state directory
14. **Document state file location** in runbooks

## 📝 Examples

### Example 1: Single Resource Group with DB VMs Only
**Pipeline:** `autoshutdown-single.yml`
- Subscription: BAB_DEV
- Resource Group: rg-dev-database
- DB VMs: sql-dev-01,sql-dev-02
- DB Shutdown Time: 2200
- App VMs: (leave empty)

**State File Created:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-database.tfstate
```

### Example 2: Multiple Resource Groups via CSV
**File:** `multiple_csv.csv`
```csv
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_DEV,rg-dev-app,sql-dev-01,2200,web-dev-01,2000
BAB_DEV,rg-dev-data,postgres-dev-01,2300,,
BAB_SIT,rg-sit-app,sql-sit-01,2200,web-sit-01,2000
```

**State Files Created:**
```
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate
C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-data.tfstate
C:\TerraformState\autoshutdown\BAB_SIT-rg-sit-app.tfstate
```

## 🆘 Troubleshooting

### Issue: CSV file not found
**Solution:** Ensure `multiple_csv.csv` is committed to the repository in the correct path.

### Issue: Subscription ID not resolved
**Solution:** Verify variable groups `cloud-subs` contains subscription IDs for all three subscriptions.

### Issue: Terraform validation failed
**Solution:** Check that VM names exist in the specified resource group.

### Issue: State file permission denied
**Solution:** 
1. Check agent service account has write access to `C:\TerraformState`
2. Verify folder permissions: `icacls C:\TerraformState`
3. Ensure no other process is locking the state file

### Issue: State file corrupted
**Solution:**
1. Stop all pipeline runs for the affected resource group
2. Restore from backup: `C:\TerraformState\backups\`
3. If no backup exists, delete state file and re-run pipeline (will recreate resources)

### Issue: State lock error
**Solution:**
1. Check if another pipeline is running for the same resource group
2. Wait for the other pipeline to complete
3. Local backend doesn't support state locking; avoid concurrent runs

### Issue: Disk space full on agent
**Solution:**
1. Check disk space: `Get-PSDrive C`
2. Clean up old state files from decommissioned resource groups
3. Archive old backups to network storage

## 🔍 State File Inspection

### View State File Contents
```powershell
# View state file in JSON format
Get-Content "C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate" | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

### List All State Files
```powershell
# List all state files
Get-ChildItem "C:\TerraformState\autoshutdown\" -Filter "*.tfstate" | Select-Object Name, Length, LastWriteTime
```

### Check State File Size
```powershell
# Check size of specific state file
(Get-Item "C:\TerraformState\autoshutdown\BAB_DEV-rg-dev-app.tfstate").Length / 1KB
```

## 🔐 Security Considerations

1. **Access Control:**
   - Restrict access to `C:\TerraformState` directory
   - Only agent service account should have write access
   - Implement folder-level encryption if required

2. **Sensitive Data:**
   - State files may contain sensitive information
   - Do not commit state files to source control
   - Ensure backups are stored securely

3. **Audit Trail:**
   - Monitor access to state files
   - Log all pipeline runs that modify state
   - Maintain change history in Azure DevOps

## 📞 Support

For questions or issues, contact the CloudOps team.

## 📚 Additional Resources

- [Terraform State Documentation](https://www.terraform.io/docs/language/state/index.html)
- [Azure DevOps Pipelines](https://docs.microsoft.com/en-us/azure/devops/pipelines/)
- [Azure VM Auto-Shutdown](https://docs.microsoft.com/en-us/azure/automation/automation-solution-vm-management)
