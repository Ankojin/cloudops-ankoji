<#
.SYNOPSIS
Create Azure AD (Entra ID) users from CSV and add them to one or more groups.

.REQUIREMENTS
- Microsoft.Graph PowerShell SDK
  Install-Module Microsoft.Graph -Scope CurrentUser
- Permissions:
  - User.ReadWrite.All
  - Group.ReadWrite.All
  - GroupMember.ReadWrite.All

#>

# === CONFIGURATION ===
$CsvPath = "C:\Users\NewUsers.csv"

# === CONNECT TO GRAPH ===
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","GroupMember.ReadWrite.All"
Select-MgProfile -Name beta

# === LOAD CSV ===
$Users = Import-Csv -Path $CsvPath
Write-Host "📄 Loaded $($Users.Count) users from CSV.`n"

# === PROCESS USERS ===
foreach ($u in $Users) {
    try {
        Write-Host "➡️ Creating user: $($u.DisplayName)..."

        # Check if user already exists
        $ExistingUser = Get-MgUser -Filter "userPrincipalName eq '$($u.UserPrincipalName)'" -ErrorAction SilentlyContinue
        if ($ExistingUser) {
            Write-Warning "⚠️ User $($u.UserPrincipalName) already exists. Skipping creation."
            $NewUser = $ExistingUser
        }
        else {
            # Create user
            $NewUser = New-MgUser -AccountEnabled $true `
                -DisplayName $u.DisplayName `
                -UserPrincipalName $u.UserPrincipalName `
                -MailNickname $u.MailNickname `
                -PasswordProfile @{ ForceChangePasswordNextSignIn = $false; Password = $u.Password }

            Write-Host "✅ User created: $($u.UserPrincipalName)"
        }

        # === Add to groups ===
        if ($u.Groups) {
            $GroupList = $u.Groups -split ';'
            foreach ($GroupName in $GroupList) {
                $GroupNameTrimmed = $GroupName.Trim()
                if (-not [string]::IsNullOrWhiteSpace($GroupNameTrimmed)) {
                    $Group = Get-MgGroup -Filter "DisplayName eq '$GroupNameTrimmed'" -ErrorAction SilentlyContinue
                    if ($Group) {
                        Write-Host "👥 Adding $($u.DisplayName) to group '$GroupNameTrimmed'..."
                        New-MgGroupMember -GroupId $Group.Id -DirectoryObjectId $NewUser.Id -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Warning "⚠️ Group '$GroupNameTrimmed' not found. Skipping."
                    }
                }
            }
        }

        Write-Host "✅ Finished processing $($u.DisplayName).`n"
    }
    catch {
        Write-Warning "❌ Error with user $($u.DisplayName): $($_.Exception.Message)"
    }
}

Write-Host "🎉 All users processed successfully!"