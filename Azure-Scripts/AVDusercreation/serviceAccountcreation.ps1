# Import Microsoft Graph module (install if not present)
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.ReadWrite.All Group.ReadWrite.All"

# CSV and log paths
$csvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\AVDusercreation\serviceaccount_users.csv"
$logPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\AVDusercreation\serviceaccount_user_creation.log"
$users   = Import-Csv -Path $csvPath

# Define target groups
$groupNames = @("ALBTests service accounts")
$groups = @{}

# Get group IDs
foreach ($name in $groupNames) {
    $grp = Get-MgGroup -Filter "displayName eq '$name'"
    if ($grp) {
        $groups[$name] = $grp.Id
    } else {
        Write-Host "❌ Group '$name' not found. Skipping." -ForegroundColor Red
        Add-Content -Path $logPath -Value "[$(Get-Date)] Group '$name' not found. Skipped."
    }
}

foreach ($user in $users) {
    $upn = $user.UserPrincipalName.Trim()
    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Host "⚠️ Skipping row – UserPrincipalName is missing." -ForegroundColor Yellow
        Add-Content -Path $logPath -Value "[$(Get-Date)] Skipped – missing UPN in CSV row"
        continue
    }

    try {
        # Get or create user
        $mgUser = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
        if (-not $mgUser) {
            # Ensure password is not empty
            $password = $user.Password.Trim()
            if ([string]::IsNullOrWhiteSpace($password)) {
                Write-Host "❌ Password is missing for $upn. Skipping." -ForegroundColor Red
                Add-Content -Path $logPath -Value "[$(Get-Date)] Password missing for $upn. Skipped."
                continue
            }

            $displayName = if ($user.DisplayName) { $user.DisplayName.Trim() } else { $null }
            $mailNickname = if ($user.MailNickName) { $user.MailNickName.Trim() } else { $null }

            if ([string]::IsNullOrWhiteSpace($displayName)) {
                Write-Host "❌ DisplayName is missing for $upn. Skipping." -ForegroundColor Red
                Add-Content -Path $logPath -Value "[$(Get-Date)] DisplayName missing for $upn. Skipped."
                continue
            }

            # Create user using direct Graph API call to bypass SDK issue
            $userBodyHashtable = @{
                displayName = $displayName
                userPrincipalName = $upn
                mailNickname = $mailNickname
                accountEnabled = $true
                passwordProfile = @{
                    password = $password
                    forceChangePasswordNextSignIn = $false
                }
            }

            $mgUser = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users" -Body $userBodyHashtable -OutputType PSObject
            Write-Host "✅ Created user: $upn" -ForegroundColor Green
            Add-Content -Path $logPath -Value "[$(Get-Date)] Created user: $upn"
            Start-Sleep -Seconds 10  # ensure Graph has registered the new user
        }
        else {
            Write-Host "⚠️ User already exists: $upn" -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "[$(Get-Date)] User already exists: $upn"
        }

        # Add user to all target groups
        foreach ($groupName in $groups.Keys) {
            $groupId = $groups[$groupName]
            
            # Verify user object exists and has ID
            if (-not $mgUser.Id) {
                Write-Host "❌ User $upn does not have valid ID. Skipping group addition." -ForegroundColor Red
                Add-Content -Path $logPath -Value "[$(Get-Date)] User $upn missing ID. Skipped group addition."
                continue
            }

            $groupMembers = Get-MgGroupMember -GroupId $groupId -All
            $isMember = $groupMembers | Where-Object { $_.Id -eq $mgUser.Id }

            if (-not $isMember) {
                try {
                    $params = @{
                        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($mgUser.Id)"
                    }
                    New-MgGroupMemberByRef -GroupId $groupId -BodyParameter $params -ErrorAction Stop
                    Write-Host "➕ Added $upn to group '$groupName'" -ForegroundColor Cyan
                    Add-Content -Path $logPath -Value "[$(Get-Date)] Added $upn to group '$groupName'"
                }
                catch {
                    Write-Host "❌ Failed to add $upn to group '$groupName': $($_.Exception.Message)" -ForegroundColor Red
                    Add-Content -Path $logPath -Value "[$(Get-Date)] Failed to add $upn to group '$groupName': $($_.Exception.Message)"
                }
            }
            else {
                Write-Host "✔️ $upn already in group '$groupName'" -ForegroundColor Gray
                Add-Content -Path $logPath -Value "[$(Get-Date)] $upn already in group '$groupName'"
            }
        }

    }
    catch {
        $err = $_.Exception.Message
        Write-Host "❌ Failed to process $upn{: $err}" -ForegroundColor Red
        Add-Content -Path $logPath -Value "[$(Get-Date)] Failed to process $upn{: $err}"
    }
}

Write-Host "✅ All users processed. See log file at $logPath" -ForegroundColor Green