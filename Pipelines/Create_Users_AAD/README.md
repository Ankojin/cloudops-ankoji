# 🚀 Azure AD User Management Pipeline - Complete Guide

## 📋 Table of Contents
- [Overview](#-overview)
- [Quick Start](#-quick-start)
- [Operation Types](#-operation-types)
- [CSV File Preparation](#-csv-file-preparation)
- [Step-by-Step Guides](#-step-by-step-guides)
- [Troubleshooting](#-troubleshooting)
- [Best Practices](#-best-practices)

---

## 🎯 Overview

The BAB CloudOps team has developed this Azure DevOps pipeline to streamline Azure AD user management operations across our banking environment. Our solution supports:
- ✅ Service account creation for applications and automation
- ✅ AVD (Azure Virtual Desktop) user provisioning for remote workers
- ✅ Admin Studio user-group assignments for banking application access
- ✅ ABIC user management for new employee onboarding and existing user updates

**Key Features Implemented by Our Team:**
- Comprehensive password complexity validation
- Built-in retry logic for enhanced reliability
- Detailed operational logging and audit trails
- Rollback-safe operations to prevent data corruption
- Efficient CSV-based bulk operations for large-scale user management

## 🏢 Environment Information

**Current Environment:** BAB (Bank Albilad) Azure AD Tenant  
**Domain:** `albtests.com`  
**Service Principal:** Managed via `cloud-subs` variable group  
**Agent Pool:** `cloudops-agent`  

**Supported User Types:**
- Service Accounts (automation/applications)
- AVD Users (Azure Virtual Desktop access)  
- Admin Studio Users (banking application access)
- ABIC Users (internal banking employees with full HR profiles)

## 👥 About This Documentation

This comprehensive guide was created and is maintained by the BAB CloudOps Engineering Team. Our team has extensive experience in Azure AD management, PowerShell automation, and banking compliance requirements. We continuously update this documentation based on operational experience and user feedback to ensure it remains accurate and helpful for our organization's needs.

---

## ⚡ Quick Start

### Prerequisites
Our team has configured the following requirements for pipeline execution:

1. **Azure DevOps Access**: Team members need appropriate permissions to run pipelines in our BAB CloudOps project
2. **Variable Group**: Our CloudOps team maintains the `cloud-subs` variable group with:
   - `AZURE_CLIENT_ID` (Service Principal App ID)
   - `AZURE_CLIENT_SECRET` (Secure client secret)
   - `AZURE_TENANT_ID` (BAB Azure AD tenant identifier)
3. **Service Principal Permissions** (configured by our team):
   - `User.ReadWrite.All` - Create and modify user accounts
   - `Group.ReadWrite.All` - Manage group memberships
   - `Directory.ReadWrite.All` - Full directory access for user provisioning

### Running the Pipeline
Follow these steps to execute user management operations:

1. Navigate to **Pipelines** → **Create-User-AAD** in our Azure DevOps project
2. Click **Run pipeline** to start a new execution
3. Select your **operation type** (1-5) based on your user management needs
4. Fill in the **required parameters** specific to your chosen operation
5. Click **Run** to begin execution and monitor progress in real-time

---

## 🎭 Operation Types

### 1️⃣ Create Service Account (GUI Input)
**Use Case:** Create a single service account with specific credentials

**Required Parameters:**
- Service Account UPN (e.g., `svc-app@contoso.com`)
- Display Name (e.g., `Service Account - App`)
- Password (secure, meets complexity)
- Target Group (optional, defaults to `ALBTests service accounts`)

**CSV Files:** ❌ None required

**Example Use Case:**
```
Creating service account for Azure Function App authentication
UPN: svc-azfunc-prod@albtests.com
Group: Azure Service Accounts
```

---

### 2️⃣ Create Normal AVD Users
**Use Case:** Bulk create AVD users and assign to shared desktop pool

**Required Parameters:**
- AVD Target Group (optional, defaults to `BAB_VDI_DT_Shared_Pool`)

**CSV Files:** ✅ Required
- Users CSV: [`Pipelines/Create_Users_AAD/AVD-users.csv`](./AVD-users.csv)

**CSV Format:**
```csv
DisplayName,UserPrincipalName,Password
John Doe,john.doe@albtests.com,P@ssw0rd123!
Jane Smith,jane.smith@albtests.com,Str0ng@Pass456
```

**Example Use Case:**
```
Onboarding 50 new contractors to shared AVD environment
All users added to: BAB_VDI_DT_Shared_Pool
```

---

### 3️⃣ Add Existing Admin Studio Users to Groups
**Use Case:** Assign existing Admin Studio users to Admin Studio security groups

**Required Parameters:**
- Confirmation checkbox ✔️ (safety check)

**CSV Files:** ✅ Required (both)
- Users CSV: [`Pipelines/Create_Users_AAD/Admin-studio-users.csv`](./Admin-studio-users.csv)
- Groups CSV: [`Pipelines/Create_Users_AAD/Admin-Studio-Groups.csv`](./Admin-Studio-Groups.csv)

**CSV Format:**

**Users CSV:**
```csv
UserPrincipalName
admin.user1@contoso.com
admin.user2@contoso.com
```

**Groups CSV:**
```csv
GroupName
Admin-Studio-Viewers
Admin-Studio-Editors
Admin-Studio-Admins
```

**Example Use Case:**
```
Grant Admin Studio access to 3 IT administrators
Users: admin1, admin2, admin3
Groups: Admin-Studio-Editors, Admin-Studio-Admins
```

---

### 4️⃣ Create New ABIC Users with Full Profile
**Use Case:** Create new ABIC users with complete organizational profile

**Required Parameters:**
- Confirmation checkbox ✔️ (safety check)

**CSV Files:** ✅ Required (both)
- Users CSV: [`Pipelines/Create_Users_AAD/ABIC-Users.csv`](./ABIC-Users.csv)
- Groups CSV: [`Pipelines/Create_Users_AAD/ABIC-Groups.csv`](./ABIC-Groups.csv)

**CSV Format:**

**Users CSV (Extended Profile):**
```csv
DisplayName,UserPrincipalName,MailNickName,Password,First name,Last name,Job Title,Company name,Department,Employee Type,Manager,Employee ID
John Doe,john.doe@contoso.com,johndoe,P@ssw0rd123!,John,Doe,Senior Analyst,ABIC,Finance,Permanent,manager@contoso.com,
```

**Groups CSV:**
```csv
GroupName
ABIC-Finance-Standard
ABIC-Finance-Approvers
ABIC-Risk-Viewers
```

**Example Use Case:**
```
Onboarding 25 new ABIC employees with full HR profile
Each user assigned to department-specific groups
Manager relationships established
```

---

### 5️⃣ Add Existing ABIC Users to Groups
**Use Case:** Assign existing ABIC users to new security groups (e.g., role changes)

**Required Parameters:**
- Confirmation checkbox ✔️ (safety check)

**CSV Files:** ✅ Required (both)
- Users CSV: [`Pipelines/Create_Users_AAD/ABIC-Existing-Users.csv`](./ABIC-Existing-Users.csv)
- Groups CSV: [`Pipelines/Create_Users_AAD/ABIC-Groups.csv`](./ABIC-Groups.csv)

**CSV Format:**

**Users CSV:**
```csv
UserPrincipalName
existing.user1@contoso.com
existing.user2@contoso.com
```

**Groups CSV:**
```csv
GroupName
ABIC-New-Application-Access
ABIC-Elevated-Permissions
```

**Example Use Case:**
```
Promotion: 5 analysts → senior analyst role
Add to: ABIC-Senior-Analyst-Access group
No new user creation needed
```

---

## 📁 CSV File Preparation

### CSV File Locations (Hardcoded)
```
Pipelines/Create_Users_AAD/
├── AVD-users.csv              (Operation 2)
├── Admin-studio-users.csv     (Operation 3)
├── Admin-Studio-Groups.csv    (Operation 3)
├── ABIC-Users.csv             (Operation 4)
├── ABIC-Groups.csv            (Operations 4 & 5)
└── ABIC-Existing-Users.csv    (Operation 5)
```

### Password Complexity Requirements

All passwords must meet **Azure AD complexity**:
- ✅ Minimum 8 characters
- ✅ At least 1 uppercase letter (A-Z)
- ✅ At least 1 lowercase letter (a-z)
- ✅ At least 1 number (0-9)
- ✅ At least 1 special character (!@#$%^&*(),.?":{}|<>)

**Valid Examples:**
```
P@ssw0rd123!
Str0ng@Pass456
C0mplex!Pass789
SecureP@ss2024
```

**Invalid Examples:**
```
password123      ❌ (no uppercase, no special char)
PASSWORD!        ❌ (no lowercase, no number)
Pass123          ❌ (too short, no special char)
```

### CSV Validation Checklist

Before running the pipeline:
- [ ] CSV file exists in correct path
- [ ] CSV uses comma separator
- [ ] Column headers match exactly (case-sensitive)
- [ ] No extra spaces in column headers
- [ ] No empty rows
- [ ] UPNs are valid email format (`user@domain.com`)
- [ ] Passwords meet complexity requirements
- [ ] Groups exist in Azure AD (for assignments)
- [ ] Users exist in Azure AD (for existing user operations)

---

## 📖 Step-by-Step Guides

### Guide 1: Creating a Service Account

**Scenario:** Create service account for automation

1. **Open Pipeline**
   - Navigate to: Pipelines → Create-User-AAD
   - Click: **Run pipeline**

2. **Configure Parameters**
   ```
   Operation Type: Create Service Account
   
   Service Account UPN: svc-automation@contoso.com
   Display Name: Service Account - Automation
   Password: AutoM@tion2024!
   Target Group: [Leave empty for default]
   ```

3. **Review & Run**
   - Verify UPN format
   - Confirm password is secure
   - Click **Run**

4. **Monitor Execution**
   - Watch pipeline progress
   - Check logs for confirmation
   - Verify in Azure AD portal

**Expected Result:**
```
✅ Service account created: svc-automation@contoso.com
✅ Added to group: ALBTests service accounts
✅ Password policy: Disabled expiration
```

---

### Guide 2: Bulk AVD User Creation

**Scenario:** Onboard 20 contractors to AVD

1. **Prepare CSV File**
   - Edit: `Pipelines/Create_Users_AAD/AVD-users.csv`
   - Add 20 rows with user details
   - Validate passwords meet complexity

2. **Commit CSV to Repository**
   ```bash
   git add Pipelines/Create_Users_AAD/AVD-users.csv
   git commit -m "Add 20 AVD contractor users"
   git push
   ```

3. **Run Pipeline**
   ```
   Operation Type: Create Normal AVD Users
   AVD Target Group: [Leave empty for default]
   ```

4. **Verify Results**
   - Check pipeline logs: `20/20 users created`
   - Azure AD Portal: Users exist
   - AVD Group: 20 new members

**Expected Result:**
```
✅ Total: 20 | Success: 20 | Failed: 0 | Skipped: 0
✅ All users added to: BAB_VDI_DT_Shared_Pool
```

---

### Guide 3: Admin Studio Assignments

**Scenario:** Grant Admin Studio access to 3 IT admins

1. **Prepare CSV Files**

**Admin-studio-users.csv:**
```csv
UserPrincipalName
it.admin1@albtests.com
it.admin2@albtests.com
it.admin3@albtests.com
```

**Admin-Studio-Groups.csv:**
```csv
GroupName
Albilad_Branch
Reports_printing_HQ
ROLE_BRANCH_SUPERVISOR
```

2. **Commit Both CSVs**
   ```bash
   git add Pipelines/Create_Users_AAD/Admin-studio-users.csv Pipelines/Create_Users_AAD/Admin-Studio-Groups.csv
   git commit -m "Admin Studio access for 3 IT admins"
   git push
   ```

3. **Run Pipeline**
   ```
   Operation Type: Add Existing Admin Studio Users...
   Confirm Operation: ✔️ Check this box
   ```

4. **Verify Results**
   - Each user assigned to both groups
   - Total mappings: 3 users × 2 groups = 6 operations

**Expected Result:**
```
✅ Total Mappings: 6 | Success: 6 | Failed: 0
✅ it.admin1 → Albilad_Branch, Reports_printing_HQ
✅ it.admin2 → Albilad_Branch, Reports_printing_HQ  
✅ it.admin3 → Albilad_Branch, Reports_printing_HQ
```

---

### Guide 4: ABIC User Onboarding

**Scenario:** Onboard 10 new ABIC employees with full profiles

1. **Prepare ABIC-Users.csv**
   - Include all required fields (12 columns)
   - Populate HR data (job title, department, manager)
   - Ensure manager UPNs exist in Azure AD

**Example Row:**
```csv
DisplayName,UserPrincipalName,MailNickName,Password,First name,Last name,Job Title,Company name,Department,Employee Type,Manager,Employee ID
Sarah Johnson,sarah.johnson@albtests.com,sjohnson,Welc0me@ABIC,Sarah,Johnson,Financial Analyst,ABIC,Finance,Permanent,finance.mgr@albtests.com,E002345
```

2. **Prepare ABIC-Groups.csv**
```csv
GroupName
ABIC_AML_ADMIN
ABIC_AMS_ADMIN
ABIC_AMS_COMPLIANCE
```

3. **Commit CSVs**
   ```bash
   git add Pipelines/Create_Users_AAD/ABIC-*.csv
   git commit -m "Onboard 10 ABIC Finance employees"
   git push
   ```

4. **Run Pipeline**
   ```
   Operation Type: Create New ABIC Users...
   Confirm Operation: ✔️ Check this box
   ```

5. **Verify Results**
   - 10 users created with full profiles
   - Each user in 3 groups (30 group memberships)
   - Manager relationships established

**Expected Result:**
```
✅ Total: 10 | Success: 10 | Failed: 0 | Skipped: 0
✅ sarah.johnson@albtests.com created
✅   Job Title: Financial Analyst
✅   Manager: finance.mgr@albtests.com
✅   Groups: ABIC_AML_ADMIN, ABIC_AMS_ADMIN, ABIC_AMS_COMPLIANCE
```

---

## 🔧 Troubleshooting

### Common Issues & Solutions

#### Issue 1: "CSV file not found"

**Error Message:**
```
ERROR: Users CSV file not found: Pipelines/Create_Users_AAD/AVD-users.csv
```

**Solution:**
1. Verify file exists in repository:
   ```bash
   ls Pipelines/Create_Users_AAD/
   ```
2. Check file name matches exactly (case-sensitive)
3. Ensure file is committed to repository
4. Verify file path in pipeline variables

---

#### Issue 2: "Missing required columns"

**Error Message:**
```
ERROR: Missing required columns: Password. Expected: DisplayName, UserPrincipalName, Password
```

**Solution:**
1. Open CSV in Excel/text editor
2. Compare column headers with required list
3. Ensure exact spelling (case-sensitive)
4. Remove extra spaces in headers
5. Save and commit changes

**Before (Incorrect):**
```csv
DisplayName, UserPrincipalName, Pwd
```

**After (Correct):**
```csv
DisplayName,UserPrincipalName,Password
```

---

#### Issue 3: "Password validation failed"

**Error Message:**
```
ERROR: Password must contain uppercase letter
```

**Solution:**
Check password against all requirements:
```powershell
# Valid password checker
$password = "YourPassword"

if ($password.Length -lt 8) { "❌ Too short" }
if ($password -notmatch '[A-Z]') { "❌ No uppercase" }
if ($password -notmatch '[a-z]') { "❌ No lowercase" }
if ($password -notmatch '[0-9]') { "❌ No number" }
if ($password -notmatch '[!@#$%^&*(),.?":{}|<>]') { "❌ No special char" }
```

**Fix Example:**
```
Incorrect: password123      → Add uppercase & special: P@ssword123!
Incorrect: PASSWORD!        → Add lowercase & number: P@ssw0rd!
Incorrect: Pass123          → Add special char: P@ss123!
```

---

#### Issue 4: "Group not found"

**Error Message:**
```
ERROR: ABIC group not found: ABIC-Finance-Standard
```

**Solution:**
1. Verify group exists in Azure AD Portal
2. Check exact group name (case-sensitive)
3. Ensure no typos in CSV
4. Service principal must have permissions

**Verification Command:**
```powershell
# Check if group exists
Get-MgGroup -Filter "displayName eq 'ABIC-Finance-Standard'"
```

---

#### Issue 5: "User not found" (for existing user operations)

**Error Message:**
```
ERROR: Admin Studio user not found: admin.user1@contoso.com
```

**Solution:**
1. Verify user exists in Azure AD Portal
2. Check UPN spelling and format
3. User must be active (not deleted/disabled)
4. Ensure correct tenant

**Verification Command:**
```powershell
# Check if user exists
Get-MgUser -Filter "userPrincipalName eq 'admin.user1@contoso.com'"
```

---

#### Issue 6: "Failed to connect to Microsoft Graph"

**Error Message:**
```
ERROR: Failed to connect to Microsoft Graph: Invalid client secret
```

**Solution:**
1. Check variable group `cloud-subs`:
   - `AZURE_CLIENT_ID` (not expired)
   - `AZURE_CLIENT_SECRET` (valid)
   - `AZURE_TENANT_ID` (correct tenant)
2. Verify service principal exists
3. Confirm permissions granted
4. Check secret expiration date

**Verification Steps:**
```bash
# Azure Portal
1. Azure Active Directory → App registrations
2. Find service principal by client ID
3. Check "Certificates & secrets"
4. Verify API permissions
```

---

#### Issue 7: "Some user operations failed"

**Error Message:**
```
WARNING: Some user operations failed. Check logs for details.
Total: 20 | Success: 18 | Failed: 2 | Skipped: 0
```

**Solution:**
1. Download pipeline logs artifact
2. Search for "ERROR" entries
3. Identify specific user failures
4. Fix CSV issues for failed users
5. Re-run pipeline with only failed users

**Log Analysis Example:**
```
[ERROR] Error processing user john.doe@contoso.com: Password validation failed
[ERROR] Error processing user jane.smith@contoso.com: Invalid UPN format
```

**Fix:**
- Update john.doe's password to meet complexity
- Correct jane.smith's UPN format

---

### Debug Mode

Enable detailed logging for troubleshooting:

1. **Modify script parameter:**
   ```powershell
   $DebugPreference = 'Continue'
   ```

2. **Check verbose logs in pipeline:**
   - Validation Stage logs
   - Execution Stage logs
   - Published artifacts

3. **Look for key indicators:**
   ```
   [INFO] Processing user: john.doe@contoso.com
   [DEBUG] Attempt 1 of 3 for: Create user
   [WARN] User already exists: john.doe@contoso.com
   [SUCCESS] Added to group: ABIC-Finance-Standard
   ```

---

## ✅ Best Practices

### Security Best Practices

1. **Password Management:**
   - ✅ Use strong, unique passwords for all user accounts
   - ✅ Store service account credentials securely (never commit plain text)
   - ✅ Rotate service account passwords quarterly
   - ✅ Enable MFA for all admin accounts

2. **Service Principal:**
   - ✅ Use least-privilege permissions (only required Graph API scopes)
   - ✅ Rotate client secrets every 90 days
   - ✅ Monitor service principal activity via Azure AD sign-in logs
   - ✅ Use separate service principals for dev/test/prod environments

3. **CSV File Security:**
   - ✅ Delete CSV files containing passwords after successful execution
   - ✅ Use `.gitignore` for sensitive CSV files if they must be stored
   - ✅ Encrypt CSV files if long-term storage is required
   - ✅ Audit CSV file access and modifications
   - ✅ Never commit production passwords to source control

4. **Banking Compliance:**
   - ✅ Follow BAB security policies for user provisioning
   - ✅ Ensure proper segregation of duties for user creation
   - ✅ Maintain audit trails for all user management operations
   - ✅ Verify manager approvals before bulk user creation

---

### Operational Best Practices

Our CloudOps team recommends the following operational procedures:

1. **Testing Approach:**
   - ✅ Always test with 1-2 users first before bulk operations
   - ✅ Use dedicated test accounts in non-production environments
   - ✅ Verify group memberships post-execution through Azure AD Portal
   - ✅ Test rollback procedures in development environment

2. **CSV Preparation Guidelines:**
   - ✅ Validate CSV format using Excel or text editor before committing
   - ✅ Use Excel formula validation for UPN format verification
   - ✅ Review all passwords meet our complexity requirements
   - ✅ Remove empty rows and columns to prevent processing errors

3. **Monitoring and Verification:**
   - ✅ Review pipeline logs after each run for success confirmation
   - ✅ Monitor Azure AD sign-in logs for new user verification
   - ✅ Track group membership changes through audit logs
   - ✅ Set up alerts for pipeline failures and investigate promptly

4. **Documentation and Change Management:**
   - ✅ Document group purpose and membership criteria in our wiki
   - ✅ Maintain user onboarding runbooks with current procedures
   - ✅ Track all bulk operations in our change management log
   - ✅ Update CSV templates as business requirements evolve

---

### Bulk Operation Best Practices

1. **Batch Size:**
   - ✅ Process 50 users per run (recommended)
   - ✅ Split large batches (500+) into multiple runs
   - ✅ Allow 5-10 minutes between batches

2. **Error Handling:**
   - ✅ Review failed users before retry
   - ✅ Extract failed users to new CSV
   - ✅ Fix root cause before retry
   - ✅ Monitor retry success rate

3. **Verification:**
   - ✅ Spot-check random users post-execution
   - ✅ Verify group memberships in Azure AD
   - ✅ Test user sign-in (if applicable)
   - ✅ Confirm manager relationships

---

## 📊 Pipeline Variables Reference

### Variable Group: `cloud-subs`

| Variable Name | Description | Example |
|--------------|-------------|---------|
| `AZURE_CLIENT_ID` | Service Principal App ID | `12345678-1234-1234-1234-123456789abc` |
| `AZURE_CLIENT_SECRET` | Service Principal Secret | `your-secret-value` |
| `AZURE_TENANT_ID` | Azure AD Tenant ID | `87654321-4321-4321-4321-cba987654321` |

### Pipeline Variables (Built-in)

| Variable Name | Default Value | Override? | Description |
|--------------|---------------|-----------|-------------|
| `defaultServiceAccountGroup` | `ALBTests service accounts` | ✅ Yes | Default group for service accounts |
| `defaultAVDGroup` | `BAB_VDI_DT_Shared_Pool` | ✅ Yes | Default group for AVD users |
| `logPath` | `C:\log` | ✅ Yes | Log file directory |
| `logFileName` | `user_management_log.txt` | ✅ Yes | Log file name |
| `avdUsersCsvPath` | `Pipelines/Create_Users_AAD/AVD-users.csv` | ❌ No | AVD users CSV path (hardcoded) |
| `adminStudioUsersCsvPath` | `Pipelines/Create_Users_AAD/Admin-studio-users.csv` | ❌ No | Admin Studio users CSV |
| `adminStudioGroupsCsvPath` | `Pipelines/Create_Users_AAD/Admin-Studio-Groups.csv` | ❌ No | Admin Studio groups CSV |
| `abicNewUsersCsvPath` | `Pipelines/Create_Users_AAD/ABIC-Users.csv` | ❌ No | New ABIC users CSV |
| `abicGroupsCsvPath` | `Pipelines/Create_Users_AAD/ABIC-Groups.csv` | ❌ No | ABIC groups CSV |
| `abicExistingUsersCsvPath` | `Pipelines/Create_Users_AAD/ABIC-Existing-Users.csv` | ❌ No | Existing ABIC users CSV |

---

## 🆘 Getting Help

### Internal Support

**BAB CloudOps Team:**
- Teams Channel: `BAB CloudOps`
- Documentation: [BAB CloudOps Repository](https://github.com/Ankojin/BAB_CloudOps)
- Pipeline: [Create User AAD Pipeline](https://dev.azure.com/BAB/CloudOps/_build?definitionId=xxx)

### Escalation Process

Our CloudOps team has established the following support escalation process:

1. **Level 1 - Self-Service (User Responsibility):**
   - Review this comprehensive README documentation
   - Check the Troubleshooting section for common issues
   - Review pipeline execution logs for error details

2. **Level 2 - Team Support (BAB CloudOps Team):**
   - Post in Teams `BAB CloudOps` channel for team assistance
   - Include pipeline run ID and operation type
   - Attach relevant error logs or screenshots

3. **Level 3 - Senior Engineer Escalation:**
   - Create Azure DevOps incident in BAB CloudOps project
   - Attach complete logs, CSV samples, and error details
   - Provide business impact assessment and urgency level
   - Our senior engineers will respond based on priority

---

## 📞 Quick Reference Card

### Operation Quick Guide

| Need to... | Use Operation | CSV Files | Key Parameters |
|-----------|---------------|-----------|----------------|
| Create single service account | #1 | ❌ None | UPN, Password, Group |
| Onboard AVD users | #2 | ✅ AVD-users.csv | AVD Group |
| Grant Admin Studio access | #3 | ✅ Users + Groups CSV | Confirmation checkbox |
| Onboard ABIC employees | #4 | ✅ Users + Groups CSV | Confirmation checkbox |
| Reassign ABIC users | #5 | ✅ Users + Groups CSV | Confirmation checkbox |

### Password Complexity Quick Check
```
✅ 8+ characters
✅ Uppercase (A-Z)
✅ Lowercase (a-z)
✅ Number (0-9)
✅ Special (!@#$...)
```

### CSV Locations Quick Reference
```
Pipelines/Create_Users_AAD/
├── AVD-users.csv
├── Admin-studio-users.csv
├── Admin-Studio-Groups.csv
├── ABIC-Users.csv
├── ABIC-Groups.csv
└── ABIC-Existing-Users.csv
```

---

## 📝 Change Log

Our CloudOps team maintains this version history:

| Version | Date | Changes | Author |
|---------|------|---------|---------|
| 1.0.0 | 2024-01-15 | Initial pipeline development and release | CloudOps Team |
| 1.1.0 | 2024-02-01 | Added ABIC user management operations | CloudOps Team |
| 1.2.0 | 2024-03-10 | Enhanced error handling & retry logic implementation | CloudOps Team |
| 1.3.0 | 2025-11-07 | Updated documentation and corrected file references | CloudOps Team |

---

## 📜 Maintenance & Support

**Developed and Maintained by:** BAB CloudOps Engineering Team  
**Documentation Last Updated:** 2025-11-07  
**Support Level:** Production Environment (24/7 Coverage)  
**Internal Repository:** BAB_CloudOps on GitHub

**Related Microsoft Documentation:**
- [Azure Active Directory Best Practices](https://learn.microsoft.com/en-us/azure/active-directory)
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph)

**Related Documentation:**
- [Azure AD Best Practices](https://learn.microsoft.com/en-us/azure/active-directory)
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph)
- [Service Principal Management](https://learn.microsoft.com/en-us/azure/active-directory/develop/app-objects-and-service-principals)

---

**Questions or Issues?** Contact the BAB CloudOps Engineering Team via our Teams channel or create an Azure DevOps work item in the BAB CloudOps project. Our team is committed to providing timely support for all user management operations.