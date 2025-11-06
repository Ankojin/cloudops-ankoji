// ServiceNow Business Rules for Azure AD User Integration

// Auto-Generate User Account Creation Payload
// Business Rule: Generate User Account Payload
// Table: u_azure_automation_request
// When: Before Insert/Update
// Condition: u_request_type == 'user_account'

(function executeRule(current, previous /*null when async*/) {
    
    if (current.u_request_type != 'user_account') {
        return;
    }
    
    try {
        var payload = {
            requestType: 'user_account',
            requestId: current.number.toString(),
            requester: current.opened_by.email.toString(),
            priority: current.priority.getDisplayValue(),
            businessJustification: current.description.toString(),
            accountType: current.u_account_type.toString(),
            
            userDetails: {
                userPrincipalName: current.u_upn.toString(),
                displayName: current.u_display_name.toString(),
                firstName: current.u_first_name.toString(),
                lastName: current.u_last_name.toString(),
                department: current.u_department.toString(),
                jobTitle: current.u_job_title.toString(),
                manager: current.u_manager_email.toString(),
                location: current.u_location.toString(),
                phoneNumber: current.u_phone_number.toString()
            },
            
            approvals: {
                managerApproval: current.u_manager_approval == 'approved',
                itSecurityApproval: current.u_security_approval == 'approved',
                dataOwnerApproval: current.u_data_owner_approval == 'approved'
            }
        };
        
        // Add service account specific details
        if (current.u_account_type == 'service_account') {
            payload.serviceAccountDetails = {
                serviceName: current.u_service_name.toString(),
                applicationOwner: current.u_app_owner_email.toString(),
                passwordExpiryDays: parseInt(current.u_password_expiry_days.toString()) || 90,
                keyVaultName: current.u_keyvault_name.toString() || 'kv-company-secrets'
            };
        }
        
        // Add AVD configuration if applicable
        if (current.u_account_type == 'avd_user') {
            payload.avdConfiguration = {
                hostPoolName: current.u_host_pool.toString(),
                applicationGroups: current.u_app_groups.toString().split(','),
                workspaceAccess: current.u_workspace_access == true
            };
        }
        
        // Add group memberships
        if (current.u_group_memberships.toString()) {
            var groups = current.u_group_memberships.toString().split(';');
            payload.groupMemberships = [];
            
            for (var i = 0; i < groups.length; i++) {
                var groupInfo = groups[i].split(','); // Format: groupName,justification
                if (groupInfo.length >= 2) {
                    payload.groupMemberships.push({
                        groupName: groupInfo[0].trim(),
                        groupType: 'Security',
                        membershipType: 'Member',
                        justification: groupInfo[1].trim()
                    });
                }
            }
        }
        
        // Add permissions if specified
        if (current.u_azure_roles.toString()) {
            var roles = current.u_azure_roles.toString().split(';');
            payload.permissions = {
                azureRoles: []
            };
            
            for (var i = 0; i < roles.length; i++) {
                var roleInfo = roles[i].split(','); // Format: roleName,scope,justification
                if (roleInfo.length >= 3) {
                    payload.permissions.azureRoles.push({
                        roleName: roleInfo[0].trim(),
                        scope: roleInfo[1].trim(),
                        justification: roleInfo[2].trim()
                    });
                }
            }
        }
        
        // Add access requirements
        payload.accessRequirements = {
            mfaRequired: current.u_mfa_required == true || true, // Default to true
            allowedLocations: current.u_allowed_locations.toString().split(','),
            deviceRequirements: {
                requireCompliantDevice: current.u_require_compliant_device == true || true,
                requireHybridAzureADJoinedDevice: current.u_require_hybrid_join == true || false
            }
        };
        
        // Add account expiry if specified
        if (current.u_account_expiry.toString()) {
            payload.accountExpiry = current.u_account_expiry.toString();
        }
        
        // Store the generated payload
        current.u_request_payload = JSON.stringify(payload, null, 2);
        
        gs.info('Azure User Account payload generated for request: ' + current.number);
        
    } catch (e) {
        gs.error('Error generating user account payload: ' + e.message);
        current.u_automation_message = 'Payload generation failed: ' + e.message;
    }
    
})(current, previous);

// Validation Business Rule
// Business Rule: Validate Azure User Request
// Table: u_azure_automation_request
// When: Before Insert/Update
// Condition: Always

(function executeRule(current, previous /*null when async*/) {
    
    var validator = new AzureUserRequestValidator();
    var validationResult = validator.validateRequest(current);
    
    if (!validationResult.isValid) {
        gs.addErrorMessage('Request validation failed: ' + validationResult.errors.join(', '));
        current.setAbortAction(true);
        return;
    }
    
    // Additional business-specific validations for user accounts
    if (current.u_request_type == 'user_account') {
        // Check UPN uniqueness
        var existingUser = new GlideRecord('sys_user');
        existingUser.addQuery('email', current.u_upn.toString());
        existingUser.query();
        
        if (existingUser.hasNext()) {
            gs.addErrorMessage('User with UPN ' + current.u_upn.toString() + ' already exists');
            current.setAbortAction(true);
            return;
        }
        
        // Check service account naming convention
        if (current.u_account_type == 'service_account') {
            var upn = current.u_upn.toString();
            if (!upn.startsWith('svc-')) {
                gs.addErrorMessage('Service account UPN must start with "svc-" prefix');
                current.setAbortAction(true);
                return;
            }
        }
        
        // Validate required approvals for privileged accounts
        if (current.u_group_memberships.toString().toLowerCase().indexOf('admin') >= 0 ||
            current.u_group_memberships.toString().toLowerCase().indexOf('privileged') >= 0) {
            
            if (current.u_data_owner_approval != 'approved') {
                gs.addErrorMessage('Privileged account requests require data owner approval');
                current.setAbortAction(true);
                return;
            }
        }
        
        // Check account expiry for temporary accounts
        if (current.u_account_expiry.toString()) {
            var expiryDate = new GlideDateTime(current.u_account_expiry.toString());
            var now = new GlideDateTime();
            
            if (expiryDate.compareTo(now) <= 0) {
                gs.addErrorMessage('Account expiry date must be in the future');
                current.setAbortAction(true);
                return;
            }
        }
    }
    
})(current, previous);

