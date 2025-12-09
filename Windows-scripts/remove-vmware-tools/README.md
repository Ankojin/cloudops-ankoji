# VMware Tools Removal Script

## Overview
Production-grade PowerShell script for removing VMware Tools from Windows servers after Azure migration. Supports batch processing across multiple hosts with WinRM remoting.

## Features

### ✅ Fast & Efficient
- **Registry-based detection** - No slow `Win32_Product` WMI queries
- **Parallel execution** - Process multiple hosts concurrently (configurable throttle limit)
- **Smart authentication** - Automatic fallback between Negotiate and Kerberos

### 🔧 Comprehensive Cleanup
- MSI uninstaller with database patching (fixes VM_LogStart issues)
- Registry keys and values removal
- Services stop and deletion
- PnP devices removal
- Driver packages uninstall
- Directories and files cleanup
- DLL unregistration

### 🛡️ Safe & Compliant
- **WhatIf support** - Test runs without making changes
- **Detailed logging** - Thread-safe log file with timestamps
- **Error handling** - Continues on individual failures
- **No hardcoded credentials** - Follows BAB CloudOps security standards

### 📊 Professional Reporting
- Real-time progress tracking
- Per-host action logging
- Summary statistics with success/failure counts
- Color-coded console output

## Prerequisites

### Target Servers
- Windows Server 2012 R2 or later
- WinRM enabled and configured
- Firewall rules allowing WinRM (TCP 5985 or 5986 for HTTPS)

### Execution Host
- PowerShell 5.1 or later
- Network connectivity to target servers
- Domain or local admin credentials for target servers

### WinRM Configuration
Target servers should have WinRM enabled:
```powershell
# On target servers (run as Administrator)
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
Restart-Service WinRM
```

## Usage

### Basic Usage
```powershell
# Process servers from computers.txt in script directory
.\Remove-VMwareTools.ps1
```

### Using CSV File
```powershell
# Use CSV with ComputerName column
.\Remove-VMwareTools.ps1 -ComputersFile C:\Servers\azure-vms.csv
```

### Test Run (WhatIf)
```powershell
# Dry-run to see what would happen
.\Remove-VMwareTools.ps1 -WhatIf
```

### Pre-supplied Credentials
```powershell
# Avoid interactive prompt
$cred = Get-Credential -UserName "DOMAIN\AdminUser"
.\Remove-VMwareTools.ps1 -Credential $cred
```

### High Concurrency
```powershell
# Process 10 servers simultaneously
.\Remove-VMwareTools.ps1 -MaxConcurrent 10
```

### HTTPS/SSL Connection
```powershell
# Use HTTPS for WinRM (requires cert configuration)
.\Remove-VMwareTools.ps1 -UseSSL
```

### Custom Log Location
```powershell
# Specify custom log path
.\Remove-VMwareTools.ps1 -LogPath "C:\Logs\VMware-Cleanup-$(Get-Date -Format 'yyyyMMdd').log"
```

## Input File Formats

### Text File (computers.txt)
One hostname or IP per line:
```
D2SAPWBBOIWV1
DA4LEAPWBSWV1
DA4LEDBSQSWV1
```

### CSV File (computers.csv)
Must have `ComputerName` column:
```csv
ComputerName,SubscriptionId,ResourceGroup
D2SAPWBBOIWV1,sub-123,rg-prod-vms
DA4LEAPWBSWV1,sub-123,rg-prod-vms
DA4LEDBSQSWV1,sub-456,rg-dev-vms
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `ComputersFile` | String | No | Auto-detect | Path to text or CSV file with computer names |
| `LogPath` | String | No | Script dir + timestamp | Path to log file |
| `Credential` | PSCredential | No | Prompt | Credentials for remote authentication |
| `UseSSL` | Switch | No | False | Use HTTPS for WinRM connections |
| `MaxConcurrent` | Int | No | 5 | Max concurrent remote executions (1-50) |
| `WhatIf` | Switch | No | False | Preview actions without executing |

## Output

### Console Output
- Real-time color-coded progress with status
- Per-host connection and cleanup status
- Summary table with success/failure counts

### Log File
Thread-safe log file with:
- Timestamp for each entry
- Log level (Info, Success, Warning, Error)
- Per-host detailed actions and results
- Summary statistics

Example log entry:
```
[2025-12-02 14:23:15] [Info] ===== Processing: D2SAPWBBOIWV1 =====
[2025-12-02 14:23:16] [Success] WinRM connected to D2SAPWBBOIWV1 (Negotiate)
[2025-12-02 14:23:18] [Info]   Detection: Found 1 VMware product(s)
[2025-12-02 14:23:20] [Info]   MSI-Patch: Patched MSI database
[2025-12-02 14:23:45] [Info]   MSI-Uninstall: MSI uninstall completed (Exit: 0)
[2025-12-02 14:23:46] [Success] Successfully cleaned VMware Tools from D2SAPWBBOIWV1
```

## Cleanup Process Details

The script performs the following cleanup steps in order:

1. **Detection** - Registry-based VMware Tools detection (fast)
2. **MSI Uninstall** - Patches MSI database and runs uninstaller
3. **Package Removal** - Uses Get-Package/Uninstall-Package (newer systems)
4. **Service Cleanup** - Stops and removes all VMware services
5. **Registry Cleanup** - Removes VMware registry keys and values
6. **Directory Removal** - Deletes VMware installation folders
7. **Device Removal** - Removes VMware PnP devices
8. **Driver Uninstall** - Removes VMware driver packages from driver store
9. **DLL Unregistration** - Unregisters vmStatsProvider.dll

## Troubleshooting

### WinRM Connection Failures

**Error**: "Failed to connect to [server] via WinRM"

**Solutions**:
```powershell
# On target server - verify WinRM is running
Get-Service WinRM

