[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Create Service Account",
        "Create Normal AVD Users",
        "Add Existing Admin Studio Users to Admin Studio Groups",
        "Create New ABIC Users and Add to ABIC Groups",
        "Add Existing ABIC Users to ABIC Groups"
    )]
    [string]$OperationType,
    
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[\w\.-]+@[\w\.-]+\.\w+$')]
    [string]$ServiceAccountUPN = "",
    
    [Parameter(Mandatory=$false)]
    [ValidateLength(1, 256)]
    [string]$ServiceAccountDisplayName = "",
    
    [Parameter(Mandatory=$false)]
    [SecureString]$ServiceAccountSecurePassword,
    
    [Parameter(Mandatory=$false)]
    [string]$ServiceAccountGroup = "ALBTests service accounts",
    
    [Parameter(Mandatory=$false)]
    [string]$UsersCsvFilePath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$GroupsCsvFilePath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$HardcodedAVDGroup = "BAB_VDI_DT_Shared_Pool",
    
    [Parameter(Mandatory=$false)]
    [string]$LogPath = "C:\log",
    
    [Parameter(Mandatory=$false)]
    [string]$LogFileName = "user_management_log.txt"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$LogFile = Join-Path $LogPath $LogFileName

# Configuration
$script:MaxRetries = 3
$script:RetryDelaySeconds = 5
$script:RequiredModuleVersion = "2.0.0"

# Initialize log
try {
    if (-not (Test-Path $LogPath)) { 
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null 
    }
    "" | Out-File -FilePath $LogFile -Encoding utf8 -Force
} catch {
    Write-Error "Failed to initialize log file: $_"
    exit 1
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logMessage = "[$timestamp] [$Level] $Message"
        
        $color = switch ($Level) {
            "INFO" { "Cyan" }
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            "SUCCESS" { "Green" }
            "DEBUG" { "Gray" }
            default { "White" }
        }
        
        Write-Host $logMessage -ForegroundColor $color
        $logMessage | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch {
        Write-Warning "Failed to write log: $_"
    }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory=$false)]
        [int]$MaxRetries = $script:MaxRetries,
        
        [Parameter(Mandatory=$false)]
        [int]$RetryDelaySeconds = $script:RetryDelaySeconds,
        
        [Parameter(Mandatory=$false)]
        [string]$OperationName = "Operation"
    )
    
    $attempt = 1
    $success = $false
    $lastError = $null
    
    while ($attempt -le $MaxRetries -and -not $success) {
        try {
            Write-Log "Attempt $attempt of $MaxRetries for: $OperationName" "DEBUG"
            $result = & $ScriptBlock
            $success = $true
            return $result
        } catch {
            $lastError = $_
            Write-Log "Attempt $attempt failed: $($_.Exception.Message)" "WARN"
            
            if ($attempt -lt $MaxRetries) {
                $delay = $RetryDelaySeconds * $attempt
                Write-Log "Retrying in $delay seconds..." "INFO"
                Start-Sleep -Seconds $delay
            }
            
            $attempt++
        }
    }
    
    if (-not $success) {
        Write-Log "All $MaxRetries attempts failed for: $OperationName" "ERROR"
        throw $lastError
    }
}

function Test-PasswordComplexity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [SecureString]$SecurePassword
    )
    
    # Convert SecureString to plain text for validation only
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plainTextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        
        $issues = @()
        
        if ($plainTextPassword.Length -lt 8) {
            $issues += "Password must be at least 8 characters"
        }
        if ($plainTextPassword -notmatch '[A-Z]') {
            $issues += "Password must contain uppercase letter"
        }
        if ($plainTextPassword -notmatch '[a-z]') {
            $issues += "Password must contain lowercase letter"
        }
        if ($plainTextPassword -notmatch '[0-9]') {
            $issues += "Password must contain number"
        }
        if ($plainTextPassword -notmatch '[!@#$%^&*(),.?":{}|<>]') {
            $issues += "Password must contain special character"
        }
        
        if ($issues.Count -gt 0) {
            throw "Password validation failed: $($issues -join '; ')"
        }
        
        return $true
    } finally {
        # Always clear the BSTR to prevent memory leaks
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

function ConvertTo-SecureStringFromPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlainTextPassword
    )
    
    return ConvertTo-SecureString -String $PlainTextPassword -AsPlainText -Force
}

