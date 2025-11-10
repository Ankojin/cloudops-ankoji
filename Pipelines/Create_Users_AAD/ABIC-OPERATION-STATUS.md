# ABIC Group Assignment Operation Status

## Current State

This operation assigns existing ABIC users to one or more ABIC security groups in Azure AD. It is designed for bulk updates, such as role changes or onboarding users to new applications.

### CSV Files Required
- **ABIC-Existing-Users.csv**: List of users (column: UserPrincipalName)
- **ABIC-Groups.csv**: List of target groups (column: GroupName)

### How It Works
- Every user in the users CSV is added to every group in the groups CSV.
- The script checks if the user is already a member before adding.
- Results are logged: successful assignments, already members (skipped), and any errors.

### Example
- If you have 1 user and 68 groups, the script will attempt 68 assignments.
- For each assignment, you’ll see a log entry indicating success, skip, or failure.

### Steps to Use
1. Update the CSV files with the users and groups you want to process.
2. Run the pipeline, select "Add Existing ABIC Users to ABIC Groups," and confirm the operation.
3. Review the logs and published artifacts for a summary of what happened.

### Notes & Tips
- Make sure all users and groups exist in Azure AD before running.
- For large numbers of users/groups, consider mapping users to specific groups to avoid unnecessary assignments.
- The service principal running the pipeline must have Group.ReadWrite.All permissions.
- If you see errors about missing users or groups, double-check the CSV spelling and Azure AD objects.

---
_Last updated: November 10, 2025_