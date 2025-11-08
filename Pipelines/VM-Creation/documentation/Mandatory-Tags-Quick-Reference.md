# 📋 Mandatory Tags Quick Reference

## ⚠️ ALL 14 TAGS REQUIRED - NO EXCEPTIONS

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

## 🔒 Fixed Values (Do Not Change)
- **Company**: Must be "BAB"
- **Department**: Usually "Information Technology"
- **RequesterName**: Usually "CloudOps Team"  
- **ManagedBy**: Usually "CloudOps Team"

## ✏️ Customize These Fields
- **ProjectName**: Your project identifier
- **ApplicationName**: Your application name
- **StartDate**: Project start date (YYYY-MM-DD)
- **EndDate**: Project end date (YYYY-MM-DD)
- **Region**: "Sweden Central" or "West Europe"
- **ApproverName**: Who approved this deployment
- **BusinessOwner**: Business contact person
- **TechnicalOwner**: Technical contact person  
- **CostCenter**: Your cost/billing center
- **ServiceClass**: Service classification (Development/Testing/Production)

## 🚨 Validation Rules
1. **All 14 tags must be present** - Pipeline fails if any missing
2. **Company must be "BAB"** - Exact match required
3. **Valid JSON syntax** - No trailing commas, proper quotes
4. **No empty values** - All tags must have actual content

## 💡 Quick Copy Templates

**Development:**
```json
{"Company": "BAB", "Department": "Information Technology", "ProjectName": "my-dev-project", "ApplicationName": "my-app", "StartDate": "2025-11-08", "EndDate": "2025-12-08", "Region": "Sweden Central", "ApproverName": "john.doe", "RequesterName": "CloudOps Team", "BusinessOwner": "jane.smith", "TechnicalOwner": "mike.jones", "CostCenter": "DEV-2025-001", "ServiceClass": "Development", "ManagedBy": "CloudOps Team"}
```

**Testing:**
```json
{"Company": "BAB", "Department": "Information Technology", "ProjectName": "my-test-project", "ApplicationName": "my-app", "StartDate": "2025-11-08", "EndDate": "2025-11-15", "Region": "West Europe", "ApproverName": "sarah.brown", "RequesterName": "CloudOps Team", "BusinessOwner": "alex.wilson", "TechnicalOwner": "lisa.garcia", "CostCenter": "TEST-2025-001", "ServiceClass": "Testing", "ManagedBy": "CloudOps Team"}
```

**Production:**
```json
{"Company": "BAB", "Department": "Information Technology", "ProjectName": "my-prod-project", "ApplicationName": "my-app", "StartDate": "2025-11-08", "EndDate": "2026-11-08", "Region": "Sweden Central", "ApproverName": "cto.office", "RequesterName": "CloudOps Team", "BusinessOwner": "business.head", "TechnicalOwner": "platform.team", "CostCenter": "PROD-2025-001", "ServiceClass": "Production", "ManagedBy": "CloudOps Team"}
```