# Pipeline GUI Options

## Overview
When running the VM Creation pipeline through Azure DevOps, you'll see a simplified GUI form focused on mandatory tags.

## 📋 Required Parameters

### **Action to Perform**
- **apply**: Create new VMs
- **modify**: Modify existing VMs (uses existing state)

### **Target Environment** 
- **DEV**: Development environment
- **SIT**: System Integration Test environment

### **Project Name**
- Default: `BaaS-Platform`
- Customize for different projects

## 🏷️ **⚠️ MANDATORY: Tags (JSON Format)**

**All infrastructure settings come from Variable Groups. Only tags need to be provided via GUI.**

### **⚠️ MANDATORY Tags (JSON Format)**
- **REQUIRED**: Must provide all mandatory tags in valid JSON format
- **Cannot be empty**: Pipeline will fail if tags are missing or invalid
- **Company must be BAB**: Validation enforced

**🔴 Required Tags (All Mandatory):**
```json
{
  "Company": "BAB",
  "Department": "Information Technology", 
  "ProjectName": "YOUR_PROJECT_NAME",
  "ApplicationName": "YOUR_APPLICATION_NAME",
  "StartDate": "2025-11-08",
  "EndDate": "2025-11-08", 
  "Region": "Sweden Central",
  "ApproverName": "YOUR_APPROVER_NAME",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "YOUR_BUSINESS_OWNER",
  "TechnicalOwner": "YOUR_TECHNICAL_OWNER", 
  "CostCenter": "YOUR_COST_CENTER",
  "ServiceClass": "YOUR_SERVICE_CLASS",
  "ManagedBy": "CloudOps Team"
}
```

**✅ Customize These Fields:**
- `ProjectName`: Your actual project name
- `ApplicationName`: Your application name  
- `StartDate`/`EndDate`: Actual project dates
- `ApproverName`: Who approved this deployment
- `BusinessOwner`: Business contact person
- `TechnicalOwner`: Technical contact person
- `CostCenter`: Your cost center code
- `ServiceClass`: Service classification level

## 🎯 How It Works

1. **Infrastructure Configuration**: All settings come from Variable Groups (one-time setup)
2. **Tags Required per Deployment**: Provide mandatory tags via GUI for each deployment  
3. **Validation**: Ensures all 14 tags present and Company="BAB"

## 📝 Usage Examples

### Standard Deployment
- Action: `apply`
- Environment: `DEV` 
- Project: `BaaS-Platform`
- Provide complete mandatory JSON tags
- All infrastructure values come from Variable Groups

### Production Deployment
- Action: `apply`
- Environment: `SIT`
- Project: `BaaS-Platform`
- Provide complete mandatory JSON tags with production values
- All infrastructure values come from Variable Groups

## 🔍 What You'll See

When you click "Run Pipeline":
```
┌─ Run pipeline ─────────────────┐
│ Branch: main                   │
│                               │
│ Parameters:                   │
│ ✓ Action to Perform: apply    │
│ ✓ Target Environment: DEV     │
│ ✓ Project Name: BaaS-Platform │
│                               │
│ ⚠️ REQUIRED: Mandatory Tags   │
│ [JSON input field with       │
│  template tags]               │
│                               │
│ [Run]                        │
└───────────────────────────────┘
```

## 🏷️ Mandatory Tags Validation

### **Validation Rules**
1. **All 14 tags required**: Missing any tag will cause pipeline failure
2. **Company must be "BAB"**: Enforced validation rule  
3. **Valid JSON format**: Proper syntax required
4. **No empty values**: All tag values must have content

### **Pipeline Default Values**
The pipeline comes with template values:
- Company: `BAB` (fixed, cannot change)
- Department: `Information Technology` (usually fixed)
- RequesterName: `CloudOps Team` (can customize)
- ManagedBy: `CloudOps Team` (can customize)

### **What You Must Customize**
Update these fields for your specific deployment:
- `ProjectName`: Your project identifier
- `ApplicationName`: Your application name
- `StartDate`/`EndDate`: Your project timeline  
- `ApproverName`: Who authorized this deployment
- `BusinessOwner`: Business stakeholder
- `TechnicalOwner`: Technical contact
- `CostCenter`: Your billing code
- `ServiceClass`: Service tier/classification

### **Error Messages You Might See**
```
❌ ERROR: Mandatory tags are required!
❌ ERROR: Missing mandatory tags: ProjectName, ApplicationName
❌ ERROR: Company must be 'BAB'
❌ ERROR: Invalid JSON format in tags
```

## 🚨 Important Notes

- **Variable Groups**: All infrastructure configuration comes from Azure DevOps Variable Groups
- **CSV File**: VM specifications (names, sizes, OS) come from CSV file  
- **Tags Required**: Mandatory tags must be provided via GUI for each deployment
- **No Infrastructure Overrides**: All infrastructure settings (VNet, Region, etc.) use Variable Group values
- **One-Time Setup**: Configure Variable Groups once, provide tags per deployment
- **Validation**: Pipeline enforces all 14 mandatory tags with Company="BAB"

## �📚 Related Documentation

- `Copy-Paste-Variable-Values.md` - Variable Group setup
- `VM-Creation-Quick-Start-Guide.md` - Complete setup guide
- `simplified-vms.csv` - VM specifications format