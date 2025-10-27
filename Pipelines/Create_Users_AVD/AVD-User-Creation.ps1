param(
    [Parameter(Mandatory=$true)]
    [string]$CsvFilePath,
    
    [Parameter(Mandatory=$true)]
    [string]$GroupNames
)

Write-Host "Starting Azure AD User Creation..." -ForegroundColor Cyan

# Install required modules
$modules = @('Microsoft.Graph.Users', 'Microsoft.Graph.Groups')
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Yellow
        Install-Module $module -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module $module
}

# Connect to Microsoft Graph using Service Principal
Write-Host "Connecting to Microsoft Graph with Service Principal..." -ForegroundColor Cyan
$securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($env:AZURE_CLIENT_ID, $securePassword)

Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -ClientSecretCredential $credential -NoWelcome
Write-Host "Connected successfully" -ForegroundColor Green

# Import CSV
$users = Import-Csv -Path $CsvFilePath
Write-Host "Found $($users.Count) users" -ForegroundColor Green

# Get groups
$groups = $GroupNames -split ';' | ForEach-Object { $_.Trim() }
$validGroups = @()

foreach ($groupName in $groups) {
    $group = Get-MgGroup -Filter "displayName eq '$groupName'"
    if ($group) {
        Write-Host "Found group: $groupName" -ForegroundColor Green
        $validGroups += $group
    } else {
        Write-Host "Group not found: $groupName" -ForegroundColor Red
        exit 1
    }
}

# Create users
$successCount = 0
$failCount = 0

foreach ($user in $users) {
    try {
        Write-Host "`nProcessing: $($user.UserPrincipalName)" -ForegroundColor Cyan
        
        # Check if user exists
        $existingUser = Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
        
        if (-not $existingUser) {
            # Create user
            $mailNickname = ($user.UserPrincipalName -split '@')[0]
            $passwordProfile = @{
                Password = $user.Password
                ForceChangePasswordNextSignIn = $true
            }
            
            $newUser = New-MgUser `
                -DisplayName $user.DisplayName `
                -UserPrincipalName $user.UserPrincipalName `
                -PasswordProfile $passwordProfile `
                -AccountEnabled:$true `
                -MailNickname $mailNickname
            
            Write-Host "User created: $($user.UserPrincipalName)" -ForegroundColor Green
            $userId = $newUser.Id
        } else {
            Write-Host "User already exists: $($user.UserPrincipalName)" -ForegroundColor Yellow
            $userId = $existingUser.Id
        }
        
        # Add to groups
        foreach ($group in $validGroups) {
            $members = Get-MgGroupMember -GroupId $group.Id
            $isMember = $members | Where-Object { $_.Id -eq $userId }
            
            if (-not $isMember) {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId
                Write-Host "Added to group: $($group.DisplayName)" -ForegroundColor Green
            } else {
                Write-Host "Already in group: $($group.DisplayName)" -ForegroundColor Yellow
            }
        }
        
        $successCount++
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
        $failCount++
    }
}

Disconnect-MgGraph

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Total: $($users.Count) | Success: $successCount | Failed: $failCount" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
}