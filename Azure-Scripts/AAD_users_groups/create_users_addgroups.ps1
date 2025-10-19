<#
.SYNOPSIS
Create Azure AD (Entra ID) users from a CSV file and add them to a specified group.

.REQUIREMENTS
- Microsoft.Graph PowerShell SDK
  Install-Module Microsoft.Graph -Scope CurrentUser
- Permissions:
  - User.ReadWrite.All
  - GroupMember.ReadWrite.All

.CSV FORMAT EXAMPLE:
DisplayName,UserPrincipalName,MailNickname,Password
John Doe,john.doe@yourdomain.com,john.doe,P@ssw0rd123!
Jane Smith,jane.smith@yourdomain.com,jane.smith,P@ssw0rd123!
#>

# Parameters
$CsvPath = "C:\Users\NewUsers.csv"
$GroupName = "Your-Target-Group-Name"

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All"
Select-MgProfile -Name beta  # optional but helps with new Graph features

# Import users from CSV
$Users = Import-Csv -Path $CsvPath
Write-Host "📄 Loaded $($Users.Count) users from CSV."

# Get the target group
$Group = Get-MgGroup -Filter "DisplayName eq '$GroupName'"
if (-not $Group) {
    Write-Error "❌ Group '$GroupName' not found. Exiting."
    exit
}
Write-Host "✅ Target group found: $($Group.DisplayName)"

# Loop through users and create them
foreach ($u in $Users) {
    try {
        Write-Host "➡️ Creating user: $($u.DisplayName)..."

        # Create user
        $NewUser = New-MgUser -AccountEnabled $true `
            -DisplayName $u.DisplayName `
            -UserPrincipalName $u.UserPrincipalName `
            -MailNickname $u.MailNickname `
            -PasswordProfile @{ ForceChangePasswordNextSignIn = $false; Password = $u.Password }

        Write-Host "✅ User created: $($u.UserPrincipalName)"

        # Add user to group
        Write-Host "👥 Adding $($u.DisplayName) to group '$GroupName'..."
        New-MgGroupMember -GroupId $Group.Id -DirectoryObjectId $NewUser.Id
        Write-Host "✅ Added to group successfully.`n"
    }
    catch {
        Write-Warning "⚠️ Failed to process $($u.DisplayName): $($_.Exception.Message)"
    }
}

Write-Host "🎉 All users processed successfully!"