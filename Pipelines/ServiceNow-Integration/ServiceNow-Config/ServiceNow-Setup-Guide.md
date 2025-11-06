# ServiceNow Integration Setup Guide

## Overview
This document provides step-by-step instructions for configuring ServiceNow to integrate with Azure DevOps pipelines for automated Azure task execution.

## 📋 Table of Contents
- [Prerequisites](#prerequisites)
- [ServiceNow Configuration](#servicenow-configuration)
- [Azure DevOps Setup](#azure-devops-setup)
- [Webhook Configuration](#webhook-configuration)
- [Testing the Integration](#testing-the-integration)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### ServiceNow Requirements
- ServiceNow instance with admin privileges
- ServiceNow REST API access
- Service Catalog module (for request management)
- Workflow module (for automation workflows)

### Azure Requirements
- Azure DevOps organization and project
- Azure subscription access
- Service Principal with appropriate permissions
- Azure Key Vault (recommended for secrets)

### Network Requirements
- ServiceNow instance can reach Azure DevOps (outbound HTTPS)
- Azure DevOps agents can reach ServiceNow API (outbound HTTPS)

## ServiceNow Configuration

### 1. Create Custom Tables

#### Automation Request Table
```javascript
// Table: u_azure_automation_request
// Purpose: Track Azure automation requests
var gr = new GlideRecord('sys_db_object');
gr.initialize();
gr.name = 'u_azure_automation_request';
gr.label = 'Azure Automation Request';
gr.super_class = 'task';
gr.insert();
```

**Required Fields:**
```javascript
// Request Type (Choice field)
Field: u_request_type
Type: Choice
Choices: 
  - vm_creation
  - user_account  
  - vm_management
  - resource_tagging

// Request Payload (JSON field)
Field: u_request_payload
Type: String (Long)
Max Length: 8000

// Azure Status
Field: u_azure_status
Type: Choice
Choices:
  - Pending
  - In Progress
  - Completed
  - Failed
  - Error

// Automation Message
Field: u_automation_message
Type: String
Max Length: 255

// Pipeline Build ID
Field: u_pipeline_build_id
Type: String
Max Length: 50

// Execution Details
Field: u_execution_details
Type: String (Long)
Max Length: 8000
```

### 2. Create Business Rules

#### Auto-Generate Request Payload
```javascript
// Business Rule: Generate Azure Request Payload
// Table: u_azure_automation_request
// When: Before Insert/Update
// Condition: u_request_type.changes()

(function executeRule(current, previous /*null when async*/) {
    
    var payload = {};
    
    // Common fields
    payload.requestType = current.u_request_type.toString();
    payload.requestId = current.number.toString();
    payload.requester = current.opened_by.email.toString();
    payload.priority = current.priority.getDisplayValue();
    payload.businessJustification = current.description.toString();
    
    // Request-specific fields based on type
    switch(current.u_request_type.toString()) {
        case 'vm_creation':
            payload.vmSpecs = {
                vmName: current.u_vm_name.toString(),
                subscription: current.u_subscription.toString(),
                resourceGroup: current.u_resource_group.toString(),
                location: current.u_location.toString(),
                vmSize: current.u_vm_size.toString(),
                osType: current.u_os_type.toString(),
                networkConfig: {
                    vnetName: current.u_vnet_name.toString(),
                    subnetName: current.u_subnet_name.toString()
                },
                tags: {
                    Environment: current.u_environment.toString(),
                    Owner: current.opened_by.email.toString(),
                    Project: current.u_project.toString(),
                    CostCenter: current.u_cost_center.toString()
                }
            };
            
            // Approvals
            payload.approvals = {
                managerApproval: current.u_manager_approval == 'approved',
                itSecurityApproval: current.u_security_approval == 'approved',
                changeControlApproval: current.u_change_approval == 'approved'
            };
            break;
            
        case 'user_account':
            payload.accountType = current.u_account_type.toString();
            payload.userDetails = {
                userPrincipalName: current.u_upn.toString(),
                displayName: current.u_display_name.toString(),
                firstName: current.u_first_name.toString(),
                lastName: current.u_last_name.toString(),
                department: current.u_department.toString()
            };
            
            payload.approvals = {
                managerApproval: current.u_manager_approval == 'approved',
                itSecurityApproval: current.u_security_approval == 'approved'
            };
            break;
            
        case 'vm_management':
            payload.operation = current.u_operation.toString();
            
            // Parse target VMs (comma-separated)
            var vmList = current.u_target_vms.toString().split(',');
            payload.targetVMs = [];
            
            for (var i = 0; i < vmList.length; i++) {
                var vmInfo = vmList[i].trim().split('|'); // Format: vmname|resourcegroup|subscription
                if (vmInfo.length >= 3) {
                    payload.targetVMs.push({
                        vmName: vmInfo[0],
                        resourceGroup: vmInfo[1],
                        subscription: vmInfo[2]
                    });
                }
            }
            
            payload.approvals = {
                managerApproval: current.u_manager_approval == 'approved',
                itApproval: current.u_it_approval == 'approved',
                changeControlApproval: current.u_change_approval == 'approved'
            };
            break;
    }
    
    // Store the generated payload
    current.u_request_payload = JSON.stringify(payload);
    
})(current, previous);
```

### 3. Create Workflow

#### Azure Automation Workflow
```javascript
// Workflow: Azure Automation Request
// Table: u_azure_automation_request

// Activity 1: Validate Request
// Type: Script
// Script:
var validation = new AzureValidation();
if (!validation.validateRequest(current)) {
    workflow.scratchpad.validation_error = validation.getError();
    answer = 'invalid';
} else {
    answer = 'valid';
}

// Activity 2: Call Azure DevOps Pipeline
// Type: REST Message
// HTTP Method: POST
// Endpoint: https://dev.azure.com/{organization}/{project}/_apis/pipelines/{pipelineId}/runs
// Authentication: Basic (PAT token)

// Headers:
Content-Type: application/json
Authorization: Basic {base64-encoded-pat}

// Body:
{
    "resources": {
        "repositories": {
            "self": {
                "refName": "refs/heads/main"
            }
        }
    },
    "templateParameters": {
        "requestType": "${current.u_request_type}",
        "manualPayload": "${current.u_request_payload}"
    }
}

// Activity 3: Update Status
// Type: Script
// Script:
current.u_azure_status = 'In Progress';
current.u_pipeline_build_id = response_body.id;
current.update();
```

### 4. Create REST Message for Azure DevOps

```javascript
// REST Message: Azure DevOps Pipeline Trigger
// Name: AzureDevOpsPipelineTrigger

// HTTP Method: POST
// Endpoint: https://dev.azure.com/{organization}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=6.0

// HTTP Headers:
var headers = {
    'Content-Type': 'application/json',
    'Authorization': 'Basic ' + gs.base64Encode('{pat-token}:')
};

// HTTP Request Body:
var requestBody = {
    "resources": {
        "repositories": {
            "self": {
                "refName": "refs/heads/main"
            }
        }
    },
    "templateParameters": {
        "requestType": "${request_type}",
        "manualPayload": "${request_payload}"
    }
};
```

### 5. Create Scheduled Job for Status Updates

```javascript
// Scheduled Job: Azure Pipeline Status Check
// Run Every: 5 minutes

var gr = new GlideRecord('u_azure_automation_request');
gr.addQuery('u_azure_status', 'In Progress');
gr.query();

while (gr.next()) {
    var buildId = gr.u_pipeline_build_id.toString();
    if (buildId) {
        var statusChecker = new AzureDevOpsClient();
        var buildStatus = statusChecker.getBuildStatus(buildId);
        
        if (buildStatus.completed) {
            gr.u_azure_status = buildStatus.result == 'succeeded' ? 'Completed' : 'Failed';
            gr.u_automation_message = buildStatus.message;
            gr.update();
        }
    }
}
```

## Azure DevOps Setup

### 1. Create Variable Groups

#### ServiceNow Integration Variables
```yaml
# Variable Group: servicenow-integration
variables:
  SERVICENOW_INSTANCE: company.service-now.com
  SERVICENOW_USERNAME: $(servicenow-username)  # From Key Vault
  SERVICENOW_PASSWORD: $(servicenow-password)  # From Key Vault
  SMTP_SERVER: smtp.company.com
  SMTP_PORT: 587
  FROM_EMAIL: azure-automation@company.com
```

### 2. Create Service Connections

#### ServiceNow REST API Connection
```json
{
  "name": "ServiceNowAPI",
  "type": "genericEndpoint",
  "url": "https://company.service-now.com",
  "authorization": {
    "scheme": "UsernamePassword",
    "parameters": {
      "username": "integration-user",
      "password": "stored-in-keyvault"
    }
  }
}
```

### 3. Configure Webhook

#### Incoming Webhook Setup
```yaml
# In servicenow-automation-pipeline.yml
resources:
  webhooks:
    - webhook: ServiceNowAutomation
      connection: ServiceNowWebhook
      filters:
        - path: action
          value: azure_automation
        - path: requestType
          value: '*'
```

## ServiceNow Catalog Items

### 1. VM Creation Catalog Item

```javascript
// Catalog Item: Request Azure Virtual Machine
// Category: Cloud Services

// Variables:
var vmNameVar = new GlideRecord('item_option_new');
vmNameVar.initialize();
vmNameVar.cat_item = current.sys_id;
vmNameVar.name = 'vm_name';
vmNameVar.question_text = 'Virtual Machine Name';
vmNameVar.type = 5; // String
vmNameVar.mandatory = true;
vmNameVar.insert();

// Workflow: Submit VM Request to Azure
// On Submit:
var azureRequest = new GlideRecord('u_azure_automation_request');
azureRequest.initialize();
azureRequest.u_request_type = 'vm_creation';
azureRequest.opened_by = current.opened_by;
azureRequest.u_vm_name = current.variables.vm_name;
azureRequest.u_subscription = current.variables.subscription;
azureRequest.u_resource_group = current.variables.resource_group;
azureRequest.state = 1; // New
azureRequest.insert();

// Trigger workflow
workflow.startFlow(azureRequest.sys_id, 'Azure Automation Request');
```

### 2. User Account Catalog Item

```javascript
// Catalog Item: Request User Account
// Category: Identity Management

// Variables for user details, account type, etc.
// Similar structure to VM creation but for user account fields

// On Submit - create u_azure_automation_request record
// with requestType = 'user_account'
```

## Testing the Integration

### 1. Test Request Creation

```javascript
// Test Script: Create Test Request
var testRequest = new GlideRecord('u_azure_automation_request');
testRequest.initialize();
testRequest.u_request_type = 'vm_creation';
testRequest.opened_by = gs.getUserID();
testRequest.u_vm_name = 'test-vm-001';
testRequest.u_subscription = 'BAB_DEV';
testRequest.u_resource_group = 'rg-test';
testRequest.u_location = 'East US';
testRequest.u_vm_size = 'Standard_B2s';
testRequest.u_os_type = 'Windows';
testRequest.u_environment = 'Dev';
testRequest.u_project = 'Test Project';
testRequest.u_cost_center = 'IT-001';
testRequest.u_manager_approval = 'approved';
testRequest.u_security_approval = 'approved';
testRequest.description = 'Test VM for integration testing';
testRequest.insert();

gs.log('Test request created: ' + testRequest.number);
```

### 2. Test Pipeline Trigger

```bash
# Manual pipeline trigger for testing
curl -X POST \
  "https://dev.azure.com/{org}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=6.0" \
  -H "Authorization: Basic $(echo -n ':PAT_TOKEN' | base64)" \
  -H "Content-Type: application/json" \
  -d '{
    "resources": {
      "repositories": {
        "self": {
          "refName": "refs/heads/main"
        }
      }
    },
    "templateParameters": {
      "requestType": "vm_creation",
      "manualPayload": "{\"requestType\":\"vm_creation\",\"requestId\":\"REQ001234\"}"
    }
  }'
```

## Troubleshooting

### Common Issues

1. **Webhook Not Triggering**
   - Check Azure DevOps webhook configuration
   - Verify ServiceNow can reach Azure DevOps endpoints
   - Check authentication credentials

2. **Authentication Failures**
   - Verify PAT token permissions
   - Check ServiceNow user account permissions
   - Validate Azure service principal credentials

3. **JSON Payload Issues**
   - Validate JSON schema in ServiceNow
   - Check for special characters in payload
   - Verify field mappings

### Monitoring and Logging

#### ServiceNow Logging
```javascript
// Custom logging in ServiceNow
gs.log('Azure Integration: ' + message, 'AzureAutomation');
```

#### Azure DevOps Monitoring
- Pipeline run history
- Task logs
- Variable inspection
- Artifact publishing

## Security Considerations

1. **API Authentication**
   - Use service accounts with minimal permissions
   - Rotate credentials regularly
   - Store secrets in Azure Key Vault

2. **Network Security**
   - Implement IP allowlisting if possible
   - Use HTTPS for all communications
   - Monitor API access logs

3. **Data Protection**
   - Sanitize sensitive data in logs
   - Encrypt data in transit
   - Implement audit trails

## Maintenance

### Regular Tasks
- Review and update schemas
- Monitor pipeline performance
- Update authentication credentials
- Review security logs
- Update documentation

### Backup and Recovery
- Export ServiceNow configurations
- Backup pipeline definitions
- Document recovery procedures