function Get-PasswordProfileFromSecureString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [SecureString]$SecurePassword,
        
        [Parameter(Mandatory=$false)]
        [bool]$ForceChangePasswordNextSignIn = $true
    )
    
    # Convert SecureString to plain text for API call
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plainTextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        
        return @{
            Password = $plainTextPassword
            ForceChangePasswordNextSignIn = $ForceChangePasswordNextSignIn
        }
    } finally {
        # Always clear the BSTR
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

Write-Log "========================================" "INFO"
Write-Log "Azure AD User Management Operation" "INFO"
Write-Log "Operation Type: $OperationType" "INFO"
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)" "INFO"
Write-Log "========================================" "INFO"

# Validate environment variables
Write-Log "Validating environment variables..." "INFO"
$requiredEnvVars = @('AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID')
foreach ($envVar in $requiredEnvVars) {
    if ([string]::IsNullOrWhiteSpace((Get-Item -Path "Env:\$envVar" -ErrorAction SilentlyContinue).Value)) {
        Write-Log "Required environment variable not set: $envVar" "ERROR"
        exit 1
    }
}
Write-Log "Environment variables validated" "SUCCESS"

# Validate CSV file paths
Write-Log -Level "INFO" -Message "Validating CSV file paths..."

# CSV validation should only happen for operations that require CSV files
switch ($OperationType) {
    "Create Service Account" {
        Write-Log -Level "INFO" -Message "Service Account creation does not require CSV files"
        # Skip CSV validation for service accounts
    }
    
    "Create Normal AVD Users" {
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file path is required for AVD user creation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if (-not (Test-Path -Path $UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file not found: $UsersCsvFilePath"
            throw "Users CSV file not found: $UsersCsvFilePath"
        }
        
        Write-Log -Level "SUCCESS" -Message "Users CSV file validated: $UsersCsvFilePath"
    }
    
    "Add Existing Admin Studio Users to Admin Studio Groups" {
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file path is required for Admin Studio operation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file path is required for Admin Studio operation"
            throw "GroupsCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if (-not (Test-Path -Path $UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file not found: $UsersCsvFilePath"
            throw "Users CSV file not found: $UsersCsvFilePath"
        }
        
        if (-not (Test-Path -Path $GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file not found: $GroupsCsvFilePath"
            throw "Groups CSV file not found: $GroupsCsvFilePath"
        }
        
        Write-Log -Level "SUCCESS" -Message "Admin Studio CSV files validated"
    }
    
    "Create New ABIC Users and Add to ABIC Groups" {
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file path is required for ABIC user creation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file path is required for ABIC operation"
            throw "GroupsCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if (-not (Test-Path -Path $UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file not found: $UsersCsvFilePath"
            throw "Users CSV file not found: $UsersCsvFilePath"
        }
        
        if (-not (Test-Path -Path $GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file not found: $GroupsCsvFilePath"
            throw "Groups CSV file not found: $GroupsCsvFilePath"
        }
        
        Write-Log -Level "SUCCESS" -Message "ABIC CSV files validated"
    }
    
    "Add Existing ABIC Users to ABIC Groups" {
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file path is required for ABIC operation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file path is required for ABIC operation"
            throw "GroupsCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if (-not (Test-Path -Path $UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file not found: $UsersCsvFilePath"
            throw "Users CSV file not found: $UsersCsvFilePath"
        }
        
        if (-not (Test-Path -Path $GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Groups CSV file not found: $GroupsCsvFilePath"
            throw "Groups CSV file not found: $GroupsCsvFilePath"
        }
        
        Write-Log -Level "SUCCESS" -Message "ABIC CSV files validated"
    }
    
    default {
        Write-Log -Level "ERROR" -Message "Unknown operation type: $OperationType"
        throw "Invalid operation type: $OperationType"
    }
}

# Install and import required modules
$modules = @(
    @{Name = 'Microsoft.Graph.Authentication'; MinVersion = $script:RequiredModuleVersion},
    @{Name = 'Microsoft.Graph.Users'; MinVersion = $script:RequiredModuleVersion},
    @{Name = 'Microsoft.Graph.Groups'; MinVersion = $script:RequiredModuleVersion}
)

foreach ($moduleInfo in $modules) {
    try {
        Write-Log "Checking module: $($moduleInfo.Name)" "INFO"
        
        $installedModule = Get-Module -ListAvailable -Name $moduleInfo.Name | 
            Where-Object { $_.Version -ge [version]$moduleInfo.MinVersion } | 
            Sort-Object Version -Descending | 
            Select-Object -First 1
        
        if (-not $installedModule) {
            Write-Log "Installing $($moduleInfo.Name) (min version $($moduleInfo.MinVersion))..." "INFO"
            Install-Module $moduleInfo.Name -MinimumVersion $moduleInfo.MinVersion -Force -Scope CurrentUser -AllowClobber -Repository PSGallery
            Write-Log "$($moduleInfo.Name) installed successfully" "SUCCESS"
        } else {
            Write-Log "$($moduleInfo.Name) version $($installedModule.Version) already installed" "SUCCESS"
        }
        
        Import-Module $moduleInfo.Name -Force -ErrorAction Stop
        Write-Log "$($moduleInfo.Name) imported successfully" "SUCCESS"
    } catch {
        Write-Log "Failed to install/import $($moduleInfo.Name): $_" "ERROR"
        exit 1
    }
}

# Connect to Microsoft Graph with retry
Write-Log "Connecting to Microsoft Graph..." "INFO"
try {
    Invoke-WithRetry -OperationName "Microsoft Graph Connection" -ScriptBlock {
        $securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($env:AZURE_CLIENT_ID, $securePassword)
        
        Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop
        
        # Verify connection
        $context = Get-MgContext
        if (-not $context) {
            throw "Failed to establish Graph context"
        }
        
        Write-Log "Connected to tenant: $($context.TenantId)" "SUCCESS"
        Write-Log "Using scopes: $($context.Scopes -join ', ')" "INFO"
    }
} catch {
    Write-Log "Failed to connect to Microsoft Graph: $_" "ERROR"
    exit 1
}

# Execute operation based on type
try {
    switch ($OperationType) {
        "Create Service Account" {
            Write-Log "Executing: Create Service Account (GUI Input)" "INFO"
            Write-Log "Service Account: $ServiceAccountUPN" "INFO"
            Write-Log "Target Group: $ServiceAccountGroup" "INFO"
            
            # Validate secure password
            if (-not $ServiceAccountSecurePassword) {
                Write-Log "Service Account password is required" "ERROR"
                exit 1
            }
            
            # Validate password complexity
            Test-PasswordComplexity -SecurePassword $ServiceAccountSecurePassword
            Write-Log "Password complexity validated" "SUCCESS"
            
            # Check if service account exists
            $existingUser = Invoke-WithRetry -OperationName "Check existing user" -ScriptBlock {
                Get-MgUser -Filter "userPrincipalName eq '$ServiceAccountUPN'" -ErrorAction SilentlyContinue
            }
            
            if ($existingUser) {
                Write-Log "Service account already exists: $ServiceAccountUPN" "WARN"
                $userId = $existingUser.Id
            } else {
                Write-Log "Creating service account: $ServiceAccountUPN" "INFO"
                
                $mailNickname = ($ServiceAccountUPN -split '@')[0] -replace '[^a-zA-Z0-9]', ''
                
                $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $ServiceAccountSecurePassword -ForceChangePasswordNextSignIn $false
                
                $newUser = Invoke-WithRetry -OperationName "Create service account" -ScriptBlock {
                    New-MgUser `
                        -DisplayName $ServiceAccountDisplayName `
                        -UserPrincipalName $ServiceAccountUPN `
                        -PasswordProfile $passwordProfile `
                        -AccountEnabled $true `
                        -MailNickname $mailNickname `
                        -PasswordPolicies "DisablePasswordExpiration" `
                        -ErrorAction Stop
                }
                
                $userId = $newUser.Id
                Write-Log "Service account created successfully (ID: $userId)" "SUCCESS"
            }
            
            # Add to group
            Write-Log "Adding to group: $ServiceAccountGroup" "INFO"
            
            $group = Invoke-WithRetry -OperationName "Get group" -ScriptBlock {
                Get-MgGroup -Filter "displayName eq '$ServiceAccountGroup'" -ErrorAction Stop
            }
            
            if (-not $group) {
                Write-Log "Group not found: $ServiceAccountGroup" "ERROR"
                throw "Required group not found: $ServiceAccountGroup"
            }
            
            $members = Get-MgGroupMember -GroupId $group.Id
            $isMember = $members | Where-Object { $_.Id -eq $userId }
            
            if (-not $isMember) {
                Invoke-WithRetry -OperationName "Add to group" -ScriptBlock {
                    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop
                }
                Write-Log "Added to group: $ServiceAccountGroup" "SUCCESS"
            } else {
                Write-Log "Already member of: $ServiceAccountGroup" "WARN"
            }
        }
        
        "Create Normal AVD Users" {
            Write-Log "Executing: Create Normal AVD Users and Add to Hardcoded Group" "INFO"
            Write-Log "Hardcoded Group: $HardcodedAVDGroup" "INFO"
            
            $avdUsers = Import-Csv -Path $UsersCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($avdUsers.Count) AVD users from CSV" "SUCCESS"
            
            # Validate CSV columns
            $requiredColumns = @('DisplayName', 'UserPrincipalName', 'Password')
            $csvColumns = $avdUsers[0].PSObject.Properties.Name
            $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
            
            if ($missingColumns) {
                throw "Missing required columns: $($missingColumns -join ', '). Expected: $($requiredColumns -join ', ')"
            }
            
            # Validate group exists
            $group = Invoke-WithRetry -OperationName "Get AVD group" -ScriptBlock {
                Get-MgGroup -Filter "displayName eq '$HardcodedAVDGroup'" -ErrorAction Stop
            }
            
            if (-not $group) {
                throw "Hardcoded AVD group not found: $HardcodedAVDGroup"
            }
            Write-Log "Hardcoded AVD group validated: $HardcodedAVDGroup (ID: $($group.Id))" "SUCCESS"
            
            $successCount = 0
            $failCount = 0
            $skippedCount = 0
            
            foreach ($user in $avdUsers) {
                try {
                    Write-Log "----------------------------------------" "INFO"
                    Write-Log "Processing AVD user: $($user.UserPrincipalName)" "INFO"
                    
                    # Validate UPN format
                    if ($user.UserPrincipalName -notmatch '^[\w\.-]+@[\w\.-]+\.\w+$') {
                        Write-Log "Invalid UPN format, skipping: $($user.UserPrincipalName)" "WARN"
                        $skippedCount++
                        continue
                    }
                    
                    # Convert plain text password to SecureString
                    $securePassword = ConvertTo-SecureStringFromPlainText -PlainTextPassword $user.Password
                    
                    # Validate password complexity
                    try {
                        Test-PasswordComplexity -SecurePassword $securePassword
                    } catch {
                        Write-Log "Password validation failed for $($user.UserPrincipalName): $_" "WARN"
                        $skippedCount++
                        continue
                    }
                    
                    # Check if user exists
                    $existingUser = Invoke-WithRetry -OperationName "Check existing AVD user" -ScriptBlock {
                        Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
                    }
                    
                    if ($existingUser) {
                        Write-Log "AVD user already exists: $($user.UserPrincipalName)" "WARN"
                        $userId = $existingUser.Id
                    } else {
                        Write-Log "Creating AVD user..." "INFO"
                        
                        $mailNickname = ($user.UserPrincipalName -split '@')[0] -replace '[^a-zA-Z0-9]', ''
                        
                        $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $securePassword -ForceChangePasswordNextSignIn $true
                        
                        $newUser = Invoke-WithRetry -OperationName "Create AVD user" -ScriptBlock {
                            New-MgUser `
                                -DisplayName $user.DisplayName `
                                -UserPrincipalName $user.UserPrincipalName `
                                -PasswordProfile $passwordProfile `
                                -AccountEnabled $true `
                                -MailNickname $mailNickname `
                                -ErrorAction Stop
                        }
                        
                        Write-Log "AVD user created: $($user.UserPrincipalName) (ID: $($newUser.Id))" "SUCCESS"
                        $userId = $newUser.Id
                    }
                    
                    # Add to hardcoded group
                    $members = Get-MgGroupMember -GroupId $group.Id
                    $isMember = $members | Where-Object { $_.Id -eq $userId }
                    
                    if (-not $isMember) {
                        Invoke-WithRetry -OperationName "Add AVD user to group" -ScriptBlock {
                            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop
                        }
                        Write-Log "Added to hardcoded group: $HardcodedAVDGroup" "SUCCESS"
                    } else {
                        Write-Log "Already member of hardcoded group: $HardcodedAVDGroup" "WARN"
                    }
                    
                    $successCount++
                } catch {
                    Write-Log "Error processing AVD user $($user.UserPrincipalName): $($_.Exception.Message)" "ERROR"
                    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                    $failCount++
                } finally {
                    # Clear the secure password from memory
                    if ($securePassword) {
                        $securePassword.Dispose()
                    }
                }
            }
            
            Write-Log "========================================" "INFO"
            Write-Log "AVD Users Summary" "INFO"
            Write-Log "Total: $($avdUsers.Count) | Success: $successCount | Failed: $failCount | Skipped: $skippedCount" "INFO"
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some AVD user operations failed. Check logs for details."
            }
        }
        
        "Add Existing Admin Studio Users to Admin Studio Groups" {
            Write-Log "Executing: Add Existing Admin Studio Users to Admin Studio Groups" "INFO"
            
            # Load Users CSV
            $adminUsers = Import-Csv -Path $UsersCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($adminUsers.Count) Admin Studio users from CSV" "SUCCESS"
            
            # Load Groups CSV
            $adminGroups = Import-Csv -Path $GroupsCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($adminGroups.Count) Admin Studio groups from CSV" "SUCCESS"
            
            # Validate CSV columns
            $requiredUserColumns = @('UserPrincipalName')
            $csvUserColumns = $adminUsers[0].PSObject.Properties.Name
            $missingUserColumns = $requiredUserColumns | Where-Object { $_ -notin $csvUserColumns }
            
            if ($missingUserColumns) {
                throw "Missing required user columns: $($missingUserColumns -join ', '). Expected: $($requiredUserColumns -join ', ')"
            }
            
            $requiredGroupColumns = @('GroupName')
            $csvGroupColumns = $adminGroups[0].PSObject.Properties.Name
            $missingGroupColumns = $requiredGroupColumns | Where-Object { $_ -notin $csvGroupColumns }
            
            if ($missingGroupColumns) {
                throw "Missing required group columns: $($missingGroupColumns -join ', '). Expected: $($requiredGroupColumns -join ', ')"
            }
            
            $successCount = 0
            $failCount = 0
            
            # Add each user to each group
            foreach ($adminUser in $adminUsers) {
                foreach ($adminGroup in $adminGroups) {
                    try {
                        Write-Log "----------------------------------------" "INFO"
                        Write-Log "Processing: $($adminUser.UserPrincipalName) -> $($adminGroup.GroupName)" "INFO"
                        
                        # Get existing Admin Studio user
                        $user = Invoke-WithRetry -OperationName "Get Admin Studio user" -ScriptBlock {
                            Get-MgUser -Filter "userPrincipalName eq '$($adminUser.UserPrincipalName)'" -ErrorAction Stop
                        }
                        
                        if (-not $user) {
                            Write-Log "Admin Studio user not found: $($adminUser.UserPrincipalName)" "ERROR"
                            $failCount++
                            continue
                        }
                        Write-Log "Admin Studio user found: $($adminUser.UserPrincipalName)" "SUCCESS"
                        
                        # Get Admin Studio group
                        $group = Invoke-WithRetry -OperationName "Get Admin Studio group" -ScriptBlock {
                            Get-MgGroup -Filter "displayName eq '$($adminGroup.GroupName)'" -ErrorAction Stop
                        }
                        
                        if (-not $group) {
                            Write-Log "Admin Studio group not found: $($adminGroup.GroupName)" "ERROR"
                            $failCount++
                            continue
                        }
                        Write-Log "Admin Studio group found: $($adminGroup.GroupName)" "SUCCESS"
                        
                        # Add to group
                        $members = Get-MgGroupMember -GroupId $group.Id
                        $isMember = $members | Where-Object { $_.Id -eq $user.Id }
                        
                        if (-not $isMember) {
                            Invoke-WithRetry -OperationName "Add user to Admin Studio group" -ScriptBlock {
                                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                            }
                            Write-Log "User added to Admin Studio group successfully" "SUCCESS"
                        } else {
                            Write-Log "User already in Admin Studio group" "WARN"
                        }
                        
                        $successCount++
                    } catch {
                        Write-Log "Error processing Admin Studio mapping: $($_.Exception.Message)" "ERROR"
                        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                        $failCount++
                    }
                }
            }
            
            Write-Log "========================================" "INFO"
            Write-Log "Admin Studio Users Summary" "INFO"
            Write-Log "Total Mappings: $($adminUsers.Count * $adminGroups.Count) | Success: $successCount | Failed: $failCount" "INFO"
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some Admin Studio operations failed. Check logs for details."
            }
        }
        
        "Create New ABIC Users and Add to ABIC Groups" {
            Write-Log "Executing: Create New ABIC Users and Add to ABIC Groups" "INFO"
            
            # Load Users CSV
            $abicUsers = Import-Csv -Path $UsersCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($abicUsers.Count) new ABIC users from CSV" "SUCCESS"
            
            # Load Groups CSV
            $abicGroups = Import-Csv -Path $GroupsCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($abicGroups.Count) ABIC groups from CSV" "SUCCESS"
            
            # Validate CSV columns for users
            $requiredUserColumns = @('DisplayName', 'UserPrincipalName', 'MailNickName', 'Password', 'First name', 'Last name', 'Job Title', 'Company name', 'Department', 'Employee Type', 'Manager', 'Employee ID')
            $csvUserColumns = $abicUsers[0].PSObject.Properties.Name
            $missingUserColumns = $requiredUserColumns | Where-Object { $_ -notin $csvUserColumns }
            
            if ($missingUserColumns) {
                throw "Missing required user columns: $($missingUserColumns -join ', '). Expected: $($requiredUserColumns -join ', ')"
            }
            
            # Validate CSV columns for groups
            $requiredGroupColumns = @('GroupName')
            $csvGroupColumns = $abicGroups[0].PSObject.Properties.Name
            $missingGroupColumns = $requiredGroupColumns | Where-Object { $_ -notin $csvGroupColumns }
            
            if ($missingGroupColumns) {
                throw "Missing required group columns: $($missingGroupColumns -join ', '). Expected: $($requiredGroupColumns -join ', ')"
            }
            
            $successCount = 0
            $failCount = 0
            $skippedCount = 0
            
            foreach ($user in $abicUsers) {
                $securePassword = $null
                try {
                    Write-Log "----------------------------------------" "INFO"
                    Write-Log "Processing new ABIC user: $($user.UserPrincipalName)" "INFO"
                    
                    # Validate UPN format
                    if ($user.UserPrincipalName -notmatch '^[\w\.-]+@[\w\.-]+\.\w+$') {
                        Write-Log "Invalid UPN format, skipping: $($user.UserPrincipalName)" "WARN"
                        $skippedCount++
                        continue
                    }
                    
                    # Convert plain text password to SecureString
                    $securePassword = ConvertTo-SecureStringFromPlainText -PlainTextPassword $user.Password
                    
                    # Validate password complexity
                    try {
                        Test-PasswordComplexity -SecurePassword $securePassword
                    } catch {
                        Write-Log "Password validation failed for $($user.UserPrincipalName): $_" "WARN"
                        $skippedCount++
                        continue
                    }
                    
                    # Check if user exists
                    $existingUser = Invoke-WithRetry -OperationName "Check existing ABIC user" -ScriptBlock {
                        Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
                    }
                    
                    if ($existingUser) {
                        Write-Log "ABIC user already exists, using existing: $($user.UserPrincipalName)" "WARN"
                        $userId = $existingUser.Id
                    } else {
                        Write-Log "Creating new ABIC user with full profile..." "INFO"
                        
                        $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $securePassword -ForceChangePasswordNextSignIn $true
                        
                        # Build user parameters with extended properties
                        $userParams = @{
                            DisplayName = $user.DisplayName
                            UserPrincipalName = $user.UserPrincipalName
                            PasswordProfile = $passwordProfile
                            AccountEnabled = $true
                            MailNickname = $user.MailNickName
                            GivenName = $user.'First name'
                            Surname = $user.'Last name'
                            JobTitle = $user.'Job Title'
                            CompanyName = $user.'Company name'
                            Department = $user.Department
                            EmployeeId = $user.'Employee ID'
                        }
                        
                        # Add manager if provided
                        if (-not [string]::IsNullOrWhiteSpace($user.Manager)) {
                            $manager = Get-MgUser -Filter "userPrincipalName eq '$($user.Manager)'" -ErrorAction SilentlyContinue
                            if ($manager) {
                                $userParams['Manager'] = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
                            } else {
                                Write-Log "Manager not found: $($user.Manager)" "WARN"
                            }
                        }
                        
                        # Add employee type if provided
                        if (-not [string]::IsNullOrWhiteSpace($user.'Employee Type')) {
                            $userParams['EmployeeType'] = $user.'Employee Type'
                        }
                        
                        $newUser = Invoke-WithRetry -OperationName "Create ABIC user" -ScriptBlock {
                            New-MgUser @userParams -ErrorAction Stop
                        }
                        
                        Write-Log "New ABIC user created: $($user.UserPrincipalName) (ID: $($newUser.Id))" "SUCCESS"
                        $userId = $newUser.Id
                    }
                    
                    # Add to all ABIC groups
                    foreach ($groupEntry in $abicGroups) {
                        try {
                            Write-Log "Adding to ABIC group: $($groupEntry.GroupName)" "INFO"
                            
                            $group = Invoke-WithRetry -OperationName "Get ABIC group" -ScriptBlock {
                                Get-MgGroup -Filter "displayName eq '$($groupEntry.GroupName)'" -ErrorAction Stop
                            }
                            
                            if (-not $group) {
                                Write-Log "ABIC group not found: $($groupEntry.GroupName)" "ERROR"
                                continue
                            }
                            
                            $members = Get-MgGroupMember -GroupId $group.Id
                            $isMember = $members | Where-Object { $_.Id -eq $userId }
                            
                            if (-not $isMember) {
                                Invoke-WithRetry -OperationName "Add to ABIC group" -ScriptBlock {
                                    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop
                                }
                                Write-Log "Added to ABIC group: $($groupEntry.GroupName)" "SUCCESS"
                            } else {
                                Write-Log "Already member of ABIC group: $($groupEntry.GroupName)" "WARN"
                            }
                        } catch {
                            Write-Log "Error adding to ABIC group $($groupEntry.GroupName): $($_.Exception.Message)" "ERROR"
                        }
                    }
                    
                    $successCount++
                } catch {
                    Write-Log "Error processing ABIC user: $($_.Exception.Message)" "ERROR"
                    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                    $failCount++
                } finally {
                    # Clear the secure password from memory
                    if ($securePassword) {
                        $securePassword.Dispose()
                    }
                }
            }
            
            Write-Log "========================================" "INFO"
            Write-Log "New ABIC Users Summary" "INFO"
            Write-Log "Total: $($abicUsers.Count) | Success: $successCount | Failed: $failCount | Skipped: $skippedCount" "INFO"
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some ABIC user operations failed. Check logs for details."
            }
        }
        
        "Add Existing ABIC Users to ABIC Groups" {
            Write-Log "Executing: Add Existing ABIC Users to ABIC Groups" "INFO"
            
            # Load Users CSV
            $abicUsers = Import-Csv -Path $UsersCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($abicUsers.Count) existing ABIC users from CSV" "SUCCESS"
            
            # Load Groups CSV
            $abicGroups = Import-Csv -Path $GroupsCsvFilePath -ErrorAction Stop
            Write-Log "Loaded $($abicGroups.Count) ABIC groups from CSV" "SUCCESS"
            
            # Validate CSV columns
            $requiredUserColumns = @('UserPrincipalName')
            $csvUserColumns = $abicUsers[0].PSObject.Properties.Name
            $missingUserColumns = $requiredUserColumns | Where-Object { $_ -notin $csvUserColumns }
            
            if ($missingUserColumns) {
                throw "Missing required user columns: $($missingUserColumns -join ', '). Expected: $($requiredUserColumns -join ', ')"
            }
            
            $requiredGroupColumns = @('GroupName')
            $csvGroupColumns = $abicGroups[0].PSObject.Properties.Name
            $missingGroupColumns = $requiredGroupColumns | Where-Object { $_ -notin $csvGroupColumns }
            
            if ($missingGroupColumns) {
                throw "Missing required group columns: $($missingGroupColumns -join ', '). Expected: $($requiredGroupColumns -join ', ')"
            }
            
            $successCount = 0
            $failCount = 0
            
            # Add each user to each group
            foreach ($abicUser in $abicUsers) {
                foreach ($abicGroup in $abicGroups) {
                    try {
                        Write-Log "----------------------------------------" "INFO"
                        Write-Log "Processing existing ABIC user: $($abicUser.UserPrincipalName) -> $($abicGroup.GroupName)" "INFO"
                        
                        # Get existing ABIC user
                        $user = Invoke-WithRetry -OperationName "Get existing ABIC user" -ScriptBlock {
                            Get-MgUser -Filter "userPrincipalName eq '$($abicUser.UserPrincipalName)'" -ErrorAction Stop
                        }
                        
                        if (-not $user) {
                            Write-Log "Existing ABIC user not found: $($abicUser.UserPrincipalName)" "ERROR"
                            $failCount++
                            continue
                        }
                        Write-Log "Existing ABIC user found: $($abicUser.UserPrincipalName)" "SUCCESS"
                        
                        # Get ABIC group
                        $group = Invoke-WithRetry -OperationName "Get ABIC group" -ScriptBlock {
                            Get-MgGroup -Filter "displayName eq '$($abicGroup.GroupName)'" -ErrorAction Stop
                        }
                        
                        if (-not $group) {
                            Write-Log "ABIC group not found: $($abicGroup.GroupName)" "ERROR"
                            $failCount++
                            continue
                        }
                        Write-Log "ABIC group found: $($abicGroup.GroupName)" "SUCCESS"
                        
                        # Add to ABIC group
                        $members = Get-MgGroupMember -GroupId $group.Id
                        $isMember = $members | Where-Object { $_.Id -eq $user.Id }
                        
                        if (-not $isMember) {
                            Invoke-WithRetry -OperationName "Add existing ABIC user to group" -ScriptBlock {
                                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                            }
                            Write-Log "Existing ABIC user added to ABIC group successfully" "SUCCESS"
                        } else {
                            Write-Log "Existing ABIC user already in ABIC group" "WARN"
                        }
                        
                        $successCount++
                    } catch {
                        Write-Log "Error processing existing ABIC user: $($_.Exception.Message)" "ERROR"
                        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                        $failCount++
                    }
                }
            }
            
            Write-Log "========================================" "INFO"
            Write-Log "Existing ABIC Users Summary" "INFO"
            Write-Log "Total Mappings: $($abicUsers.Count * $abicGroups.Count) | Success: $successCount | Failed: $failCount" "INFO"
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some existing ABIC operations failed. Check logs for details."
            }
        }
    }
} catch {
    Write-Log "Operation failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    exit 1
} finally {
    # Always disconnect
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Write-Log "Disconnected from Microsoft Graph" "INFO"
    } catch {
        Write-Log "Failed to disconnect cleanly: $_" "WARN"
    }
}

Write-Log "========================================" "INFO"
Write-Log "Operation completed successfully!" "SUCCESS"
Write-Log "========================================" "INFO"
exit 0