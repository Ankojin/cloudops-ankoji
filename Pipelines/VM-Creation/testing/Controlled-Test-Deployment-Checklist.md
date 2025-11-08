# Controlled Test Deployment Checklist

## Pre-Deployment Verification ✅

### Local Environment Validated:
- ✅ Python script execution successful
- ✅ CSV parsing working correctly  
- ✅ Terraform configuration generation complete
- ✅ SIT environment variables validated
- ✅ Mandatory tags (14) validation passing
- ✅ File structure complete

### Azure DevOps Configuration:
- ✅ Pipeline YAML syntax validated
- ✅ PowerShell JSON parsing fixed
- ✅ Variable groups documented and specified
- ✅ Service principal permissions documented
- ✅ Agent requirements documented

## Deployment Readiness

### Required Azure DevOps Variable Groups:
1. **TerraformVariables** (Global)
2. **VM-Creation-SIT** (Environment-specific)
3. **VM-Creation-DEV** (Environment-specific)

### Test Deployment Configuration:
```
Environment: SIT
Project: BaaS-Platform
VM: ankoji-test-01
Size: Standard_B2s
OS: Windows Server 2019 Datacenter
Network: Static IP 10.189.57.162 in app subnet
Storage: 16GB data disk + StandardSSD_LRS OS disk
```

### Mandatory Tags for Test:
```json
{
  "Company": "BAB",
  "Department": "Information Technology", 
  "ProjectName": "pilot-test",
  "ApplicationName": "pilot-test",
  "StartDate": "2025-11-08",
  "EndDate": "2025-11-08",
  "Region": "Sweden Central",
  "ApproverName": "pilot-test",
  "RequesterName": "CloudOps Team",
  "BusinessOwner": "pilot-test",
  "TechnicalOwner": "pilot-test",
  "CostCenter": "pilot-test",
  "ServiceClass": "pilot-test",
  "ManagedBy": "CloudOps Team"
}
```

## Execution Steps

### Phase 1: Variable Groups Setup
1. Create variable groups in Azure DevOps Library
2. Populate all required variables per documentation
3. Set sensitive variables (subscription_id) as secrets
4. Grant pipeline permissions to variable groups

### Phase 2: Service Principal Configuration  
1. Verify service principal has Contributor role
2. Grant Key Vault Secrets User role for password access
3. Test service connection in Azure DevOps
4. Validate RBAC permissions on target resources

### Phase 3: Agent Validation
1. Verify cloudops-agent has Python 3.9+
2. Confirm Terraform 1.11.4+ installed
3. Test Azure CLI authentication
4. Ensure write access to C:\TerraformState\

### Phase 4: Pipeline Execution
1. Queue pipeline in Azure DevOps
2. Select **SIT** environment
3. Keep default **BaaS-Platform** project
4. Paste mandatory tags JSON in GUI field
5. Select **apply** action

### Phase 5: Deployment Monitoring
1. Monitor Python script execution
2. Review generated Terraform configuration
3. Validate Terraform plan output
4. Approve resource deployment
5. Verify successful VM creation

### Phase 6: Post-Deployment Validation
1. Confirm VM is running and accessible
2. Validate all 18 tags applied correctly
3. Check Azure Monitor Agent installation
4. Verify auto-shutdown schedule created
5. Test Key Vault password integration

## Expected Timeline

| Phase | Duration | Status |
|-------|----------|--------|
| Variable Groups | 15 min | ⏳ |
| Service Principal | 10 min | ⏳ |
| Agent Validation | 5 min | ⏳ |
| Pipeline Execution | 10 min | ⏳ |
| Resource Deployment | 15 min | ⏳ |
| Post-Validation | 10 min | ⏳ |
| **Total** | **~65 min** | ⏳ |

## Success Criteria

### Deployment Success:
- ✅ Pipeline runs without errors
- ✅ Terraform state created/updated
- ✅ VM deployed with correct configuration
- ✅ All monitoring components installed
- ✅ Tags applied correctly (18 total)
- ✅ Auto-shutdown configured

### Operational Success:
- ✅ VM accessible via RDP (Windows)
- ✅ Azure Monitor Agent reporting data
- ✅ Key Vault password authentication working
- ✅ Post-configuration script executed
- ✅ Automatic shutdown working at 8:00 PM

## Risk Mitigation

### Rollback Plan:
1. Terraform destroy command available
2. State file backup created automatically
3. Resource group can be deleted if needed
4. No impact on existing infrastructure

### Safety Measures:
1. Test VM in non-production subscription
2. Isolated resource group for testing
3. Small VM size to minimize costs
4. Auto-shutdown enabled to prevent runaway costs

## Next Steps After Success

### Production Readiness:
1. Document lessons learned
2. Create production variable groups
3. Test with production-like configurations  
4. Train operations team on pipeline usage
5. Implement monitoring and alerting

### Scaling Preparation:
1. Test multi-VM deployments
2. Validate cross-environment consistency
3. Test disaster recovery scenarios
4. Implement cost monitoring dashboards