# 🏷️ Mandatory Tags Testing Guide

## ⚠️ IMPORTANT: All Tags Are Mandatory

**No optional tags** - all 14 tags must be provided or pipeline will fail.

## 📋 Copy-Paste Template

### **Base Template (Customize YOUR_* values)**
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

## 🧪 Ready-to-Use Examples

### **Example 1: Development Project**
```json
{
  "Company": "BAB",
  "Department": "Information Technology", 
  "ProjectName": "web-portal-dev",
  "ApplicationName": "customer-portal",
  "StartDate": "2025-11-08",
  "EndDate": "2025-12-08",
  "Region": "Sweden Central",
  "ApproverName": "john.smith",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "jane.doe",
  "TechnicalOwner": "mike.wilson",
  "CostCenter": "IT-2025-001",
  "ServiceClass": "Development",
  "ManagedBy": "CloudOps Team"
}
```

### **Example 2: Testing Environment**
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "api-testing",
  "ApplicationName": "payment-api",
  "StartDate": "2025-11-08", 
  "EndDate": "2025-11-15",
  "Region": "West Europe",
  "ApproverName": "sarah.jones",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "alex.brown",
  "TechnicalOwner": "lisa.garcia",
  "CostCenter": "QA-2025-002",
  "ServiceClass": "Testing",
  "ManagedBy": "CloudOps Team"
}
```

### **Example 3: Production Workload**
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "erp-production",
  "ApplicationName": "enterprise-erp",
  "StartDate": "2025-11-08",
  "EndDate": "2026-11-08", 
  "Region": "Sweden Central",
  "ApproverName": "cto.office",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "finance.head",
  "TechnicalOwner": "platform.team",
  "CostCenter": "PROD-2025-001",
  "ServiceClass": "Production",
  "ManagedBy": "CloudOps Team"
}
```

## 🧪 How to Test Mandatory Tags

1. **Copy** one of the complete JSON examples above
2. **Customize** the YOUR_* placeholders with real values
3. **Navigate** to Azure DevOps → Pipelines → VM Creation Pipeline
4. **Click** "Run Pipeline"
5. **Paste** complete JSON into the mandatory tags field
6. **Verify** all 14 tags are present before clicking Run
7. **Run** the pipeline

## ✅ Validation Checklist

**Before running pipeline:**
- [ ] All 14 mandatory tags present
- [ ] Company = "BAB" (exactly)
- [ ] ProjectName customized (not YOUR_PROJECT_NAME)
- [ ] ApplicationName customized (not YOUR_APPLICATION_NAME) 
- [ ] Valid dates in YYYY-MM-DD format
- [ ] ApproverName is a real person
- [ ] BusinessOwner is a real person
- [ ] TechnicalOwner is a real person
- [ ] CostCenter follows your organization's format
- [ ] ServiceClass reflects actual service type
- [ ] JSON syntax is valid (no trailing commas)

## ❌ Common Validation Errors

**Missing Tags:**
```
❌ ERROR: Missing mandatory tags: ProjectName, ApplicationName
```
**Solution:** Ensure all 14 tags are present

**Wrong Company:**
```
❌ ERROR: Company must be 'BAB'  
```
**Solution:** Set "Company": "BAB" exactly

**Invalid JSON:**
```
❌ ERROR: Invalid JSON format in tags
```
**Solution:** Check for trailing commas, quotes, brackets

## 🎯 What You'll See When Successful

**In Pipeline Logs:**
```
✅ Loaded 14 tags from JSON format
✅ All mandatory tags validated successfully  
🏷️ Final tag count: 18 (including auto-generated)
```

**On Azure Resources:**
- All 14 mandatory tags applied
- Plus 4 auto-generated tags:
  - CreatedBy: Terraform
  - CreationDate: 2025-11-08
  - Environment: DEV/SIT
  - Project: BaaS-Platform