# Quick Setup Guide - Pipeline Enhancements

## 🚀 5-Minute Setup

### Step 1: Configure Teams Notifications (2 minutes)

1. Open your Microsoft Teams channel
2. Click `...` → `Connectors` → `Incoming Webhook`
3. Name it: "VM Creation Pipeline"
4. Copy the webhook URL
5. In Azure DevOps:
   - Go to `Pipelines` → `Library` → `VM-Creation-{ENV}`
   - Add variable: `TEAMS_WEBHOOK_URL`
   - Paste the webhook URL
   - ✅ Mark as **Secret**
   - Save

### Step 2: Test Notification (1 minute)

```powershell
# Run this on your agent or locally
$webhookUrl = "YOUR_WEBHOOK_URL"

.\Pipelines\VM-Creation\scripts\Send-PipelineNotification.ps1 `
    -Status "Success" `
    -Project "test" `
    -Environment "DEV" `
    -Action "apply" `
    -WebhookUrl $webhookUrl `
    -BuildId "12345"
```

Expected: You should see a message in Teams! ✅

### Step 3: Validate Your CSV (2 minutes)

Before running the pipeline, validate your CSV:

```powershell
# Check CSV format
$csv = Import-Csv ".\Pipelines\VM-Creation\core\simplified-vms.csv"

# Check for duplicates
$csv | Group-Object vm_name | Where { $_.Count -gt 1 }  # Should be empty
$csv | Group-Object static_ip | Where { $_.Count -gt 1 }  # Should be empty

# Validate required columns
$required = @('vm_name', 'resource_group', 'subnet_name', 'static_ip', 'vm_size', 'os_template')
$csv[0].PSObject.Properties.Name | Should -Contain $required
```

---

## ✅ Verification Checklist

Run pipeline → Check these appear:

- [ ] **CSV Pre-flight Validation** step runs first
- [ ] **Start Notification** appears in Teams
- [ ] **Terraform Plan Summary** shows resource counts
- [ ] **Rollback point created** message in logs
- [ ] **Success Notification** appears in Teams (if successful)
- [ ] **VM IP Addresses** displayed at end

---

## 🔍 Monitoring Your Pipeline

### Where to Find Information:

**1. Azure DevOps Pipeline Logs**
```
Look for:
✅ CSV validation completed successfully
✅ Rollback point created: ...
✅ Apply completed successfully in X seconds
✅ State file contains Y resources
```

**2. Teams Channel**
```
You'll receive:
🚀 Pipeline Started notification
✅ Pipeline Completed notification (with resource counts)
❌ Pipeline Failed notification (with error details)
```

**3. State Backups**
```
Location: C:\TerraformState\Project\{project}\{env}\backups\
Files: pre-apply-state-{timestamp}.tfstate
Retention: Last 10 backups kept automatically
```

---

## ⚠️ Troubleshooting

### Issue: Notifications not appearing

**Check:**
```powershell
# Verify variable is set
az pipelines variable-group list --group-name "VM-Creation-SIT" --query "[].variables.TEAMS_WEBHOOK_URL"

# Test webhook manually
Invoke-RestMethod -Uri $webhookUrl -Method Post -Body '{"text":"Test"}' -ContentType "application/json"
```

**Solution:** Regenerate webhook in Teams if expired

---

### Issue: CSV validation failing

**Common Errors:**
```
❌ Duplicate VM names found: web-01
Fix: Ensure all VM names are unique

❌ Duplicate IP addresses found: 10.189.59.100
Fix: Assign unique IPs to each VM

❌ Invalid VM name: web_server_01
Fix: Use hyphens instead: web-server-01

❌ Invalid IP address for web-01: 10.189.59.256
Fix: Use valid IP range (0-255 per octet)
```

---

### Issue: Rollback not working

**Check backup exists:**
```powershell
$backupDir = "C:\TerraformState\Project\pilot-test\SIT\backups"
Get-ChildItem $backupDir -Filter "pre-apply-*.tfstate" | Select -First 1
```

**Manual rollback if needed:**
```powershell
# Use most recent backup
$latest = Get-ChildItem $backupDir -Filter "pre-apply-*.tfstate" | Sort LastWriteTime -Desc | Select -First 1
Copy-Item $latest.FullName "C:\TerraformState\Project\pilot-test\SIT\terraform.tfstate" -Force
```

---

## 🎯 Best Practices

### 1. Always Validate CSV First
```powershell
# Before pipeline run
.\validate-csv-subnets.ps1 `
    -CsvPath ".\core\simplified-vms.csv" `
    -SubscriptionId "YOUR_SUB_ID" `
    -VNetName "YOUR_VNET" `
    -VNetResourceGroup "YOUR_RG"
```

### 2. Use Modify Action for Updates
```
✅ Changing IP → Use modify action
✅ Adding disks → Use modify action
✅ Changing VM size → Use modify action
❌ New VMs → Use apply action
```

### 3. Review Plan Before Apply
```
Check the plan summary:
- Resources to ADD: Should match expected new VMs
- Resources to CHANGE: Review carefully
- Resources to DESTROY: ⚠️ Verify this is intentional!
```

### 4. Monitor Teams for Status
```
✅ Set up mobile Teams app
✅ Enable notifications for pipeline channel
✅ Act quickly on failure notifications
```

---

## 📊 Success Metrics

After enhancements, you should see:

✅ **Faster Failure Detection**
- CSV errors caught in <1 minute (vs 5+ minutes before)

✅ **Reduced Manual Intervention**
- Automatic rollback on failures
- No manual state cleanup needed

✅ **Better Team Awareness**
- Real-time notifications to team
- Clear success/failure visibility

✅ **Improved Reliability**
- Duplicate detection prevents conflicts
- Validation prevents partial deployments

---

## 🆘 Emergency Contacts

**Pipeline Issues:**
- CloudOps Team: cloudops@company.com
- Teams Channel: #cloudops-support

**State Corruption:**
1. Stop all pipeline runs
2. Contact CloudOps team immediately
3. Don't attempt manual fixes without backup

**Rollback Failed:**
1. Note the backup timestamp in logs
2. Contact CloudOps with Build ID
3. Manual restoration may be required

---

## 📚 Additional Resources

- Full documentation: `ENHANCEMENTS-v2.8.1.md`
- Validation script: `validate-csv-subnets.ps1`
- Notification script: `scripts/Send-PipelineNotification.ps1`
- Pipeline YAML: `pipelines/Terraform-Apply-Enhanced-v2.8.yml`
- Generator: `core/generate-tf-v2.8.py`

---

**Last Updated:** December 9, 2025
**Version:** 2.8.1
