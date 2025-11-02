/**
 * ServiceNow Flow: Trigger Azure DevOps Pipeline for AAD User Creation
 * 
 * Purpose: Automate Azure AD user and service account provisioning from ServiceNow requests
 * 
 * UPN Generation:
 * - Regular Users: FirstName(3)+LastName(3)-Company(1)@test.com
 * - Service Accounts: svc_Environment_Application(3)@test.com
 * 
 * Service Account Environments: DEV, SIT only
 * 
 * Examples:
 * - BAB User: ANKNAG-B@test.com
 * - Service Account: svc_dev_sql@test.com, svc_sit_sql@test.com
 * 
 * Version: 4.1
 * Last Updated: 2025-10-31
 */

(function executeFlow(inputs, outputs) {
    var gs = new GlideSystem();
    var requestProcessor = new AzureADRequestProcessor();
    
    try {
        var ritm = inputs.ritm;
        
        // Validate RITM object
        if (!ritm || !ritm.isValidRecord()) {
            throw new Error('Invalid request item provided');
        }
        
        // Process the request
        var result = requestProcessor.processRequest(ritm);
        
        // Set outputs
        outputs.success = result.success;
        outputs.pipelineRunId = result.pipelineRunId;
        outputs.pipelineRunUrl = result.pipelineRunUrl;
        outputs.generatedUPN = result.generatedUPN;
        outputs.errorMessage = result.errorMessage || '';
        
    } catch (e) {
        gs.error('Flow Execution Error: ' + e.message + '\nStack: ' + e.stack);
        outputs.success = false;
        outputs.errorMessage = e.message;
    }
    
})(inputs, outputs);

/**
 * Azure AD Request Processor Class
 */
