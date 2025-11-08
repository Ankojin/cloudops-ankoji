# 🔧 PowerShell JSON Parsing Fix

## ❌ Problem
```powershell
# This causes parsing errors in PowerShell:
$env:SUBNETS_CONFIG = "{"app": ["subnet1", "subnet2"]}"
$tagsInput = "{"Company": "BAB", "Department": "IT"}"
```

**Error Message:**
```
Unexpected token 'app": ["subnet1", "subnet2"]' in expression or statement.
Unexpected token 'Company": "BAB", "Department": "IT"' in expression or statement.
```

## 🔍 Root Cause
- **Double Quotes Conflict**: JSON contains double quotes inside PowerShell double-quoted strings
- **Variable Expansion**: Azure DevOps variables with JSON get improperly parsed
- **PowerShell Parser**: Confused by nested quotes in command-line context

## ✅ Solution Applied

### **Before (Broken):**
```powershell
$env:SUBNETS_CONFIG = "$(subnets_config)"
$tagsInput = "${{ parameters.tags_json_override }}"
```

### **After (Fixed):**
```powershell
# Use single quotes to prevent quote conflicts
$env:SUBNETS_CONFIG = '$(subnets_config)'
$tagsInput = '${{ parameters.tags_json_override }}'
```

## 🎯 Key Changes

### 1. **Subnets Configuration**
```powershell
# ❌ Before: Double quotes cause JSON parsing issues
$env:SUBNETS_CONFIG = "$(subnets_config)"

# ✅ After: Single quotes preserve JSON structure
$env:SUBNETS_CONFIG = '$(subnets_config)'
```

### 2. **Tags JSON Input**
```powershell
# ❌ Before: Nested quotes break PowerShell parsing
$tagsInput = "${{ parameters.tags_json_override }}"

# ✅ After: Single quotes handle JSON safely
$tagsInput = '${{ parameters.tags_json_override }}'
```

### 3. **Enhanced Validation**
```powershell
# Added null check for better error handling
if ($tagsInput -and $tagsInput -ne "" -and $tagsInput -ne "Use Variable Group") {
    # Process tags...
}
```

## 📋 What This Fixes

### **Variable Group JSON (subnets_config):**
```json
{
  "app": ["snet-dev-nonpci-app-01", "snet-dev-nonpci-app-02"],
  "db": ["snet-dev-nonpci-db-02", "snet-dev-nonpci-db-03"],
  "web": ["snet-dev-nonpci-web-01", "snet-dev-nonpci-web-02"]
}
```

### **Pipeline Parameter JSON (tags):**
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "pilot-test",
  "ApplicationName": "pilot-test"
}
```

## 🧪 Validation Results

**✅ YAML Syntax**: Valid after fix  
**✅ PowerShell Parsing**: No more quote conflicts  
**✅ JSON Handling**: Proper preservation of JSON structure  
**✅ Pipeline Ready**: Should run without parsing errors  

## 💡 Best Practices Applied

1. **Single Quotes for JSON**: Use `'...'` when containing JSON data
2. **Null Checking**: Validate variables before processing  
3. **Clear Error Messages**: Helpful guidance for users
4. **Variable Isolation**: Separate JSON handling from other variables

**The pipeline should now handle JSON data correctly without PowerShell parsing errors!** 🎉