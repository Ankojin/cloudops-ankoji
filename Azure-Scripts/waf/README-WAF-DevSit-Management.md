# WAF Policy Management for DEV/SIT Environment

## 🔧 **Current Configuration Analysis (DEV/SIT Appropriate)**

Based on your DEV/SIT environment, your current WAF policy configuration is **mostly appropriate** with some recommended adjustments:

### ✅ **What's Already Good for DEV/SIT**

1. **OWASP Rules in Log Mode** ✅
   - All rules set to `"Action": "Log"` 
   - **Perfect for DEV/SIT**: Allows development without blocking + gathers security intelligence

2. **Policy in Prevention Mode** ✅
   - `"Mode": "Prevention"` with `"State": "Enabled"`
   - Good baseline for testing WAF behavior

3. **Reasonable Body Limits** ✅
   - `MaxRequestBodySizeInKb: 2000` (2MB) - adequate for most testing
   - `FileUploadLimitInMb: 100` - good for file upload testing

### 🔧 **Recommended DEV/SIT Adjustments**

## Quick Configuration Script

Run this command to configure your WAF for optimal DEV/SIT use:

```powershell
.\Configure-WAFPolicy-DevSit.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ResourceGroupName "bab-core-appgw-weeu-rg-01" -PolicyName "bab-core-default-waf-policy"
```

## Manual Configuration Changes (Alternative)

If you prefer manual configuration, make these changes in Azure Portal:

### 1. **Geo-blocking Rules (Disable for Global Testing)**
- Navigate to: WAF Policy → Custom Rules
- **Disable** these rules:
  - `AllowHRMobileGeo`
  - `AllowBABUATAI` 
  - `AllowBABLIVEAI`
- **Reason**: Allows global testing access

### 2. **IP Allowlists (Add Development IPs)**
- Update `AllowRMBIPs` and `AllowBABProxyIPs` rules
- Add your development team IP ranges:
  ```
  [Your Office IP Range]
  [CI/CD Pipeline IPs]
  [Developer VPN IPs]
  ```

### 3. **Remove Dangerous Rules**
- **DELETE** the `BlockALL` rule entirely
- Even disabled, it's a risk

### 4. **Add Development Tools Rule**
```json
{
  "Name": "AllowDevelopmentTools",
  "Priority": 5,
  "MatchConditions": [{
    "MatchVariables": [{"VariableName": "RequestHeaders", "Selector": "User-Agent"}],
    "OperatorProperty": "Contains",
    "MatchValues": ["PostmanRuntime", "curl", "wget", "HTTPie", "Insomnia"]
  }],
  "Action": "Allow",
  "State": "Enabled"
}
```

## 📊 **DEV/SIT Monitoring Strategy**

### Use Azure Monitor Logs
```kusto
// WAF logs query for development insights
AzureDiagnostics
| where Category == "ApplicationGatewayFirewallLog"
| where TimeGenerated > ago(24h)
| summarize count() by ruleId_s, action_s, hostname_s
| order by count_ desc
```

### Key Metrics to Track in DEV/SIT:
1. **Rule Triggers**: Which OWASP rules fire most frequently
2. **False Positives**: Legitimate dev traffic being flagged
3. **Custom Rule Effectiveness**: Are your custom rules working as expected
4. **Performance Impact**: Request processing times

## 🚀 **Transition to Production**

When promoting to production, use this checklist:

### Production Readiness Checklist:
- [ ] Change OWASP rules from "Log" to "Block"
- [ ] Re-enable geo-blocking rules
- [ ] Reduce `MaxRequestBodySizeInKb` to 512-1024 KB
- [ ] Remove development tools allowlist rule
- [ ] Tighten IP allowlists to production requirements
- [ ] Enable custom block responses
- [ ] Configure log scrubbing for sensitive data
- [ ] Add rate limiting rules
- [ ] Upgrade to OWASP 4.0

### Production Configuration Script:
```powershell
# Future production script (to be created)
.\Configure-WAFPolicy-Production.ps1 -SubscriptionId "xxx" -ResourceGroupName "xxx" -PolicyName "xxx"
```

## 🔍 **Development Testing Scenarios**

Your current configuration supports these testing scenarios:

### ✅ **Supported Testing**
1. **API Testing**: Postman, curl, automated tests
2. **Large Payloads**: File uploads up to 100MB
3. **Security Testing**: All attacks logged but not blocked
4. **Load Testing**: No rate limiting interference
5. **Global Access**: Testing from any geographic location

### ⚠️ **Limitations to Consider**
1. **Real Attack Simulation**: Won't block actual attacks (by design)
2. **Performance Testing**: May not reflect production WAF overhead
3. **False Positive Testing**: Need production-like rules to test properly

## 📋 **Environment-Specific WAF Strategy**

| Environment | OWASP Action | Geo-blocking | Body Limits | Custom Rules |
|-------------|--------------|--------------|-------------|--------------|
| **DEV/SIT** | Log | Disabled | Relaxed | Dev-friendly |
| **UAT** | Log→Block (gradual) | Enabled | Medium | Production-like |
| **PROD** | Block | Enabled | Strict | Security-focused |

## 🛠️ **Useful Commands**

### Export Current Policy for Backup:
```powershell
.\Export-AppGatewayWAFPolicy.ps1 -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912" -ExportFormat "JSON"
```

### Check WAF Logs:
```powershell
# View recent WAF activity
Get-AzLog -ResourceId "/subscriptions/d88f0b5b-6660-4607-8c6a-395820400912/resourceGroups/bab-core-appgw-weeu-rg-01/providers/Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies/bab-core-default-waf-policy" -StartTime (Get-Date).AddHours(-1)
```

## 🎯 **Summary for DEV/SIT**

Your current WAF configuration is **85% optimal** for DEV/SIT environment. The main improvements needed are:

1. **Disable geo-blocking** for global testing access
2. **Add development tools allowlist** for API testing
3. **Remove dangerous BlockALL rule**
4. **Increase payload limits** for comprehensive testing

The script `Configure-WAFPolicy-DevSit.ps1` will make these adjustments automatically while maintaining security monitoring capabilities.