# WAF Rule Fix: AllowHRMobileGeo Access Issue

## Problem Analysis
Your access to `hrmobile.albtests.com` from IP `195.114.107.49` is being blocked by the `AllowHRMobileGeo` rule.

## Root Cause
The rule has confusing double-negative logic and may have case-sensitivity issues.

### Current Rule Logic (Problematic):
```
Block if (NOT from SA) AND (NOT hostname equals "hrmobile.albtests.com")
```

## Immediate Fixes

### Option 1: Quick Fix - Add Case Insensitive Transform
```json
{
  "MatchVariables": [{"VariableName": "RequestHeaders", "Selector": "Host"}],
  "OperatorProperty": "Equal",
  "NegationConditon": true,
  "MatchValues": ["hrmobile.albtests.com"],
  "Transforms": ["Lowercase"]  // ADD THIS
}
```

### Option 2: Fix Logic - Change to Positive Logic
```json
{
  "Name": "BlockNonHRMobileOutsideSA",
  "Priority": 20,
  "Action": "Block",
  "MatchConditions": [
    {
      "MatchVariables": [{"VariableName": "RemoteAddr"}],
      "OperatorProperty": "GeoMatch",
      "NegationConditon": true,
      "MatchValues": ["SA"]
    },
    {
      "MatchVariables": [{"VariableName": "RequestHeaders", "Selector": "Host"}],
      "OperatorProperty": "Equal",
      "NegationConditon": true,
      "MatchValues": ["hrmobile.albtests.com"],
      "Transforms": ["Lowercase"]
    }
  ]
}
```

### Option 3: Simplest Fix - Allow Your IP Range
Add your IP to the `AllowRMBIPs` rule:
```json
"MatchValues": [
  "194.126.231.49",
  "195.114.107.49",  // YOUR IP - ADD THIS
  "13.94.212.98",
  // ... rest of IPs
]
```

## Recommended Action for DEV/SIT

Since this is DEV/SIT environment, **Option 3 is recommended**:

1. Add your IP `195.114.107.49` to the `AllowRMBIPs` rule
2. This will bypass all other blocking rules
3. Simple and safe for development environment

## Why This Rule is Confusing

1. **Name says "Allow" but Action is "Block"**
2. **Double negative logic**: NOT(condition1) AND NOT(condition2)
3. **Case sensitivity**: "Equal" operator without transforms

## Test Your Fix

After implementing the fix, test with:
```bash
curl -H "Host: hrmobile.albtests.com" https://[your-app-gateway-ip]/
```

## Long-term Recommendation

For production, simplify this rule to positive logic:
```json
{
  "Name": "AllowHRMobileFromSA", 
  "Action": "Allow",
  "MatchConditions": [
    {
      "OperatorProperty": "GeoMatch",
      "NegationConditon": false,
      "MatchValues": ["SA"]
    },
    {
      "OperatorProperty": "Contains", 
      "NegationConditon": false,
      "MatchValues": ["hrmobile.albtests.com"],
      "Transforms": ["Lowercase"]
    }
  ]
}
```