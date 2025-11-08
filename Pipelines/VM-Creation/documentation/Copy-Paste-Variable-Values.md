# Copy-Paste Reference - Variable Values

## 🚀 Quick Setup: Copy These Exact Values

### For VM-Creation-DEV Variable Group

#### Tag Variables Option 1: Individual Variables (Copy-Paste Ready):
```
tag_company: BAB
tag_department: Information Technology
tag_project_name: BaaS Platform Migration
tag_application_name: Banking as a Service
tag_start_date: 2025-01-01
tag_end_date: 2025-12-31
tag_region: Sweden Central
tag_approver_name: IT Director
tag_requester_name: CloudOps Team
tag_business_owner: Banking Operations Manager
tag_technical_owner: Infrastructure Team Lead
tag_cost_center: IT-INFRA-001
tag_service_class: Development
tag_managed_by: CloudOps Team
```

#### Tag Variables Option 2: Single JSON Variable (RECOMMENDED):
**Variable Name**: `default_tags_json`
**Value** (Copy exactly):
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "BaaS Platform Migration",
  "ApplicationName": "Banking as a Service",
  "StartDate": "2025-01-01",
  "EndDate": "2025-12-31",
  "Region": "Sweden Central",
  "ApproverName": "IT Director",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "Banking Operations Manager",
  "TechnicalOwner": "Infrastructure Team Lead",
  "CostCenter": "IT-INFRA-001",
  "ServiceClass": "Development",
  "ManagedBy": "CloudOps Team"
}
```

#### Infrastructure Variables (Copy-Paste Ready):
```
location: swedencentral
vnet_name: vnet-baas-dev-001
vnet_rg: rg-networking-dev
subnet_rg: rg-networking-dev
keyvault_name: kv-baas-dev-001
keyvault_rg: rg-security-dev: rg-security-dev
dcr_name: dcr-baas-dev-001
dcr_rg: rg-monitoring-dev
diagnostics_storage: stdiagnosticsdev001
diagnostics_storage_rg: rg-diagnostics-dev
script_storage_account: stscriptsdev001
script_storage_container: scripts
script_blob_name_linux: linuxpostconf.sh
script_blob_name_windows: windows-postconf-script-secure.ps1
```

#### Subnets Config (JSON - Copy Exactly):
```json
{"app": ["subnet-app-dev-001", "subnet-app-dev-002"], "db": ["subnet-db-dev-001"], "web": ["subnet-web-dev-001", "subnet-web-dev-002"], "mgmt": ["subnet-mgmt-dev-001"]}
```

---

### For VM-Creation-SIT Variable Group

#### Tag Variables Option 1: Individual Variables (Copy-Paste Ready):
```
tag_company: BAB
tag_department: Information Technology
tag_project_name: BaaS Platform Migration
tag_application_name: Banking as a Service
tag_start_date: 2025-01-01
tag_end_date: 2025-12-31
tag_region: Sweden Central
tag_approver_name: IT Director
tag_requester_name: CloudOps Team
tag_business_owner: Banking Operations Manager
tag_technical_owner: Infrastructure Team Lead
tag_cost_center: IT-INFRA-002
tag_service_class: Testing
tag_managed_by: QA Team
```

#### Tag Variables Option 2: Single JSON Variable (RECOMMENDED):
**Variable Name**: `default_tags_json`
**Value** (Copy exactly):
```json
{
  "Company": "BAB",
  "Department": "Information Technology",
  "ProjectName": "BaaS Platform Migration",
  "ApplicationName": "Banking as a Service",
  "StartDate": "2025-01-01",
  "EndDate": "2025-12-31",
  "Region": "Sweden Central",
  "ApproverName": "IT Director",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "Banking Operations Manager",
  "TechnicalOwner": "Infrastructure Team Lead",
  "CostCenter": "IT-INFRA-002",
  "ServiceClass": "Testing",
  "ManagedBy": "QA Team"
}
```

#### Infrastructure Variables (Copy-Paste Ready):
```
location: swedencentral
vnet_name: vnet-baas-sit-001
vnet_rg: rg-networking-sit
subnet_rg: rg-networking-sit
keyvault_name: kv-baas-sit-001
keyvault_rg: rg-security-sit
dcr_name: dcr-baas-sit-001
dcr_rg: rg-monitoring-sit
diagnostics_storage: stdiagnosticssit001
diagnostics_storage_rg: rg-diagnostics-sit
script_storage_account: stscriptssit001
script_storage_container: scripts
script_blob_name_linux: linuxpostconf.sh
script_blob_name_windows: windows-postconf-script-secure.ps1
```

#### Subnets Config (JSON - Copy Exactly):
```json
{"app": ["subnet-app-sit-001", "subnet-app-sit-002"], "db": ["subnet-db-sit-001"], "web": ["subnet-web-sit-001", "subnet-web-sit-002"], "mgmt": ["subnet-mgmt-sit-001"]}
```

---

## 🔐 Secret Variables (Enter Your Actual Values):

### DEV Environment:
```
subscription_id: [YOUR-DEV-SUBSCRIPTION-ID] (Mark as SECRET)
```

### SIT Environment:
```
subscription_id: [YOUR-SIT-SUBSCRIPTION-ID] (Mark as SECRET)
```

---

## 🔧 TerraformVariables Group (Global):

```
ARM_CLIENT_ID: [YOUR-SERVICE-PRINCIPAL-ID] (Mark as SECRET)
ARM_CLIENT_SECRET: [YOUR-SERVICE-PRINCIPAL-SECRET] (Mark as SECRET)  
ARM_TENANT_ID: [YOUR-TENANT-ID] (Mark as SECRET)
```

---

## ⚡ Speed Tips:

1. **Open two browser tabs** - one for DEV, one for SIT variable groups
2. **Copy-paste in batches** - do all tag variables first, then infrastructure
3. **Double-check JSON** - subnets_config must be valid JSON (no line breaks)
4. **Mark secrets last** - easier to verify values before hiding them
5. **Save frequently** - don't lose your work

## 🎯 Differences to Watch:

| Variable | DEV Value | SIT Value |
|----------|-----------|-----------|
| `tag_cost_center` | `IT-INFRA-001` | `IT-INFRA-002` |
| `tag_service_class` | `Development` | `Testing` |
| `tag_managed_by` | `CloudOps Team` | `QA Team` |
| `vnet_name` | `vnet-baas-dev-001` | `vnet-baas-sit-001` |
| All resource names | `-dev-` | `-sit-` |

**Time Estimate**: ~15-20 minutes to create both variable groups

---

## 🎯 **RECOMMENDATION: Use JSON Format**

### Simplified Setup with JSON:

#### For DEV (17 variables total):
- 16 infrastructure variables 
- 1 tag variable: `default_tags_json` (with DEV JSON)

#### For SIT (17 variables total):
- 16 infrastructure variables
- 1 tag variable: `default_tags_json` (with SIT JSON)

### Benefits:
- **50% fewer variables** (34 total instead of 66)
- **Faster setup** (2 minutes vs 10 minutes per environment)
- **Easier maintenance** (edit JSON structure vs 14 individual variables)
- **Better overview** (see all tags in one place)

### Migration Path:
- The Python script supports **both approaches**
- Start with JSON format for new setups
- Individual variables still work as fallback
- You can switch between approaches anytime