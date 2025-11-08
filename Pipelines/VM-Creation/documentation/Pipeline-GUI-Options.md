# Pipeline GUI Options

## Overview
When running the VM Creation pipeline through Azure DevOps, you'll see a GUI form with the following options.

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

## 🔧 Optional Override Parameters

> **Note**: Leave these empty to use values from Variable Groups. Only fill them if you need to override for this specific run.

### **Azure Subscription ID**
- Leave empty to use variable group value
- Enter specific subscription ID only if needed for this run

### **Azure Region**
- Default: `Use Variable Group` (uses variable group value)  
- Available options: `Sweden Central`, `West Europe`
- Choose based on your compliance and performance requirements

### **VNet Name**
- Leave empty to use variable group value
- Override only if deploying to different VNet for this run

### **VNet Resource Group**
- Leave empty to use variable group value
- Override only if VNet is in different RG for this run

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

1. **Default Behavior**: Pipeline uses values from Variable Groups
2. **Override Behavior**: If you enter a value in GUI, it overrides the Variable Group value
3. **Hybrid Approach**: You can override some values while keeping others from Variable Groups

## 📝 Usage Examples

### Standard Deployment
- Action: `apply`
- Environment: `DEV` 
- Project: `BaaS-Platform`
- Leave all overrides **empty** (uses Variable Groups)

### Custom Region Deployment  
- Action: `apply`
- Environment: `SIT`
- Project: `BaaS-Platform`
- Region Override: `Sweden Central`
- Leave other overrides as `Use Variable Group`

### Special Testing with Custom Values
- Action: `apply`
- Environment: `DEV`
- Project: `BaaS-Platform` 
- Tags: Update ProjectName, ApplicationName, and other custom fields in the mandatory JSON
- Leave other overrides empty

### Production Deployment in West Europe
- Action: `apply`
- Environment: `SIT`
- Project: `BaaS-Platform`
- Region Override: `West Europe`
- Tags: Use mandatory JSON with production values and Region: "West Europe"

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
│ Advanced options:             │
│ □ Azure Subscription ID       │
│ □ Azure Region               │
│ □ VNet Name                  │
│ □ VNet Resource Group        │
│ □ Custom Tags (JSON)         │
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

## � Important Notes

- **Variable Groups**: Main configuration still comes from Azure DevOps Variable Groups
- **CSV File**: VM specifications (names, sizes, OS) come from CSV file  
- **Override Use**: Only use overrides when you need different values for specific runs
- **Testing**: Great for testing different regions or adding temporary tags
- **Production**: For production, prefer Variable Groups over GUI overrides
- **JSON Tags**: Always validate JSON format before running pipeline

## �📚 Related Documentation

- `Copy-Paste-Variable-Values.md` - Variable Group setup
- `VM-Creation-Quick-Start-Guide.md` - Complete setup guide
- `simplified-vms.csv` - VM specifications format