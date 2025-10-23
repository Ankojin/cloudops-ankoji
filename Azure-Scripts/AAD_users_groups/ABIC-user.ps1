# Import the Microsoft Graph module (install if not present)
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph with the necessary permissions
Connect-MgGraph -Scopes "User.ReadWrite.All Group.ReadWrite.All"

# Paths
$csvPath = "C:\Ankoji\scripts\abic-users.csv"
$logPath = "C:\Ankoji\scripts\userCreation.log"

# Get target group
$groupName = "BAB AVD ABIC"
$group = Get-MgGroup -Filter "displayName eq '$groupName'"
if (-not $group) {
    Write-Host "❌ Group '$groupName' not found. Exiting." -ForegroundColor Red
    exit
}

# Import CSV file with user details
$users = Import-Csv -Path $csvPath

# Dictionary to map UPN -> UserId for manager assignment later
$userIdMap = @{}

# -------- Pass 1: Create users & add to group --------
foreach ($user in $users) {
    try {
        # Validate required fields
        if ([string]::IsNullOrWhiteSpace($user.DisplayName) -or
            [string]::IsNullOrWhiteSpace($user.UserPrincipalName) -or
            [string]::IsNullOrWhiteSpace($user.MailNickName) -or
            [string]::IsNullOrWhiteSpace($user.Password)) {
            $msg = "⚠️ Skipped row due to missing required data: $($user | ConvertTo-Json -Compress)"
            Write-Host $msg -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
            continue
        }

        # Check if user already exists
        $existingUser = Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
        $userId = $null

        if ($null -ne $existingUser) {
            $msg = "⚠️ User already exists: $($user.UserPrincipalName)"
            Write-Host $msg -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
            $userId = $existingUser.Id
        }
        else {
            # Build user parameters
            $userParams = @{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                MailNickName      = $user.MailNickName
                GivenName         = $user.'First name'
                Surname           = $user.'Last name'
                JobTitle          = $user.'Job Title'
                CompanyName       = $user.'Company name'
                Department        = $user.Department
                EmployeeType      = $user.'Employee Type'
                EmployeeId        = $user.'Employee ID'
                AccountEnabled    = $true
                PasswordProfile   = @{
                    Password                      = $user.Password
                    ForceChangePasswordNextSignIn = $true
                }
            }

            # Create new user
            $newUser = New-MgUser @userParams
            $userId = $newUser.Id

            $msg = "✅ Created user: $($user.UserPrincipalName)"
            Write-Host $msg -ForegroundColor Green
            Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
        }

        # Store userId for later manager assignment
        if ($userId) {
            $userIdMap[$user.UserPrincipalName] = $userId

            # Add user to group
            try {
                $memberCheck = Get-MgGroupMember -GroupId $group.Id -All | Where-Object Id -eq $userId
                if (-not $memberCheck) {
                    New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter @{
                        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
                    }
                    $msg = "➕ Added $($user.UserPrincipalName) to group '$groupName'"
                }
                else {
                    $msg = "✔️ $($user.UserPrincipalName) already in group '$groupName'"
                }
                Write-Host $msg -ForegroundColor Cyan
                Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
            }
            catch {
                $err = $_.ErrorDetails.Message
                if ([string]::IsNullOrWhiteSpace($err)) { $err = $_.Exception.Message }
                $msg = "❌ Failed to add $($user.UserPrincipalName) to group '$groupName': $err"
                Write-Host $msg -ForegroundColor Red
                Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
            }
        }

    }
    catch {
        $err = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($err)) { $err = $_.Exception.Message }
        $msg = "❌ Failed to process user $($user.UserPrincipalName): $err"
        Write-Host $msg -ForegroundColor Red
        Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
    }
}

# -------- Pass 2: Assign managers --------
foreach ($user in $users) {
    if (-not [string]::IsNullOrWhiteSpace($user.Manager)) {
        $managerUpn = $user.Manager
        $userId = $userIdMap[$user.UserPrincipalName]

        if (-not $userId) { continue }

        $managerId = $null

        # First try CSV-created users
        if ($userIdMap.ContainsKey($managerUpn)) {
            $managerId = $userIdMap[$managerUpn]
        }
        else {
            # Fallback: look up existing user in Azure AD
            try {
                $managerUser = Get-MgUser -Filter "userPrincipalName eq '$managerUpn'" -ErrorAction Stop
                if ($managerUser) { $managerId = $managerUser.Id }
            }
            catch {
                # manager not found anywhere
            }
        }

        if ($managerId) {
    try {
        Set-MgUserManagerByRef -UserId $userId -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$managerId"
        }
        $msg = "👔 Set manager for $($user.UserPrincipalName): $managerUpn"
        Write-Host $msg -ForegroundColor Magenta
        Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
    }
    catch {
        $err = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($err)) { $err = $_.Exception.Message }
        $msg = "❌ Failed to set manager for $($user.UserPrincipalName): $managerUpn ($err)"
        Write-Host $msg -ForegroundColor Red
        Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
    }
}
        else {
            $msg = "⚠️ Manager not found for user '$($user.UserPrincipalName)': $managerUpn"
            Write-Host $msg -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "[$(Get-Date)] $msg"
        }
    }
}
