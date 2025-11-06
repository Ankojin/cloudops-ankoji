# ServiceNow Workflow Templates

This directory contains ServiceNow workflow definitions and business rules for Azure automation integration.

## Workflow Templates

### 1. Azure VM Creation Workflow

**Purpose**: Automate the approval and provisioning of Azure virtual machines.

**Stages**:
1. Request Validation
2. Manager Approval
3. IT Security Approval
4. Change Control Approval (for production)
5. Azure DevOps Pipeline Trigger
6. Status Monitoring
7. Completion Notification

### 2. User Account Creation Workflow

**Purpose**: Automate Azure AD user account creation and group assignments.

**Stages**:
1. Request Validation
2. Manager Approval
3. IT Security Approval
4. Data Owner Approval (for privileged access)
5. Azure DevOps Pipeline Trigger
6. Account Creation Verification
7. Welcome Email

### 3. VM Management Workflow

**Purpose**: Automate VM lifecycle operations (start, stop, restart, etc.).

**Stages**:
1. Request Validation
2. Business Justification Review
3. Change Control (for production)
4. Maintenance Window Check
5. Azure DevOps Pipeline Trigger
6. Operation Verification
7. Completion Report

## Business Rules

### Auto-Generate Request Payload

Automatically generates the JSON payload required by Azure DevOps pipeline based on form inputs.

### Approval Routing

Routes requests to appropriate approvers based on:
- Request type
- Target environment (Dev/Test/Prod)
- Resource impact level
- Cost implications

### Validation Rules

Validates requests against:
- Naming conventions
- Security policies
- Resource quotas
- Business rules

## Custom Tables

### u_azure_automation_request

Main table for tracking Azure automation requests.

**Key Fields**:
- `u_request_type`: Type of automation request
- `u_request_payload`: JSON payload for Azure DevOps
- `u_azure_status`: Current automation status
- `u_pipeline_build_id`: Azure DevOps build ID
- `u_automation_message`: Status messages
- `u_execution_details`: Detailed execution results

### u_azure_vm_specs

Detailed VM specifications for creation requests.

### u_azure_approvals

Approval tracking for complex requests.

## REST Messages

### Azure DevOps Pipeline Trigger

REST message configuration for triggering Azure DevOps pipelines.

**Endpoint**: `https://dev.azure.com/{org}/{project}/_apis/pipelines/{id}/runs`
**Method**: POST
**Authentication**: Basic (PAT token)

## Scheduled Jobs

### Pipeline Status Monitor

Monitors Azure DevOps pipeline execution and updates ServiceNow records.

**Schedule**: Every 5 minutes
**Function**: Check build status and update request records

### Cleanup Job

Cleans up old automation records and temporary data.

**Schedule**: Daily at 2 AM
**Function**: Archive completed requests older than 90 days

## Integration Points

### Azure DevOps
- Pipeline triggering via REST API
- Build status monitoring
- Artifact retrieval

### Azure Active Directory
- User validation
- Group membership verification
- Permission checks

### Email Systems
- Notification delivery
- Approval requests
- Status updates

## Configuration Variables

### ServiceNow System Properties

```javascript
// Azure Integration Configuration
gs.setProperty('azure.integration.enabled', 'true');
gs.setProperty('azure.devops.org', 'your-organization');
gs.setProperty('azure.devops.project', 'your-project');
gs.setProperty('azure.devops.pipeline.id', 'pipeline-id');
gs.setProperty('azure.devops.pat.token', 'encrypted-token');

// Approval Configuration
gs.setProperty('azure.approval.manager.required', 'true');
gs.setProperty('azure.approval.security.required', 'true');
gs.setProperty('azure.approval.change.prod.required', 'true');

// Notification Configuration
gs.setProperty('azure.notification.email.enabled', 'true');
gs.setProperty('azure.notification.email.from', 'azure-automation@company.com');
```

## Error Handling

### Validation Errors
- Display user-friendly error messages
- Log detailed errors for debugging
- Prevent submission of invalid requests

### Integration Errors
- Retry mechanisms for transient failures
- Fallback to manual processing
- Automatic incident creation

### Business Rule Violations
- Clear violation messages
- Guidance for correction
- Escalation to administrators

## Security Considerations

### Data Protection
- Encrypt sensitive data in payloads
- Mask credentials in logs
- Sanitize user inputs

### Access Control
- Role-based access to workflows
- Approval delegation rules
- Administrative override controls

### Audit Requirements
- Complete audit trail
- Immutable logs
- Retention policies

## Testing

### Unit Tests
Test individual business rules and functions.

### Integration Tests
Test end-to-end workflow execution.

### Performance Tests
Validate system performance under load.

## Deployment

### Development Environment
- Test workflow definitions
- Validate business rules
- User acceptance testing

### Production Environment
- Gradual rollout
- Monitoring and alerting
- Rollback procedures

## Maintenance

### Regular Tasks
- Review and update workflows
- Monitor performance metrics
- Update approval rules
- Refresh integration credentials

### Monitoring
- Workflow execution times
- Error rates and patterns
- User satisfaction metrics
- System resource usage