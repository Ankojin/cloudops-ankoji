# Application Gateway WAF Policy Export Script

## Overview
The `Export-AppGatewayWAFPolicy.ps1` script exports Application Gateway WAF (Web Application Firewall) policies from Azure subscriptions. It supports both standalone WAF policies and WAF configurations attached to Application Gateways.

## Features
- **Multi-subscription support**: Process single subscription, multiple subscriptions from CSV, or all accessible subscriptions
- **Multiple export formats**: JSON, CSV, or both
- **Comprehensive logging**: Detailed logging with color-coded console output
- **Flexible filtering**: Choose to export standalone WAF policies, Application Gateway WAF configs, or both
- **Detailed reporting**: Summary statistics and individual policy details
- **Error handling**: Robust error handling with detailed error reporting

## Prerequisites
- Azure PowerShell modules: `Az.Accounts` and `Az.Network`
- Valid Azure authentication (run `Connect-AzAccount` first)
- Appropriate RBAC permissions to read Application Gateways and WAF policies

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `SubscriptionId` | string | No | - | Specific Azure subscription ID to export from |
| `CsvPath` | string | No | - | Path to CSV file containing subscription IDs |
| `OutputPath` | string | No | `.\WAF-Export-{timestamp}` | Path to save exported WAF policies |
| `ExportFormat` | string | No | `Both` | Export format: JSON, CSV, or Both |
| `IncludeAppGatewayWAF` | bool | No | `true` | Include WAF configurations from Application Gateways |
| `IncludeStandaloneWAFPolicies` | bool | No | `true` | Include standalone WAF policies |
| `LogPath` | string | No | `.\waf-export-{timestamp}.log` | Path for the log file |

## Usage Examples

### Export from all accessible subscriptions
```powershell
.\Export-AppGatewayWAFPolicy.ps1
```

### Export from specific subscription (JSON only)
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -ExportFormat "JSON"
```

### Export from subscriptions listed in CSV file
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -CsvPath ".\sample-subscriptions.csv" -OutputPath ".\WAF-Policies"
```

### Export only standalone WAF policies
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -IncludeAppGatewayWAF $false -OutputPath ".\Standalone-WAF-Only"
```

### Export only Application Gateway WAF configurations
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -IncludeStandaloneWAFPolicies $false -OutputPath ".\AppGateway-WAF-Only"
```

## CSV Input Format
When using the `-CsvPath` parameter, ensure your CSV file has the following structure:

```csv
SubscriptionId,SubscriptionName,Environment
12345678-1234-1234-1234-123456789012,Production-Subscription,Production
87654321-4321-4321-4321-210987654321,Development-Subscription,Development
```

**Required column**: `SubscriptionId`
**Optional columns**: Any additional columns for documentation purposes

## Output Files

The script generates the following output files:

### Summary Files
- **WAF-Policies-Summary.csv**: CSV summary of all WAF policies and configurations
- **WAF-Policies-Summary.json**: JSON summary of all WAF policies and configurations
- **Export-Summary.txt**: Text summary with statistics and file locations

### Individual Policy Files (JSON format only)
- **WAFPolicy_{PolicyName}_{SubscriptionId}.json**: Detailed JSON for standalone WAF policies
- **AppGateway_{GatewayName}_{SubscriptionId}.json**: Detailed JSON for Application Gateways with WAF

### Log File
- **waf-export-{timestamp}.log**: Detailed execution log with timestamps

## CSV Output Columns

The summary CSV includes the following columns:

| Column | Description |
|--------|-------------|
| `SubscriptionId` | Azure subscription ID |
| `PolicyType` | "Standalone" or "ApplicationGateway" |
| `PolicyName` | Name of the WAF policy or configuration |
| `ResourceGroupName` | Resource group containing the resource |
| `ApplicationGatewayName` | Name of Application Gateway (for AppGateway type) |
| `Location` | Azure region |
| `ProvisioningState` | Current provisioning state |
| `PolicyMode` | WAF mode (Detection/Prevention) |
| `PolicyState` | WAF state (Enabled/Disabled) |
| `RequestBodyCheck` | Whether request body inspection is enabled |
| `MaxRequestBodySizeInKb` | Maximum request body size |
| `FileUploadLimitInMb` | File upload size limit |
| `ManagedRuleSetType` | Managed rule set type and version |
| `CustomRulesCount` | Number of custom rules |
| `ExclusionCount` | Number of exclusions/disabled rule groups |
| `FirewallPolicyId` | ID of attached firewall policy (for App Gateways) |
| `ResourceId` | Full Azure resource ID |
| `Tags` | Resource tags (semicolon-separated) |
| `ExportTimestamp` | When the export was performed |

## Security Considerations

⚠️ **Important Security Notes:**
- Exported files may contain sensitive WAF configuration details
- Review JSON exports for any sensitive information before sharing
- Store exported files in secure locations
- Consider using Azure Key Vault references instead of hardcoded values in scripts
- Ensure appropriate RBAC permissions are in place

## Error Handling

The script includes comprehensive error handling:
- Validates Azure PowerShell modules and authentication
- Handles subscription access errors gracefully
- Continues processing other subscriptions if one fails
- Provides detailed error messages in logs
- Returns appropriate exit codes for automation scenarios

## Troubleshooting

### Common Issues

1. **"Not logged into Azure"**
   - Solution: Run `Connect-AzAccount` before executing the script

2. **"Az.Network module is not installed"**
   - Solution: Install Azure PowerShell modules: `Install-Module -Name Az -Force`

3. **Permission denied errors**
   - Solution: Ensure you have at least Reader permissions on the subscriptions and resources

4. **No WAF policies found**
   - Verify that Application Gateways or standalone WAF policies exist in the target subscriptions
   - Check that you have the correct subscription IDs

### Debug Mode
For additional debugging information, run the script with verbose output:
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -Verbose
```

## Integration with BAB CloudOps

This script follows the BAB CloudOps repository standards:
- Consistent logging patterns with color-coded output
- CSV-driven operations support
- Multi-subscription handling with proper context switching
- Comprehensive error handling and reporting
- Security-conscious design avoiding hardcoded sensitive values

## Version History

- **v1.0**: Initial release with comprehensive WAF policy export functionality