var AzureADRequestProcessor = Class.create();
AzureADRequestProcessor.prototype = {
    
    initialize: function() {
        this.gs = new GlideSystem();
        this.config = this._loadConfiguration();
        this.domain = this.config.domain || 'test.com';
    },
    
    /**
     * Load configuration from system properties
     */
    _loadConfiguration: function() {
        return {
            adoOrganization: this.gs.getProperty('ado.organization'),
            adoProject: this.gs.getProperty('ado.project'),
            adoPipelineId: this.gs.getProperty('ado.aad.pipeline.id'),
            adoPAT: this.gs.getProperty('ado.pat'),
            domain: this.gs.getProperty('azure.ad.domain') || 'test.com',
            maxRetries: parseInt(this.gs.getProperty('ado.max.retries') || '3'),
            retryDelay: parseInt(this.gs.getProperty('ado.retry.delay') || '5000')
        };
    },
    
    /**
     * Main request processing method
     */
    processRequest: function(ritm) {
        try {
            // Extract and validate request data
            var requestData = this._extractRequestData(ritm);
            var isServiceAccount = requestData.requestType === 'Service Account';
            
            // Validate based on account type
            if (isServiceAccount) {
                this._validateServiceAccountFields(requestData);
            } else {
                this._validateUserAccountFields(requestData);
            }
            
            // Generate UPN based on account type
            var credentials = isServiceAccount ? 
                this._generateServiceAccountUPN(requestData) : 
                this._generateUserUPN(requestData);
                
            requestData.upn = credentials.upn;
            requestData.mailNickname = credentials.mailNickname;
            requestData.domain = credentials.domain;
            
            // Determine operation type
            var operationType = this._mapOperationType(requestData.requestType);
            var hasVDIAccess = requestData.requestType.indexOf('VDI Access Request') !== -1;
            
            // Build pipeline parameters
            var pipelineParams = this._buildPipelineParameters(
                requestData, 
                operationType, 
                hasVDIAccess, 
                ritm,
                isServiceAccount
            );
            
            // Trigger Azure DevOps Pipeline
            var pipelineResult = this._triggerPipeline(pipelineParams);
            
            // Update RITM with results
            this._updateRITM(ritm, requestData, pipelineResult, true, isServiceAccount);
            
            return {
                success: true,
                pipelineRunId: pipelineResult.runId,
                pipelineRunUrl: pipelineResult.runUrl,
                generatedUPN: requestData.upn
            };
            
        } catch (e) {
            this.gs.error('Request Processing Error: ' + e.message);
            this._updateRITM(ritm, null, null, false, false, e.message);
            return {
                success: false,
                errorMessage: e.message
            };
        }
    },
    
    /**
     * Extract request data from RITM
     */
    _extractRequestData: function(ritm) {
        var requestType = this._getVariableValue(ritm, 'request_type');
        var isServiceAccount = requestType === 'Service Account';
        
        if (isServiceAccount) {
            // Service Account fields
            return {
                requestType: requestType,
                displayName: this._getVariableValue(ritm, 'display_name'),
                firstName: this._getVariableValue(ritm, 'first_name').trim(),
                lastName: this._getVariableValue(ritm, 'last_name').trim(),
                company: this._getVariableValue(ritm, 'company'),
                project: this._getVariableValue(ritm, 'project'),
                application: this._getVariableValue(ritm, 'application'),
                environment: this._getVariableValue(ritm, 'environment'),
                targetGroup: this._getVariableValue(ritm, 'target_group') || '',
                businessJustification: this._getVariableValue(ritm, 'business_justification')
            };
        } else {
            // Regular User Account fields
            return {
                requestType: requestType,
                company: this._getVariableValue(ritm, 'company'),
                firstName: this._getVariableValue(ritm, 'first_name').trim(),
                lastName: this._getVariableValue(ritm, 'last_name').trim(),
                displayName: this._getVariableValue(ritm, 'display_name'),
                jobTitle: this._getVariableValue(ritm, 'job_title'),
                department: this._getVariableValue(ritm, 'department'),
                employeeType: this._getVariableValue(ritm, 'employee_type'),
                manager: this._getVariableValue(ritm, 'manager'),
                employeeId: this._getVariableValue(ritm, 'employee_id'),
                location: this._getVariableValue(ritm, 'location'),
                vendor: this._getVariableValue(ritm, 'vendor') || '',
                targetGroup: this._getVariableValue(ritm, 'target_group') || '',
                businessJustification: this._getVariableValue(ritm, 'business_justification')
            };
        }
    },
    
    /**
     * Get variable value from RITM
     */
    _getVariableValue: function(ritm, variableName) {
        try {
            var value = ritm.variables[variableName];
            return value ? value.toString() : '';
        } catch (e) {
            this.gs.warn('Failed to get variable ' + variableName + ': ' + e.message);
            return '';
        }
    },
    
    /**
     * Validate service account mandatory fields
     */
    _validateServiceAccountFields: function(data) {
        var requiredFields = [
            { field: 'displayName', name: 'Display Name' },
            { field: 'firstName', name: 'First Name' },
            { field: 'lastName', name: 'Last Name' },
            { field: 'company', name: 'Company' },
            { field: 'project', name: 'Project' },
            { field: 'application', name: 'Application' },
            { field: 'environment', name: 'Environment' }
        ];
        
        var missingFields = [];
        
        for (var i = 0; i < requiredFields.length; i++) {
            var field = requiredFields[i];
            if (!data[field.field] || data[field.field] === '') {
                missingFields.push(field.name);
            }
        }
        
        if (missingFields.length > 0) {
            throw new Error('Missing mandatory service account fields: ' + missingFields.join(', '));
        }
        
        // Validate company value
        var validCompanies = ['BAB', 'ENJAZ', 'ABIC'];
        if (validCompanies.indexOf(data.company.toUpperCase()) === -1) {
            throw new Error('Invalid company. Must be BAB, ENJAZ, or ABIC');
        }
        
        // Validate environment - ONLY DEV and SIT allowed for service accounts
        var validEnvironments = ['dev', 'sit'];
        var environment = data.environment.toLowerCase();
        
        if (validEnvironments.indexOf(environment) === -1) {
            throw new Error('Invalid environment for service account. Only DEV and SIT are allowed. Provided: ' + data.environment);
        }
        
        this.gs.info('Service account environment validated: ' + environment.toUpperCase());
    },
    
    /**
     * Validate user account mandatory fields
     */
    _validateUserAccountFields: function(data) {
        var requiredFields = [
            { field: 'company', name: 'Company' },
            { field: 'firstName', name: 'First Name' },
            { field: 'lastName', name: 'Last Name' },
            { field: 'displayName', name: 'Display Name' },
            { field: 'jobTitle', name: 'Job Title' },
            { field: 'department', name: 'Department' },
            { field: 'employeeType', name: 'Employee Type' },
            { field: 'manager', name: 'Manager' },
            { field: 'employeeId', name: 'Employee ID' },
            { field: 'location', name: 'Location' }
        ];
        
        var missingFields = [];
        
        for (var i = 0; i < requiredFields.length; i++) {
            var field = requiredFields[i];
            if (!data[field.field] || data[field.field] === '') {
                missingFields.push(field.name);
            }
        }
        
        if (missingFields.length > 0) {
            throw new Error('Missing mandatory fields: ' + missingFields.join(', '));
        }
        
        // Validate company value
        var validCompanies = ['BAB', 'ENJAZ', 'ABIC'];
        if (validCompanies.indexOf(data.company.toUpperCase()) === -1) {
            throw new Error('Invalid company. Must be BAB, ENJAZ, or ABIC');
        }
        
        // Validate vendor for vendor employees
        if (data.employeeType === 'Vendor' && (!data.vendor || data.vendor === '')) {
            throw new Error('Vendor name is required for Vendor employee type');
        }
    },
    
    /**
     * Generate Service Account UPN
     * 
     * Format: svc_environment_application(3)@domain
     * Environments: DEV, SIT only
     * Examples: svc_dev_sql@test.com, svc_sit_iis@test.com
     */
    _generateServiceAccountUPN: function(data) {
        var environment = data.environment.toLowerCase();
        var application = data.application.replace(/\s+/g, '').substring(0, 3).toLowerCase();
        
        var mailNickname = 'svc_' + environment + '_' + application;
        var upn = mailNickname + '@' + this.domain;
        
        this.gs.info('Generated Service Account UPN: ' + upn + 
                    ' (Environment: ' + environment.toUpperCase() + ', Application: ' + data.application + ')');
        
        return {
            upn: upn,
            mailNickname: mailNickname,
            domain: this.domain
        };
    },
    
    /**
     * Generate User Account UPN
     * 
     * Format: FirstName(3)+LastName(3)-Company(1)@domain
     * Example: ANKNAG-B@test.com
     */
    _generateUserUPN: function(data) {
        // Remove all spaces from first and last name
        var firstName = data.firstName.replace(/\s+/g, '');
        var lastName = data.lastName.replace(/\s+/g, '');
        var company = data.company.toUpperCase();
        
        // Extract first 3 letters from first name (uppercase)
        var firstNamePrefix = firstName.substring(0, Math.min(3, firstName.length)).toUpperCase();
        
        // Extract first 3 letters from last name (uppercase)
        var lastNamePrefix = lastName.substring(0, Math.min(3, lastName.length)).toUpperCase();
        
        // Extract first letter of company (uppercase)
        var companyPrefix = company.substring(0, 1).toUpperCase();
        
        // Build UPN: ANKNAG-B@test.com
        var mailNickname = firstNamePrefix + lastNamePrefix + '-' + companyPrefix;
        var upn = mailNickname + '@' + this.domain;
        
        this.gs.info('Generated User UPN for ' + company + ': ' + upn + 
                    ' (from ' + firstName + ' ' + lastName + ')');
        
        return {
            upn: upn,
            mailNickname: mailNickname,
            domain: this.domain
        };
    },
    
    /**
     * Map ServiceNow request type to pipeline operation type
     */
    _mapOperationType: function(requestType) {
        var operationMap = {
            'Service Account': 'Create Service Account',
            'VDI Access Request - BAB': 'Create BAB Users with VDI',
            'VDI Access Request - Enjaz': 'Create Enjaz Users with VDI',
            'VDI Access Request - ABIC': 'Create ABIC Users with VDI',
            'Normal Account (No VDI) - BAB': 'Create BAB Users',
            'Normal Account (No VDI) - Enjaz': 'Create Enjaz Users',
            'Normal Account (No VDI) - ABIC': 'Create New ABIC Users and Add to ABIC Groups'
        };
        
        var operationType = operationMap[requestType];
        if (!operationType) {
            throw new Error('Invalid request type: ' + requestType);
        }
        
        return operationType;
    },
    
    /**
     * Build pipeline parameters
     */
    _buildPipelineParameters: function(data, operationType, hasVDI, ritm, isServiceAccount) {
        var params = {
            operationType: operationType,
            company: data.company,
            hasVDIAccess: hasVDI.toString(),
            serviceNowRequestNumber: ritm.number.toString(),
            serviceNowRequestId: ritm.sys_id.toString(),
            singleUserMode: 'true',
            isServiceAccount: isServiceAccount.toString(),
            
            // Common fields
            singleUserUPN: data.upn,
            singleUserMailNickname: data.mailNickname,
            singleUserPassword: isServiceAccount ? '' : this._generateSecurePassword(),
            isServiceAccountPasswordNeverExpires: isServiceAccount.toString(),
            singleUserDisplayName: data.displayName,
            singleUserFirstName: data.firstName,
            singleUserLastName: data.lastName,
            targetGroup: data.targetGroup,
            businessJustification: data.businessJustification
        };
        
        if (isServiceAccount) {
            // Service Account specific fields
            params.serviceAccountProject = data.project;
            params.serviceAccountApplication = data.application;
            params.serviceAccountEnvironment = data.environment;
            params.singleUserCompany = data.company;
        } else {
            // User Account specific fields
            params.singleUserJobTitle = data.jobTitle;
            params.singleUserCompany = data.company;
            params.singleUserDepartment = data.department;
            params.singleUserEmployeeType = data.employeeType;
            params.singleUserManager = data.manager;
            params.singleUserEmployeeId = data.employeeId;
            params.singleUserLocation = data.location;
            params.singleUserVendor = data.vendor;
        }
        
        return params;
    },
    
    /**
     * Generate secure password for user accounts
     */
    _generateSecurePassword: function() {
        var length = 16;
        var uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        var lowercase = 'abcdefghijklmnopqrstuvwxyz';
        var numbers = '0123456789';
        var special = '!@#$%^&*';
        var allChars = uppercase + lowercase + numbers + special;
        
        var password = '';
        
        // Ensure at least one of each type
        password += uppercase.charAt(Math.floor(Math.random() * uppercase.length));
        password += lowercase.charAt(Math.floor(Math.random() * lowercase.length));
        password += numbers.charAt(Math.floor(Math.random() * numbers.length));
        password += special.charAt(Math.floor(Math.random() * special.length));
        
        // Fill remaining with random characters
        for (var i = 4; i < length; i++) {
            password += allChars.charAt(Math.floor(Math.random() * allChars.length));
        }
        
        // Shuffle password
        password = password.split('').sort(function() { 
            return 0.5 - Math.random(); 
        }).join('');
        
        return password;
    },
    
    /**
     * Trigger Azure DevOps Pipeline with retry logic
     */
    _triggerPipeline: function(params) {
        var maxRetries = this.config.maxRetries;
        var retryDelay = this.config.retryDelay;
        var lastError = null;
        
        for (var attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                this.gs.info('Pipeline trigger attempt ' + attempt + ' of ' + maxRetries);
                
                var request = new sn_ws.RESTMessageV2();
                request.setHttpMethod('POST');
                request.setEndpoint(
                    'https://dev.azure.com/' + this.config.adoOrganization + '/' +
                    this.config.adoProject + '/_apis/pipelines/' + 
                    this.config.adoPipelineId + '/runs?api-version=7.0'
                );
                
                // Set headers
                request.setRequestHeader('Content-Type', 'application/json');
                request.setRequestHeader(
                    'Authorization', 
                    'Basic ' + this.gs.base64Encode(':' + this.config.adoPAT)
                );
                
                // Build request body
                var requestBody = {
                    templateParameters: params,
                    resources: {
                        repositories: {
                            self: {
                                refName: 'refs/heads/main'
                            }
                        }
                    }
                };
                
                request.setRequestBody(JSON.stringify(requestBody));
                
                // Execute request
                var response = request.execute();
                var httpStatus = response.getStatusCode();
                var responseBody = response.getBody();
                
                this.gs.info('Pipeline trigger response - Status: ' + httpStatus);
                
                if (httpStatus == 200 || httpStatus == 201) {
                    var responseObj = JSON.parse(responseBody);
                    return {
                        runId: responseObj.id,
                        runUrl: responseObj._links.web.href
                    };
                } else {
                    lastError = 'HTTP ' + httpStatus + ': ' + responseBody;
                    this.gs.warn('Pipeline trigger failed on attempt ' + attempt + ': ' + lastError);
                    
                    if (attempt < maxRetries) {
                        this.gs.sleep(retryDelay);
                    }
                }
                
            } catch (e) {
                lastError = e.message;
                this.gs.error('Pipeline trigger exception on attempt ' + attempt + ': ' + lastError);
                
                if (attempt < maxRetries) {
                    this.gs.sleep(retryDelay);
                }
            }
        }
        
        throw new Error('Failed to trigger pipeline after ' + maxRetries + ' attempts. Last error: ' + lastError);
    },
    
    /**
     * Update RITM with results
     */
    _updateRITM: function(ritm, requestData, pipelineResult, success, isServiceAccount, errorMessage) {
        try {
            if (success && requestData && pipelineResult) {
                var workNotes = isServiceAccount ? 
                    this._buildServiceAccountSuccessNotes(requestData, pipelineResult) :
                    this._buildUserAccountSuccessNotes(requestData, pipelineResult);
                
                ritm.work_notes = workNotes;
                ritm.u_ado_pipeline_run_id = pipelineResult.runId;
                ritm.u_ado_pipeline_url = pipelineResult.runUrl;
                ritm.u_company = requestData.company;
                ritm.u_generated_upn = requestData.upn;
                ritm.u_account_type = isServiceAccount ? 'Service Account' : 'User Account';
                
                if (!isServiceAccount) {
                    ritm.u_employee_id = requestData.employeeId;
                    ritm.u_has_vdi_access = requestData.requestType.indexOf('VDI') !== -1;
                }
                
                ritm.state = 2; // Work in Progress
                
            } else {
                ritm.work_notes = this._buildErrorNotes(errorMessage);
                ritm.state = 4; // Failed
            }
            
            ritm.update();
            
        } catch (e) {
            this.gs.error('Failed to update RITM: ' + e.message);
        }
    },
    
    /**
     * Build success work notes for service accounts
     */
    _buildServiceAccountSuccessNotes: function(data, pipeline) {
        var notes = 'Azure DevOps Pipeline triggered successfully.\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Service Account Details:\n';
        notes += '  Account Type: Service Account\n';
        notes += '  Display Name: ' + data.displayName + '\n';
        notes += '  Company: ' + data.company + '\n';
        notes += '  Project: ' + data.project + '\n';
        notes += '  Application: ' + data.application + '\n';
        notes += '  Environment: ' + data.environment.toUpperCase() + ' (DEV/SIT only)\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Generated Credentials:\n';
        notes += '  UPN: ' + data.upn + '\n';
        notes += '  Mail Nickname: ' + data.mailNickname + '\n';
        notes += '  Domain: ' + data.domain + '\n';
        notes += '  UPN Format: svc_environment_application(3)@domain\n';
        notes += '  Allowed Environments: DEV, SIT\n';
        notes += '  Example: svc_dev_sql@test.com, svc_sit_iis@test.com\n';
        notes += '  Password: No expiry configured\n';
        notes += '  Target Group: serviceaccount\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Pipeline Information:\n';
        notes += '  Run ID: ' + pipeline.runId + '\n';
        notes += '  URL: ' + pipeline.runUrl + '\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Next Steps:\n';
        notes += '  1. Monitor pipeline execution\n';
        notes += '  2. Service account credentials will be provided via secure channel\n';
        notes += '  3. Password never expires policy applied\n';
        
        return notes;
    },
    
    /**
     * Build success work notes for user accounts
     */
    _buildUserAccountSuccessNotes: function(data, pipeline) {
        var notes = 'Azure DevOps Pipeline triggered successfully.\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'User Account Details:\n';
        notes += '  Company: ' + data.company + '\n';
        notes += '  Employee: ' + data.firstName + ' ' + data.lastName + '\n';
        notes += '  Employee ID: ' + data.employeeId + '\n';
        notes += '  Job Title: ' + data.jobTitle + '\n';
        notes += '  Department: ' + data.department + '\n';
        notes += '  Location: ' + data.location + '\n';
        notes += '  Manager: ' + data.manager + '\n';
        notes += '  Employee Type: ' + data.employeeType + '\n';
        if (data.vendor) {
            notes += '  Vendor: ' + data.vendor + '\n';
        }
        notes += '═══════════════════════════════════════════\n';
        notes += 'Generated Credentials:\n';
        notes += '  UPN: ' + data.upn + '\n';
        notes += '  Mail Nickname: ' + data.mailNickname + '\n';
        notes += '  Domain: ' + data.domain + '\n';
        notes += '  UPN Format: FirstName(3)+LastName(3)-Company(1)@domain\n';
        notes += '  Example: ' + data.mailNickname + '@' + data.domain + '\n';
        notes += '  Password: Will be sent separately via secure channel\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Pipeline Information:\n';
        notes += '  Run ID: ' + pipeline.runId + '\n';
        notes += '  URL: ' + pipeline.runUrl + '\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Next Steps:\n';
        notes += '  1. Monitor pipeline execution\n';
        notes += '  2. Credentials will be provided upon successful completion\n';
        notes += '  3. User will receive welcome email with access instructions\n';
        
        return notes;
    },
    
    /**
     * Build error work notes
     */
    _buildErrorNotes: function(errorMessage) {
        var notes = 'ERROR: Failed to trigger Azure DevOps pipeline.\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Error Details:\n';
        notes += errorMessage + '\n';
        notes += '═══════════════════════════════════════════\n';
        notes += 'Action Required:\n';
        notes += '  1. Review error details above\n';
        notes += '  2. Contact Cloud Operations team\n';
        notes += '  3. Provide request number for investigation\n';
        
        return notes;
    },
    
    type: 'AzureADRequestProcessor'
};