// Script Include: AzureUserRequestValidator
var AzureUserRequestValidator = Class.create();
AzureUserRequestValidator.prototype = {
    initialize: function() {
    },
    
    validateRequest: function(record) {
        var errors = [];
        
        // Common validations
        if (!record.opened_by) {
            errors.push('Requester is required');
        }
        
        if (!record.u_request_type) {
            errors.push('Request type is required');
        }
        
        if (!record.description) {
            errors.push('Business justification is required');
        }
        
        // User account specific validations
        if (record.u_request_type.toString() == 'user_account') {
            errors = errors.concat(this._validateUserAccount(record));
        }
        
        return {
            isValid: errors.length === 0,
            errors: errors
        };
    },
    
    _validateUserAccount: function(record) {
        var errors = [];
        
        if (!record.u_account_type) {
            errors.push('Account type is required');
        }
        
        if (!record.u_upn) {
            errors.push('User Principal Name is required');
        } else if (!this._isValidEmail(record.u_upn.toString())) {
            errors.push('User Principal Name must be a valid email address');
        }
        
        if (!record.u_display_name) {
            errors.push('Display name is required');
        }
        
        if (!record.u_first_name) {
            errors.push('First name is required');
        }
        
        if (!record.u_last_name) {
            errors.push('Last name is required');
        }
        
        // Service account specific validations
        if (record.u_account_type == 'service_account') {
            if (!record.u_service_name) {
                errors.push('Service name is required for service accounts');
            }
            
            if (!record.u_app_owner_email) {
                errors.push('Application owner email is required for service accounts');
            }
        }
        
        // AVD user specific validations
        if (record.u_account_type == 'avd_user') {
            if (!record.u_host_pool) {
                errors.push('Host pool is required for AVD users');
            }
        }
        
        return errors;
    },
    
    _isValidEmail: function(email) {
        var emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        return emailRegex.test(email);
    },
    
    type: 'AzureUserRequestValidator'
};

// Approval Routing Business Rule
// Business Rule: Route User Account Approvals
// Table: u_azure_automation_request  
// When: After Insert
// Condition: state == 'New' AND u_request_type == 'user_account'

(function executeRule(current, previous /*null when async*/) {
    
    var approvalRouter = new AzureUserApprovalRouter();
    approvalRouter.routeApprovals(current);
    
})(current, previous);

// Script Include: AzureUserApprovalRouter
var AzureUserApprovalRouter = Class.create();
AzureUserApprovalRouter.prototype = {
    initialize: function() {
    },
    
    routeApprovals: function(request) {
        var accountType = request.u_account_type.toString();
        var priority = request.priority.toString();
        
        // Manager approval (always required)
        this._createApproval(request, 'manager', request.opened_by.manager);
        
        // IT Security approval (always required for user accounts)
        this._createApproval(request, 'it_security', this._getSecurityApprover());
        
        // Additional approvals based on account type
        if (accountType == 'service_account') {
            // Service accounts need additional security review
            this._createApproval(request, 'service_account_review', this._getServiceAccountApprover());
        }
        
        if (this._isPrivilegedAccount(request)) {
            // Privileged accounts need data owner approval
            this._createApproval(request, 'data_owner', this._getDataOwnerApprover(request));
        }
        
        if (accountType == 'avd_user') {
            // AVD users need workspace admin approval
            this._createApproval(request, 'avd_admin', this._getAVDAdminApprover());
        }
        
        if (this._hasAzureRoleAssignments(request)) {
            // Azure role assignments need cloud admin approval
            this._createApproval(request, 'cloud_admin', this._getCloudAdminApprover());
        }
    },
    
    _createApproval: function(request, approvalType, approver) {
        if (!approver) {
            gs.error('No approver found for approval type: ' + approvalType);
            return;
        }
        
        var approval = new GlideRecord('sysapproval_approver');
        approval.initialize();
        approval.document_id = request.sys_id;
        approval.source_table = 'u_azure_automation_request';
        approval.approver = approver;
        approval.state = 'requested';
        approval.u_approval_type = approvalType;
        approval.insert();
        
        gs.info('Created ' + approvalType + ' approval for request ' + request.number);
    },
    
    _getSecurityApprover: function() {
        return 'azure.security@company.com';
    },
    
    _getServiceAccountApprover: function() {
        return 'service.accounts@company.com';
    },
    
    _getDataOwnerApprover: function(request) {
        // Determine data owner based on request details
        return 'data.owner@company.com';
    },
    
    _getAVDAdminApprover: function() {
        return 'avd.admin@company.com';
    },
    
    _getCloudAdminApprover: function() {
        return 'cloud.admin@company.com';
    },
    
    _isPrivilegedAccount: function(request) {
        var groups = request.u_group_memberships.toString().toLowerCase();
        return groups.indexOf('admin') >= 0 || 
               groups.indexOf('privileged') >= 0 ||
               groups.indexOf('security') >= 0;
    },
    
    _hasAzureRoleAssignments: function(request) {
        return request.u_azure_roles && request.u_azure_roles.toString().length > 0;
    },
    
    type: 'AzureUserApprovalRouter'
};