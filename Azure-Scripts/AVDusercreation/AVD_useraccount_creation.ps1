# Import Microsoft Graph module (install if not present)
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.ReadWrite.All Group.ReadWrite.All"

# CSV and log paths
$csvPath = "C:\Ankoji\scripts\AVD_useraccount_creation.csv"
$logPath = "C:\Ankoji\scripts\AVD_useraccount_creation.log"
$users   = Import-Csv -Path $csvPath

# Define target groups
$groupNames = @("ALB Test FSX Share Contributor", "BAB_VDI_DT_Shared_Pool")
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
            $userParams = @{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $upn
                MailNickName      = $user.MailNickName
                AccountEnabled    = $true
                PasswordProfile   = @{
                    Password                      = $user.Password
                    ForceChangePasswordNextSignIn = $false
                }
            }
            $mgUser = New-MgUser @userParams
            Write-Host "✅ Created user: $upn" -ForegroundColor Green
            Add-Content -Path $logPath -Value "[$(Get-Date)] Created user: $upn"
            Start-Sleep -Seconds 5  # ensure Graph has registered the new user
        }
        else {
            Write-Host "⚠️ User already exists: $upn" -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "[$(Get-Date)] User already exists: $upn"
        }

        # Add user to all target groups
        foreach ($groupName in $groups.Keys) {
            $groupId = $groups[$groupName]
            $groupMembers = Get-MgGroupMember -GroupId $groupId -All
            $isMember = $groupMembers | Where-Object { $_.Id -eq $mgUser.Id }

            if (-not $isMember) {
                $params = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($mgUser.Id)"
                }
                New-MgGroupMemberByRef -GroupId $groupId -BodyParameter $params
                Write-Host "➕ Added $upn to group '$groupName'" -ForegroundColor Cyan
                Add-Content -Path $logPath -Value "[$(Get-Date)] Added $upn to group '$groupName'"
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