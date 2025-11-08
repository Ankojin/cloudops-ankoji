# Copy-Paste Reference - Variable Values

## ⚠️ IMPORTANT: Tags Are Now Mandatory via GUI

**Tags are no longer configured in Variable Groups** - they must be provided through the pipeline GUI in mandatory JSON format.

## 🚀 Quick Setup: Copy These Exact Values

### For VM-Creation-DEV Variable Group

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

## ⚠️ **IMPORTANT: Tags Now Mandatory via Pipeline GUI**

### New Workflow (No Variable Group Tags):

#### For DEV (16 variables total):
- 16 infrastructure variables
- ❌ No tag variables (mandatory via GUI)

#### For SIT (16 variables total):
- 16 infrastructure variables
- ❌ No tag variables (mandatory via GUI)

### Benefits of GUI-Based Tags:
- **🔒 Enforced compliance** (all 14 mandatory tags)
- **✅ Real-time validation** (Company="BAB" required)
- **📝 Per-deployment customization** (project-specific values)
- **🚀 Simplified Variable Groups** (16 vars vs 30+ previously)
- **🛡️ Security** (tags validated before deployment)

### Migration from Previous Setup:
- **Remove all tag variables** from Variable Groups
- **Use pipeline GUI** for all tag input
- **Variable Groups** now only contain infrastructure settings
- **Mandatory validation** ensures compliance