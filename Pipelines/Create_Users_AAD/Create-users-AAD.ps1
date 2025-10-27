param(
    [Parameter(Mandatory=$true)]
    [string]$CsvFilePath,
    
    [Parameter(Mandatory=$true)]
    [string]$GroupNames
)

$ErrorActionPreference = 'Stop'
$LogFile = "C:\log\user_creation_log.txt"

# Initialize log directory and file
if (-not (Test-Path "C:\log")) { 
    New-Item -Path "C:\log" -ItemType Directory | Out-Null 
}
"" | Out-File -FilePath $LogFile -Encoding utf8

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    $color = switch ($Level) {
        "INFO" { "Cyan" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    
    Write-Host $logMessage -ForegroundColor $color
    $logMessage | Out-File -FilePath $LogFile -Append -Encoding utf8
}

Write-Log "Starting Azure AD User Creation..." "INFO"
Write-Log "CSV Path: $CsvFilePath" "INFO"
Write-Log "Groups: $GroupNames" "INFO"

# Install required modules
$modules = @('Microsoft.Graph.Users', 'Microsoft.Graph.Groups')
foreach ($module in $modules) {
    try {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Log "Installing $module..." "INFO"
            Install-Module $module -Force -Scope CurrentUser -AllowClobber -Repository PSGallery -ErrorAction Stop
            Write-Log "$module installed successfully" "SUCCESS"
        }
        Import-Module $module -Force -ErrorAction Stop
        Write-Log "$module imported successfully" "SUCCESS"
    } catch {
        Write-Log "Failed to install/import $module - $_" "ERROR"
        exit 1
    }
}

# Connect to Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph..." "INFO"
    
    if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_CLIENT_SECRET -or -not $env:AZURE_TENANT_ID) {
        Write-Log "Missing required environment variables" "ERROR"
        exit 1
    }
    
    $securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($env:AZURE_CLIENT_ID, $securePassword)
    
    Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop
    Write-Log "Connected to Microsoft Graph successfully" "SUCCESS"
} catch {
    Write-Log "Failed to connect to Microsoft Graph - $_" "ERROR"
    exit 1
}

# Import and validate CSV
try {
    Write-Log "Loading CSV file..." "INFO"
    $users = Import-Csv -Path $CsvFilePath -ErrorAction Stop
    Write-Log "Loaded $($users.Count) users from CSV" "SUCCESS"
    
    if ($users.Count -eq 0) {
        Write-Log "CSV file is empty" "ERROR"
        Disconnect-MgGraph
        exit 1
    }
    
    $requiredColumns = @('DisplayName', 'UserPrincipalName', 'Password')
    $csvColumns = $users[0].PSObject.Properties.Name
    $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
    
    if ($missingColumns) {
        Write-Log "Missing required columns: $($missingColumns -join ', ')" "ERROR"
        Disconnect-MgGraph
        exit 1
    }
    
    Write-Log "CSV validation successful" "SUCCESS"
} catch {
    Write-Log "Failed to process CSV - $_" "ERROR"
    Disconnect-MgGraph
    exit 1
}

# Parse and validate groups
$groups = $GroupNames -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$validGroups = @()

if ($groups.Count -eq 0) {
    Write-Log "No groups specified. Users will be created without group assignments." "WARN"
} else {
    Write-Log "Validating $($groups.Count) group(s)..." "INFO"
    
    foreach ($groupName in $groups) {
        try {
            Write-Log "Checking group: $groupName" "INFO"
            $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
            
            if ($group) {
                Write-Log "Group found: $groupName (ID: $($group.Id))" "SUCCESS"
                $validGroups += $group
            } else {
                Write-Log "Group not found: $groupName" "ERROR"
                Disconnect-MgGraph
                exit 1
            }
        } catch {
            Write-Log "Error validating group '$groupName' - $_" "ERROR"
            Disconnect-MgGraph
            exit 1
        }
    }
}

# Create users
$successCount = 0
$failCount = 0

Write-Log "Starting user creation process..." "INFO"

foreach ($user in $users) {
    try {
        Write-Log "----------------------------------------" "INFO"
        Write-Log "Processing user: $($user.UserPrincipalName)" "INFO"
        
        # Check if user exists
        $existingUser = Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
        
        if (-not $existingUser) {
            Write-Log "Creating new user..." "INFO"
            
            # Sanitize mailNickname
            $mailNickname = ($user.UserPrincipalName -split '@')[0] -replace '[^a-zA-Z0-9]', ''
            
            $passwordProfile = @{
                Password = $user.Password
                ForceChangePasswordNextSignIn = $true
            }
            
            $newUser = New-MgUser `
                -DisplayName $user.DisplayName `
                -UserPrincipalName $user.UserPrincipalName `
                -PasswordProfile $passwordProfile `
                -AccountEnabled $true `
                -MailNickname $mailNickname `
                -ErrorAction Stop
            
            Write-Log "User created successfully: $($user.UserPrincipalName)" "SUCCESS"
            $userId = $newUser.Id
        } else {
            Write-Log "User already exists: $($user.UserPrincipalName)" "WARN"
            $userId = $existingUser.Id
        }
        
        # Add to groups
        if ($validGroups.Count -gt 0) {
            foreach ($group in $validGroups) {
                try {
                    Write-Log "Checking group membership: $($group.DisplayName)" "INFO"
                    
                    $members = Get-MgGroupMember -GroupId $group.Id -ErrorAction Stop
                    $isMember = $members | Where-Object { $_.Id -eq $userId }
                    
                    if (-not $isMember) {
                        New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop
                        Write-Log "Added to group: $($group.DisplayName)" "SUCCESS"
                    } else {
                        Write-Log "Already member of: $($group.DisplayName)" "WARN"
                    }
                } catch {
                    Write-Log "Failed to add to group '$($group.DisplayName)' - $_" "ERROR"
                }
            }
        }
        
        $successCount++
        Write-Log "User processing completed: $($user.UserPrincipalName)" "SUCCESS"
        
    } catch {
        Write-Log "Error processing $($user.UserPrincipalName) - $_" "ERROR"
        $failCount++
    }
}

# Disconnect from Graph
Disconnect-MgGraph
Write-Log "Disconnected from Microsoft Graph" "INFO"

# Summary
Write-Log "========================================" "INFO"
Write-Log "EXECUTION SUMMARY" "INFO"
Write-Log "========================================" "INFO"
Write-Log "Total Users: $($users.Count)" "INFO"
Write-Log "Successful: $successCount" "SUCCESS"
Write-Log "Failed: $failCount" $(if ($failCount -gt 0) { "ERROR" } else { "INFO" })
Write-Log "========================================" "INFO"

if ($failCount -gt 0) {
    Write-Log "Some users failed to process. Check the log for details." "WARN"
    exit 1
}

Write-Log "User creation completed successfully!" "SUCCESS"
exit 0