/**
 * ServiceNow Catalog Item Configuration
 * Purpose: Azure AD User Account and Service Account Request Form
 * Supports: Service Accounts (DEV/SIT only), VDI Access Request, and Normal Account Creation
 */
{
    "name": "Azure AD Account Request",
    "short_description": "Request creation of Azure AD user account or service account",
    "description": "Submit a request to create a new account in Azure Active Directory. Choose between Service Account (DEV/SIT only), VDI Access (BAB/Enjaz/ABIC), or Normal Account without VDI access.",
    "category": "Identity Management",
    "variables": [
        {
            "name": "request_type",
            "type": "Multiple Choice",
            "question": "Account Type *",
            "choices": [
                "Service Account",
                "VDI Access Request - BAB",
                "VDI Access Request - Enjaz",
                "VDI Access Request - ABIC",
                "Normal Account (No VDI) - BAB",
                "Normal Account (No VDI) - Enjaz",
                "Normal Account (No VDI) - ABIC"
            ],
            "mandatory": true,
            "order": 1
        },
        {
            "name": "company",
            "type": "Multiple Choice",
            "question": "Company *",
            "choices": [
                "BAB",
                "ENJAZ",
                "ABIC"
            ],
            "hint": "Select the company for this account (Required)",
            "mandatory": true,
            "order": 2
        },
        
        // ═══════════════════════════════════════════
        // COMMON FIELDS (All Account Types)
        // ═══════════════════════════════════════════
        {
            "name": "display_name",
            "type": "Single Line Text",
            "question": "Display Name *",
            "hint": "Full name as it will appear in Azure AD (e.g., John Smith or Service Account - SQL)",
            "max_length": 256,
            "mandatory": true,
            "order": 3
        },
        {
            "name": "first_name",
            "type": "Single Line Text",
            "question": "First Name *",
            "hint": "Required for UPN generation (e.g., Ankoji Rao or SVC)",
            "max_length": 64,
            "mandatory": true,
            "order": 4
        },
        {
            "name": "last_name",
            "type": "Single Line Text",
            "question": "Last Name *",
            "hint": "Required for UPN generation (e.g., Nagisetty or SQL)",
            "max_length": 64,
            "mandatory": true,
            "order": 5
        },
        
        // ═══════════════════════════════════════════
        // SERVICE ACCOUNT SPECIFIC FIELDS (DEV/SIT ONLY)
        // ═══════════════════════════════════════════
        {
            "name": "project",
            "type": "Single Line Text",
            "question": "Project Name",
            "hint": "Project name for service account (Required for Service Accounts)",
            "max_length": 100,
            "mandatory": false,
            "order": 6,
            "show_when": "request_type=Service Account"
        },
        {
            "name": "application",
            "type": "Single Line Text",
            "question": "Application Name",
            "hint": "Application name for service account (Required for Service Accounts, e.g., SQL, IIS, Exchange)",
            "max_length": 100,
            "mandatory": false,
            "order": 7,
            "show_when": "request_type=Service Account"
        },
        {
            "name": "environment",
            "type": "Multiple Choice",
            "question": "Environment",
            "choices": [
                "dev",
                "sit"
            ],
            "hint": "Select environment - ONLY DEV and SIT available for service accounts",
            "mandatory": false,
            "order": 8,
            "show_when": "request_type=Service Account"
        },
        
        // ═══════════════════════════════════════════
        // USER ACCOUNT SPECIFIC FIELDS
        // ═══════════════════════════════════════════
        {
            "name": "job_title",
            "type": "Single Line Text",
            "question": "Job Title",
            "hint": "Employee's job position (Required for User Accounts)",
            "max_length": 128,
            "mandatory": false,
            "order": 9,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "department",
            "type": "Single Line Text",
            "question": "Department",
            "hint": "Department or business unit (Required for User Accounts)",
            "max_length": 64,
            "mandatory": false,
            "order": 10,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "employee_type",
            "type": "Multiple Choice",
            "question": "Employee Type",
            "choices": [
                "Permanent",
                "Contract",
                "Temporary",
                "Vendor"
            ],
            "hint": "Required for User Accounts",
            "mandatory": false,
            "order": 11,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "manager",
            "type": "Reference",
            "reference_table": "sys_user",
            "question": "Manager",
            "hint": "Select the employee's manager from the list (Required for User Accounts)",
            "mandatory": false,
            "order": 12,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "employee_id",
            "type": "Single Line Text",
            "question": "Employee ID",
            "hint": "Company employee identification number (Required for User Accounts)",
            "max_length": 50,
            "mandatory": false,
            "order": 13,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "location",
            "type": "Single Line Text",
            "question": "Location",
            "hint": "Office location or city (e.g., Riyadh, Dubai) (Required for User Accounts)",
            "max_length": 100,
            "mandatory": false,
            "order": 14,
            "hide_when": "request_type=Service Account"
        },
        {
            "name": "vendor",
            "type": "Single Line Text",
            "question": "Vendor",
            "hint": "Vendor name (required if Employee Type is 'Vendor')",
            "max_length": 100,
            "mandatory": false,
            "order": 15,
            "hide_when": "request_type=Service Account"
        },
        
        // ═══════════════════════════════════════════
        // OPTIONAL FIELDS (All Account Types)
        // ═══════════════════════════════════════════
        {
            "name": "target_group",
            "type": "Single Line Text",
            "question": "Target Azure AD Group (Optional)",
            "hint": "Leave empty for default group assignment (serviceaccount for Service Accounts, company-specific for User Accounts)",
            "max_length": 256,
            "mandatory": false,
            "order": 16
        },
        {
            "name": "business_justification",
            "type": "Multi Line Text",
            "question": "Business Justification *",
            "hint": "Explain why this account is needed",
            "mandatory": true,
            "order": 17
        }
    ],
    "workflow": "Azure AD Account Provisioning Workflow",
    "fulfillment_group": "Cloud Operations Team",
    
    // Client Script for conditional mandatory fields and environment restriction
    "client_script": {
        "type": "onChange",
        "field": "request_type",
        "script": `
function onChange(control, oldValue, newValue, isLoading) {
    if (isLoading || newValue == '') {
        return;
    }
    
    var isServiceAccount = (newValue == 'Service Account');
    
    // Service Account fields
    g_form.setMandatory('project', isServiceAccount);
    g_form.setMandatory('application', isServiceAccount);
    g_form.setMandatory('environment', isServiceAccount);
    
    // User Account fields
    g_form.setMandatory('job_title', !isServiceAccount);
    g_form.setMandatory('department', !isServiceAccount);
    g_form.setMandatory('employee_type', !isServiceAccount);
    g_form.setMandatory('manager', !isServiceAccount);
    g_form.setMandatory('employee_id', !isServiceAccount);
    g_form.setMandatory('location', !isServiceAccount);
    
    // Show/hide sections with environment restriction message
    if (isServiceAccount) {
        g_form.addInfoMessage('Service Account UPN Format: svc_environment_application(3)@test.com');
        g_form.addInfoMessage('⚠️ Service Accounts: Only DEV and SIT environments are allowed');
    } else {
        g_form.addInfoMessage('User Account UPN Format: FirstName(3)+LastName(3)-Company(1)@test.com');
    }
}
        `
    },
    
    // Client Script for employee_type onChange
    "client_script": {
        "type": "onChange",
        "field": "employee_type",
        "script": `
function onChange(control, oldValue, newValue, isLoading) {
    if (isLoading || newValue == '') {
        return;
    }
    
    var isVendor = (newValue == 'Vendor');
    g_form.setMandatory('vendor', isVendor);
    
    if (isVendor) {
        g_form.addInfoMessage('⚠️ Vendor name is required when Employee Type is Vendor');
    }
}
        `
    }
}