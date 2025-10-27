# Azure AD User Management - CSV File Guide

## CSV File Locations and Formats

### 1. AVD Users CSV
**Path:** `Pipelines/Azure_AD_User_Management/CSV/AVD-users.csv`  
**Operation:** Create Normal AVD Users and Add to Hardcoded Group  
**Target Group:** `BAB_VDI_DT_Shared_Pool` (hardcoded)

**Required Columns:**
```csv
DisplayName,UserPrincipalName,Password
John Doe,john.doe@contoso.com,P@ssw0rd123!
Jane Smith,jane.smith@contoso.com,Str0ng@Pass456
```

**Column Descriptions:**
- `DisplayName`: User's full display name
- `UserPrincipalName`: User's email/UPN (must be valid format)
- `Password`: Initial password (min 8 chars, must contain uppercase, lowercase, number, special char)

---

### 2. Admin Studio Users CSV
**Path:** `Pipelines/Azure_AD_User_Management/CSV/Admin-Studio-Users.csv`  
**Operation:** Add Existing Admin Studio Users to Admin Studio Groups

**Required Columns:**
```csv
UserPrincipalName,GroupName
admin.user1@contoso.com,Admin-Studio-Viewers
admin.user2@contoso.com,Admin-Studio-Editors
admin.user3@contoso.com,Admin-Studio-Admins
```

**Column Descriptions:**
- `UserPrincipalName`: Existing user's email/UPN
- `GroupName`: Target Admin Studio group name (must exist in Azure AD)

---

### 3. New ABIC Users CSV
**Path:** `Pipelines/Azure_AD_User_Management/CSV/ABIC-Users.csv`  
**Operation:** Create New ABIC Users and Add to ABIC Groups

**Required Columns:**
```csv
DisplayName,UserPrincipalName,Password,GroupName
ABIC User 1,abic.user1@contoso.com,P@ssw0rd123!,ABIC-Standard-Users
ABIC User 2,abic.user2@contoso.com,Str0ng@Pass456,ABIC-Power-Users
ABIC User 3,abic.user3@contoso.com,C0mplex!Pass789,ABIC-Admins
```

**Column Descriptions:**
- `DisplayName`: User's full display name
- `UserPrincipalName`: User's email/UPN (must be valid format)
- `Password`: Initial password (min 8 chars, must contain uppercase, lowercase, number, special char)
- `GroupName`: Target ABIC group name (must exist in Azure AD)

---

### 4. Existing ABIC Users CSV
**Path:** `Pipelines/Azure_AD_User_Management/CSV/ABIC-Existing-Users.csv`  
**Operation:** Add Existing ABIC Users to ABIC Groups

**Required Columns:**
```csv
UserPrincipalName,GroupName
existing.abic1@contoso.com,ABIC-Standard-Users
existing.abic2@contoso.com,ABIC-Power-Users
existing.abic3@contoso.com,ABIC-Admins
```

**Column Descriptions:**
- `UserPrincipalName`: Existing user's email/UPN
- `GroupName`: Target ABIC group name (must exist in Azure AD)

---

## Password Requirements

All passwords must meet the following complexity requirements:
- ✅ Minimum 8 characters
- ✅ At least one uppercase letter (A-Z)
- ✅ At least one lowercase letter (a-z)
- ✅ At least one number (0-9)
- ✅ At least one special character (!@#$%^&*(),.?":{}|<>)

**Examples of valid passwords:**
- `P@ssw0rd123!`
- `Str0ng@Pass456`
- `C0mplex!Pass789`

---

## Using Custom CSV Paths

You can override the default CSV paths by providing a custom path in the pipeline parameter:

**Example:** `Pipelines/Custom/MyUsers.csv`

The path should be relative to the repository root.

---

## Pre-requisites

Before running the pipeline:

1. ✅ Ensure all target groups exist in Azure AD
2. ✅ Validate CSV file format matches the required columns
3. ✅ Verify all passwords meet complexity requirements
4. ✅ Check UPN format is valid (user@domain.com)
5. ✅ Service principal has required permissions:
   - `User.ReadWrite.All`
   - `Group.ReadWrite.All`
   - `Directory.ReadWrite.All`

---

## Troubleshooting

### Common Issues:

1. **"CSV file not found"**
   - Check the file path is correct
   - Ensure file is committed to the repository
   - Verify file is in the correct folder

2. **"Missing required columns"**
   - Check column names match exactly (case-sensitive)
   - Ensure no extra spaces in column headers
   - Verify CSV uses comma separator

3. **"Password validation failed"**
   - Check password meets all complexity requirements
   - Ensure no special characters are causing issues
   - Minimum 8 characters required

4. **"Group not found"**
   - Verify group exists in Azure AD
   - Check group name spelling (exact match required)
   - Ensure service principal has permissions

5. **"User not found"** (for existing user operations)
   - Verify user exists in Azure AD
   - Check UPN spelling and format
   - Ensure user is not deleted/disabled

---

## Support

For issues or questions, contact the CloudOps team or check the pipeline logs for detailed error messages.