# Test WinRM from execution host
Test-WSMan -ComputerName [server]

# Check firewall rules
Get-NetFirewallRule -DisplayName "*WinRM*"

# Enable WinRM on target
Enable-PSRemoting -Force
```

### Authentication Failures

**Error**: "Access is denied"

**Solutions**:
- Ensure credentials have local administrator rights on target servers
- Verify domain trust relationships
- Check if account is locked or password expired
- Try using DOMAIN\Username format

### MSI Uninstall Issues

**Error**: "MSI uninstall completed with code: 1603"

**Resolution**: Script will continue with manual cleanup methods even if MSI uninstall fails. Check `%TEMP%\vmware_uninstall.log` on target server for details.

### Partial Cleanup

If some components remain:
1. Check log file for specific failures
2. Manually remove remaining items on affected server
3. Use Device Manager to remove any remaining VMware devices
4. Reboot server and re-run script if necessary

## Post-Execution Steps

### ⚠️ Important: Reboot Required
After successful cleanup, **reboot target servers** to complete the removal process. This ensures:
- Driver removal is finalized
- Registry changes take full effect
- Services are completely removed
- System operates without VMware dependencies

### Verification
After reboot, verify removal:
```powershell
# Check for VMware services
Get-Service | Where-Object { $_.Name -like "*vmware*" }

# Check for VMware programs
Get-Package | Where-Object { $_.Name -like "*vmware*" }

# Check Program Files
Get-ChildItem "C:\Program Files" | Where-Object { $_.Name -like "*vmware*" }
```

## Migration Workflow Integration

This script is part of the **On-Premises to Azure VM Migration** workflow:

1. **Pre-Migration** - Prepare source VMs for migration
2. **Migration** - Use Azure Migrate or ASR to move VMs
3. **Post-Migration** - Install Azure VM Agent
4. **👉 VMware Cleanup** - Run this script to remove VMware Tools
5. **Validation** - Verify VM functionality in Azure
6. **Optimization** - Configure auto-shutdown, tags, backups

## Security Considerations

### ✅ Compliant with BAB CloudOps Standards
- No hardcoded credentials or secrets
- Uses secure credential prompting
- Supports Azure Key Vault integration (via pre-fetched credentials)
- Thread-safe logging prevents data corruption
- WhatIf support for safe testing

### Best Practices
- Use service accounts with minimal required privileges
- Store credentials in Azure Key Vault when running automated
- Review log files for security audit trail
- Use SSL/HTTPS for WinRM in production environments

## Performance

### Benchmarks (typical)
- Single server cleanup: 30-45 seconds
- 10 servers (MaxConcurrent=5): 2-3 minutes
- 100 servers (MaxConcurrent=10): 15-20 minutes

### Optimization Tips
- Increase `MaxConcurrent` for faster batch processing
- Use local network segments to reduce latency
- Pre-stage credentials to avoid multiple prompts
- Run during maintenance windows for reboots

## Known Limitations

1. **Reboot requirement** - Servers must be rebooted to complete removal
2. **WinRM dependency** - Requires WinRM to be properly configured
3. **Admin rights** - Requires local administrator privileges
4. **Network connectivity** - Cannot process offline or unreachable servers
5. **Windows only** - Does not support Linux VMware Tools removal

## Version History

### v2.0 (Current) - December 2025
- Complete rewrite following BAB CloudOps standards
- Added parallel execution with throttling
- Registry-based detection (removed slow Win32_Product)
- CSV input support
- WhatIf parameter
- Thread-safe logging
- Improved error handling and reporting
- Security enhancements

### v1.x (Deprecated)
- Legacy scripts removed from repository
- Used PsExec and Win32_Product (not recommended)

## Support

For issues or questions:
1. Check log file for detailed error messages
2. Review troubleshooting section above
3. Contact BAB CloudOps team
4. Open issue in repository with log excerpt

## Related Scripts

- **Add-VMTags-MultiSub.ps1** - Tag VMs across subscriptions
- **Add-VM-To-RecoveryVault.ps1** - Configure VM backups
- **autoshutdown.ps1** - Configure VM auto-shutdown schedules

## License

Internal use only - BAB CloudOps
