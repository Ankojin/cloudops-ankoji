# 📋 ServiceNow User Creation Pipeline - Required PowerShell Scripts

## 🎯 **Overview**
This document lists all PowerShell scripts required for the ServiceNow Azure AD user creation pipeline located in the `ServiceNow-Integration` folder.

## ✅ **Required Scripts in ServiceNow-Integration/Scripts/**

### 1. **Parse-ServiceNowRequest.ps1**
- **Purpose**: Parse incoming ServiceNow webhook requests
- **Input**: Raw JSON payload from ServiceNow
- **Output**: Parsed request data for pipeline processing
- **Status**: ✅ Complete and tested

### 2. **Validate-Request.ps1**
- **Purpose**: Validate request data against JSON schema
- **Input**: Parsed request data and schema file
- **Output**: Validation results and error messages
- **Status**: ✅ Complete and tested

### 3. **Generate-UPN.ps1**
- **Purpose**: Generate User Principal Names with company codes
- **Input**: User details (firstName, lastName, company)
- **Output**: Formatted UPN (e.g., anknag-B@babgroup.com)
- **Features**: 
  - Company code mapping (BAB="-B", ENJAZ="-E", ABIC="-A", ODC="-O")
  - Service account prefix handling (svc-)
  - Fixed domain: babgroup.com
- **Status**: ✅ Complete and tested

### 4. **Create-User-AAD.ps1** (Copied from Create_Users_AAD)
- **Purpose**: Direct Azure AD user account creation
- **Input**: Operation type, user details, or CSV file path
- **Output**: Created Azure AD user accounts
- **Features**:
  - Multiple operation types: "Create Service Account", "Create Normal AVD Users"
  - Service account parameter support
  - CSV file processing for bulk operations
  - Password complexity validation
  - Group membership management
- **Status**: ✅ Copied from original, fully functional

### 5. **Update-ServiceNow.ps1**
- **Purpose**: Send status updates back to ServiceNow
- **Input**: Request ID, status, progress percentage, messages
- **Output**: HTTP responses to ServiceNow REST API
- **Status**: ✅ Complete and tested

## � **Pipeline Flow (Simplified)**
```
ServiceNow Request → Parse → Validate → Generate UPN → Create-User-AAD (Direct) → Update ServiceNow
```

## 📊 **Pipeline Implementation**
- **Approach**: Direct inline PowerShell task in Azure DevOps pipeline
- **Flexibility**: Handles Service Account vs Normal/AVD account creation logic
- **CSV Generation**: Creates temporary CSV files for normal/AVD users
- **Parameter Mapping**: Maps ServiceNow request to Create-User-AAD.ps1 parameters

## 🧹 **Cleanup Actions Performed**
- ❌ **Removed**: `Execute-AzureAutomation.ps1` (unnecessary wrapper complexity)
- ❌ **Removed**: `vm-creation-schema.json` (out of scope)
- ✅ **Added**: Direct copy of `Create-User-AAD.ps1` to ServiceNow-Integration folder
- ✅ **Simplified**: Pipeline now uses inline PowerShell with direct script calls
- ✅ **Maintained**: Original `Create-User-AAD.ps1` script untouched

## ✅ **Verification Status**
- All 5 required scripts present in ServiceNow-Integration/Scripts/
- Pipeline YAML updated to call Create-User-AAD.ps1 directly via inline PowerShell
- All tests passing (schema, parse, validate, upn, execute, pipeline)
- Original Create-User-AAD.ps1 script copied but not modified
- Simplified architecture with reduced complexity

## 🎯 **Key Benefits of This Approach**
1. **No wrapper complexity**: Direct calls to proven Azure AD creation script
2. **Original script preserved**: No modifications to existing working code
3. **ServiceNow-specific copy**: Dedicated script copy for ServiceNow operations
4. **Simplified pipeline**: Inline PowerShell eliminates intermediate script files
5. **Flexible parameter handling**: Supports both service accounts and normal/AVD users

## 🚀 **Ready for Production**
The ServiceNow-Integration pipeline is now simplified and ready for production with direct Azure AD user creation capabilities.