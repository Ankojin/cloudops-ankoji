/**
 * ServiceNow System Properties Configuration
 * 
 * Purpose: Configure integration settings for Azure DevOps and Azure AD
 * 
 * Setup Instructions:
 * 1. Navigate to: System Properties > New
 * 2. Create each property below
 * 3. For 'password' type properties, ensure encryption is enabled
 * 4. Test connectivity after configuration
 * 
 * Version: 4.2
 * Last Updated: 2025-10-31
 */

[
  // ═══════════════════════════════════════════
  // ServiceNow Integration Credentials
  // ═══════════════════════════════════════════
  {
    name: 'servicenow.instance',
    value: 'your-instance.service-now.com',
    description: 'ServiceNow instance URL (without https://). Example: dev12345.service-now.com',
    category: 'ServiceNow Integration',
    mandatory: true
  },
  {
    name: 'servicenow.username',
    value: 'integration_user',
    description: 'ServiceNow integration service account username with REST API access',
    category: 'ServiceNow Integration',
    mandatory: true
  },
  {
    name: 'servicenow.password',
    value: 'encrypted-password',
    description: 'ServiceNow integration service account password (automatically encrypted)',
    type: 'password',
    category: 'ServiceNow Integration',
    mandatory: true
  },
  
  // ═══════════════════════════════════════════
  // Azure DevOps Configuration
  // ═══════════════════════════════════════════
  {
    name: 'ado.organization',
    value: 'your-organization',
    description: 'Azure DevOps organization name (from URL: dev.azure.com/{organization})',
    category: 'Azure DevOps',
    mandatory: true
  },
  {
    name: 'ado.project',
    value: 'BAB_CloudOps',
    description: 'Azure DevOps project name containing the AAD user creation pipeline',
    category: 'Azure DevOps',
    mandatory: true
  },
  {
    name: 'ado.aad.pipeline.id',
    value: '123',
    description: 'Pipeline ID for Azure AD user creation pipeline (numeric)',
    category: 'Azure DevOps',
    mandatory: true
  },
  {
    name: 'ado.pat',
    value: 'encrypted-token',
    description: 'Azure DevOps Personal Access Token with Build (Execute) permissions (automatically encrypted)',
    type: 'password',
    category: 'Azure DevOps',
    mandatory: true
  },
  
  // ═══════════════════════════════════════════
  // Azure AD Configuration
  // ═══════════════════════════════════════════
  {
    name: 'azure.ad.domain',
    value: 'test.com',
    description: 'Unified domain for UPN generation (used for BAB, ENJAZ, and ABIC)',
    category: 'Azure AD',
    mandatory: true
  },
  {
    name: 'azure.ad.tenant.id',
    value: 'your-tenant-id-guid',
    description: 'Azure AD Tenant ID (GUID format)',
    category: 'Azure AD',
    mandatory: true
  },
  
  // ═══════════════════════════════════════════
  // Retry and Performance Settings
  // ═══════════════════════════════════════════
  {
    name: 'ado.max.retries',
    value: '3',
    description: 'Maximum retry attempts for pipeline trigger failures',
    category: 'Performance',
    mandatory: false
  },
  {
    name: 'ado.retry.delay',
    value: '5000',
    description: 'Delay between retry attempts in milliseconds (default: 5000ms = 5 seconds)',
    category: 'Performance',
    mandatory: false
  },
  {
    name: 'ado.timeout',
    value: '30000',
    description: 'HTTP request timeout in milliseconds (default: 30000ms = 30 seconds)',
    category: 'Performance',
    mandatory: false
  },
  
  // ═══════════════════════════════════════════
  // Service Account Configuration
  // ═══════════════════════════════════════════
  {
    name: 'service.account.allowed.environments',
    value: 'dev,sit',
    description: 'Comma-separated list of allowed environments for service accounts (default: dev,sit)',
    category: 'Service Accounts',
    mandatory: false
  },
  {
    name: 'service.account.default.group',
    value: 'serviceaccount',
    description: 'Default Azure AD group for service accounts',
    category: 'Service Accounts',
    mandatory: false
  },
  
  // ═══════════════════════════════════════════
  // User Account Default Groups
  // ═══════════════════════════════════════════
  {
    name: 'user.account.bab.default.group',
    value: 'BAB_VDI_DT_Shared_Pool',
    description: 'Default Azure AD group for BAB user accounts with VDI access',
    category: 'User Accounts',
    mandatory: false
  },
  {
    name: 'user.account.enjaz.default.group',
    value: 'Enjaz_Users',
    description: 'Default Azure AD group for Enjaz user accounts',
    category: 'User Accounts',
    mandatory: false
  },
  {
    name: 'user.account.abic.default.group',
    value: 'ABIC_Users',
    description: 'Default Azure AD group for ABIC user accounts',
    category: 'User Accounts',
    mandatory: false
  },
  
  // ═══════════════════════════════════════════
  // Audit and Logging
  // ═══════════════════════════════════════════
  {
    name: 'audit.logging.enabled',
    value: 'true',
    description: 'Enable audit logging for all account creation operations',
    category: 'Audit',
    mandatory: false
  },
  {
    name: 'audit.log.retention.days',
    value: '90',
    description: 'Number of days to retain audit logs (default: 90 days)',
    category: 'Audit',
    mandatory: false
  }
]

/**
 * Setup Checklist:
 * 
 * 1. ServiceNow Configuration:
 *    □ Create integration user with REST API permissions
 *    □ Configure system properties above
 *    □ Test ServiceNow connectivity
 * 
 * 2. Azure DevOps Configuration:
 *    □ Generate PAT token with Build (Execute) permissions
 *    □ Note pipeline ID from pipeline URL
 *    □ Configure ADO system properties
 * 
 * 3. Azure AD Configuration:
 *    □ Verify tenant ID
 *    □ Confirm domain name (test.com)
 *    □ Validate group names exist in Azure AD
 * 
 * 4. Testing:
 *    □ Test service account creation (DEV environment)
 *    □ Test user account creation (each company)
 *    □ Verify ServiceNow callback updates RITM
 *    □ Confirm audit logging works
 * 
 * 5. Security Review:
 *    □ Ensure password fields are encrypted
 *    □ Review service account permissions
 *    □ Configure secret rotation policy
 *    □ Enable audit logging
 */