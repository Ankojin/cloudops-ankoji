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
<#
.SYNOPSIS
    Azure AD User Management Script for BAB CloudOps

.DESCRIPTION
    This script supports multiple Azure AD operations including service account creation,
    AVD user provisioning, Admin Studio user management, and ABIC user operations.

.OPERATION TYPES
    1. Create Service Account - GUI input based service account creation
    2. Create Normal AVD Users - CSV-driven AVD user creation
    3. Add Existing Admin Studio Users to Admin Studio Groups - Group assignment from CSV
    4. Create New ABIC Users and Add to ABIC Groups - Full ABIC user lifecycle
    5. Add Existing ABIC Users to ABIC Groups - Existing user group assignment

.CSV FILE MAPPINGS
    "Add Existing ABIC Users to ABIC Groups" operation uses:
    - Users CSV: ABIC-Existing-Users.csv (UserPrincipalName column)
    - Groups CSV: ABIC-Groups.csv (GroupName column)
    
    Current operation will assign:
    - 1 user (Kurweg-A@albtests.com)
    - To 68 ABIC groups
    - Total: 68 group assignments

.NOTES
    File: Create-User-AAD.ps1
    Author: BAB CloudOps Team
    Version: 2.0
    Updated: November 2025
#>

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
    
    # Service Account Parameters (Optional - only required for "Create Service Account")
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ServiceAccountUPN = "",
    
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ServiceAccountDisplayName = "",
    
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [SecureString]$ServiceAccountSecurePassword = $null,
    
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ServiceAccountGroup = "",
    
    # CSV File Paths (Optional - operation-specific)
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$UsersCsvFilePath = "",
    
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GroupsCsvFilePath = "",
    
    # AVD Group (Optional - only for AVD operations)
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$HardcodedAVDGroup = "",
    
    # Logging Parameters
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\log",
    
    [Parameter(Mandatory = $false)]
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
        
        # Return Microsoft.Graph.PowerShell.Models.IMicrosoftGraphPasswordProfile compatible object
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
        # Validate CSV file path
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "UsersCsvFilePath is required for AVD user creation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if (-not (Test-Path -Path $UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "Users CSV file not found: $UsersCsvFilePath"
            throw "Users CSV file not found: $UsersCsvFilePath"
        }
        
        Write-Log -Level "SUCCESS" -Message "AVD users CSV file validated: $UsersCsvFilePath"
    }
    
    "Add Existing Admin Studio Users to Admin Studio Groups" {
        # Validate both CSV file paths
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "UsersCsvFilePath is required for Admin Studio operation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "GroupsCsvFilePath is required for Admin Studio operation"
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
        # Validate both CSV file paths
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "UsersCsvFilePath is required for ABIC user creation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "GroupsCsvFilePath is required for ABIC operation"
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
        # Validate both CSV file paths
        if ([string]::IsNullOrWhiteSpace($UsersCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "UsersCsvFilePath is required for ABIC operation"
            throw "UsersCsvFilePath parameter is required for operation: $OperationType"
        }
        
        if ([string]::IsNullOrWhiteSpace($GroupsCsvFilePath)) {
            Write-Log -Level "ERROR" -Message "GroupsCsvFilePath is required for ABIC operation"
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

Write-Log -Level "SUCCESS" -Message "All parameter validations passed"

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
        # SECTION: Create Service Account (Line ~420)
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
                
                # Get password profile
                $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $ServiceAccountSecurePassword -ForceChangePasswordNextSignIn $false
                
                # Create user with explicit parameter mapping (Azure Graph SDK best practice)
                $newUser = Invoke-WithRetry -OperationName "Create service account" -ScriptBlock {
                    New-MgUser `
                        -DisplayName $ServiceAccountDisplayName `
                        -UserPrincipalName $ServiceAccountUPN `
                        -PasswordProfile $passwordProfile `
                        -AccountEnabled:$true `
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
        
        # SECTION: Create Normal AVD Users (Line ~480)
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
                        
                        # Get password profile
                        $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $securePassword -ForceChangePasswordNextSignIn $true
                        
                        # Create AVD user with explicit parameter mapping
                        $newUser = Invoke-WithRetry -OperationName "Create AVD user" -ScriptBlock {
                            New-MgUser `
                                -DisplayName $user.DisplayName `
                                -UserPrincipalName $user.UserPrincipalName `
                                -PasswordProfile $passwordProfile `
                                -AccountEnabled:$true `
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
        
        # SECTION: Create New ABIC Users (Line ~670)
        "Create New ABIC Users and Add to ABIC Groups" {
            Write-Log "Executing: Create New ABIC Users and Add to ABIC Groups" "INFO"
            Write-Log "Users CSV: $UsersCsvFilePath" "INFO"
            Write-Log "Groups CSV: $GroupsCsvFilePath" "INFO"
            
            # Import CSV files
            $abicUsers = Import-Csv -Path $UsersCsvFilePath
            $abicGroups = Import-Csv -Path $GroupsCsvFilePath
            
            Write-Log "Found $($abicUsers.Count) ABIC users to process" "INFO"
            Write-Log "Found $($abicGroups.Count) ABIC groups for assignment" "INFO"
            
            $successCount = 0
            $failCount = 0
            $skipCount = 0
            
            foreach ($user in $abicUsers) {
                try {
                    Write-Log "Processing ABIC user: $($user.UserPrincipalName)" "INFO"
                    
                    # Check if user already exists
                    $existingUser = Invoke-WithRetry -OperationName "Check existing ABIC user" -ScriptBlock {
                        Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue
                    }
                    
                    if ($existingUser) {
                        Write-Log "ABIC user already exists: $($user.UserPrincipalName)" "WARN"
                        $userId = $existingUser.Id
                        $skipCount++
                    } else {
                        Write-Log "Creating new ABIC user with full profile..." "INFO"
                        
                        # Validate and convert password
                        $securePassword = ConvertTo-SecureString -String $user.Password -AsPlainText -Force
                        Test-PasswordComplexity -SecurePassword $securePassword
                        
                        # Get password profile
                        $passwordProfile = Get-PasswordProfileFromSecureString -SecurePassword $securePassword -ForceChangePasswordNextSignIn $true
                        
                        # Build user parameters WITHOUT manager (Azure Graph API best practice)
                        $userParams = @{
                            DisplayName = $user.DisplayName
                            UserPrincipalName = $user.UserPrincipalName
                            PasswordProfile = $passwordProfile
                            AccountEnabled = $true
                            MailNickname = $user.MailNickName
                        }
                        
                        # Add optional profile fields if provided
                        if (-not [string]::IsNullOrWhiteSpace($user.'First name')) {
                            $userParams['GivenName'] = $user.'First name'
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.'Last name')) {
                            $userParams['Surname'] = $user.'Last name'
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.'Job Title')) {
                            $userParams['JobTitle'] = $user.'Job Title'
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.'Company name')) {
                            $userParams['CompanyName'] = $user.'Company name'
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.Department)) {
                            $userParams['Department'] = $user.Department
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.'Employee Type')) {
                            $userParams['EmployeeType'] = $user.'Employee Type'
                        }
                        
                        if (-not [string]::IsNullOrWhiteSpace($user.'Employee ID')) {
                            $userParams['EmployeeId'] = $user.'Employee ID'
                        }
                        
                        # Create user WITHOUT manager (Azure best practice)
                        $newUser = Invoke-WithRetry -OperationName "Create ABIC user" -ScriptBlock {
                            New-MgUser @userParams -ErrorAction Stop
                        }
                        
                        $userId = $newUser.Id
                        Write-Log "ABIC user created successfully (ID: $userId)" "SUCCESS"
                        
                        # Set manager AFTER user creation (Azure Graph API requirement)
                        if (-not [string]::IsNullOrWhiteSpace($user.Manager)) {
                            Write-Log "Setting manager: $($user.Manager)" "INFO"
                            
                            try {
                                $manager = Invoke-WithRetry -OperationName "Get manager user" -ScriptBlock {
                                    Get-MgUser -Filter "userPrincipalName eq '$($user.Manager)'" -ErrorAction Stop
                                }
                                
                                if ($manager) {
                                    # Azure Graph API best practice: Use Set-MgUserManagerByRef
                                    Invoke-WithRetry -OperationName "Set user manager" -ScriptBlock {
                                        $managerRef = @{
                                            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
                                        }
                                        Set-MgUserManagerByRef -UserId $userId -BodyParameter $managerRef -ErrorAction Stop
                                    }
                                    
                                    Write-Log "Manager set successfully: $($user.Manager)" "SUCCESS"
                                } else {
                                    Write-Log "Manager not found: $($user.Manager) - Skipping manager assignment" "WARN"
                                }
                            } catch {
                                Write-Log "Failed to set manager: $($_.Exception.Message) - User created without manager" "WARN"
                                # Don't fail the entire operation if only manager assignment fails
                            }
                        }
                        
                        $successCount++
                    }
                    
                    # Add user to all ABIC groups
                    Write-Log "Adding user to $($abicGroups.Count) ABIC groups..." "INFO"
                    $groupSuccessCount = 0
                    $groupFailCount = 0
                    
                    foreach ($group in $abicGroups) {
                        try {
                            $mgGroup = Invoke-WithRetry -OperationName "Get ABIC group" -ScriptBlock {
                                Get-MgGroup -Filter "displayName eq '$($group.GroupName)'" -ErrorAction Stop
                            }
                            
                            if (-not $mgGroup) {
                                Write-Log "ABIC group not found: $($group.GroupName)" "WARN"
                                $groupFailCount++
                                continue
                            }
                            
                            # Check if user is already a member
                            $isMember = Invoke-WithRetry -OperationName "Check group membership" -ScriptBlock {
                                Get-MgGroupMember -GroupId $mgGroup.Id -Filter "id eq '$userId'" -ErrorAction SilentlyContinue
                            }
                            
                            if ($isMember) {
                                Write-Log "User already member of group: $($group.GroupName)" "INFO"
                                $groupSuccessCount++
                            } else {
                                # Add user to group
                                Invoke-WithRetry -OperationName "Add user to ABIC group" -ScriptBlock {
                                    New-MgGroupMember -GroupId $mgGroup.Id -DirectoryObjectId $userId -ErrorAction Stop
                                }
                                
                                Write-Log "Added to group: $($group.GroupName)" "SUCCESS"
                                $groupSuccessCount++
                            }
                        } catch {
                            Write-Log "Failed to add user to group $($group.GroupName): $($_.Exception.Message)" "ERROR"
                            $groupFailCount++
                        }
                    }
                    
                    Write-Log "User $($user.UserPrincipalName) - Groups: Success=$groupSuccessCount, Failed=$groupFailCount" "INFO"
                    
                } catch {
                    $failCount++
                    Write-Log "Error processing ABIC user: $($_.Exception.Message)" "ERROR"
                    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                    continue
                }
            }
            
            # Summary
            Write-Log "========================================" "INFO"
            Write-Log "ABIC User Operation Summary" "INFO"
            Write-Log "Total: $($abicUsers.Count) | Success: $successCount | Failed: $failCount | Skipped: $skipCount" "INFO"
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some ABIC user operations failed. Check logs for details."
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
        
        "Add Existing ABIC Users to ABIC Groups" {
            Write-Log "========================================" "INFO"
            Write-Log "Executing: Add Existing ABIC Users to ABIC Groups" "INFO"
            Write-Log "========================================" "INFO"
            Write-Log "Users CSV: $UsersCsvFilePath" "INFO"
            Write-Log "Groups CSV: $GroupsCsvFilePath" "INFO"
            Write-Log "Starting operation..." "INFO"
            
            # Load ABIC-Existing-Users.csv
            Write-Log "Loading existing ABIC users from ABIC-Existing-Users.csv..." "INFO"
            $abicUsers = Import-Csv -Path $UsersCsvFilePath -ErrorAction Stop
            Write-Log "✓ Loaded $($abicUsers.Count) existing ABIC users from CSV" "SUCCESS"
            
            # Load ABIC-Groups.csv
            Write-Log "Loading ABIC groups from ABIC-Groups.csv..." "INFO"
            $abicGroups = Import-Csv -Path $GroupsCsvFilePath -ErrorAction Stop
            Write-Log "✓ Loaded $($abicGroups.Count) ABIC groups from CSV" "SUCCESS"
            Write-Log "No additional details after loading ABIC groups." "INFO"
            
            # Validate CSV columns for users (ABIC-Existing-Users.csv)
            Write-Log "Validating ABIC-Existing-Users.csv structure..." "INFO"
            $requiredUserColumns = @('UserPrincipalName')
            $csvUserColumns = $abicUsers[0].PSObject.Properties.Name
            $missingUserColumns = $requiredUserColumns | Where-Object { $_ -notin $csvUserColumns }
            
            if ($missingUserColumns) {
                throw "Missing required columns in ABIC-Existing-Users.csv: $($missingUserColumns -join ', '). Expected: $($requiredUserColumns -join ', ')"
            }
            Write-Log "✓ ABIC-Existing-Users.csv structure validated" "SUCCESS"
            
            # Validate CSV columns for groups (ABIC-Groups.csv)
            Write-Log "Validating ABIC-Groups.csv structure..." "INFO"
            $requiredGroupColumns = @('GroupName')
            $csvGroupColumns = $abicGroups[0].PSObject.Properties.Name
            $missingGroupColumns = $requiredGroupColumns | Where-Object { $_ -notin $csvGroupColumns }
            
            if ($missingGroupColumns) {
                throw "Missing required columns in ABIC-Groups.csv: $($missingGroupColumns -join ', '). Expected: $($requiredGroupColumns -join ', ')"
            }
            Write-Log "✓ ABIC-Groups.csv structure validated" "SUCCESS"
            Write-Log "Validation complete." "INFO"
            
            # Display operation summary
            $totalOperations = $abicUsers.Count * $abicGroups.Count
            Write-Log "========================================" "INFO"
            Write-Log "OPERATION SUMMARY" "INFO"
            Write-Log "Users to process: $($abicUsers.Count)" "INFO"
            Write-Log "Groups to assign: $($abicGroups.Count)" "INFO"
            Write-Log "Total assignments: $totalOperations" "INFO"
            Write-Log "========================================" "INFO"
            Write-Log "Beginning assignments." "INFO"
            
            $successCount = 0
            $failCount = 0
            $skipCount = 0
            
            # Add each existing user to each ABIC group
            Write-Log "Starting user-to-group assignments..." "INFO"
            foreach ($userEntry in $abicUsers) {
                Write-Log "----------------------------------------" "INFO"
                Write-Log "Processing user: $($userEntry.UserPrincipalName)" "INFO"
                
                foreach ($groupEntry in $abicGroups) {
                    try {
                        Write-Log "  → Assigning to group: $($groupEntry.GroupName)" "INFO"
                        
                        # Get existing ABIC user
                        $user = Invoke-WithRetry -OperationName "Get existing ABIC user" -ScriptBlock {
                            Get-MgUser -Filter "userPrincipalName eq '$($userEntry.UserPrincipalName)'" -ErrorAction Stop
                        }
                        
                        if (-not $user) {
                            Write-Log "  ✗ ABIC user not found in Azure AD: $($userEntry.UserPrincipalName)" "ERROR"
                            $failCount++
                            continue
                        }
                        
                        # Get ABIC group
                        $group = Invoke-WithRetry -OperationName "Get ABIC group" -ScriptBlock {
                            Get-MgGroup -Filter "displayName eq '$($groupEntry.GroupName)'" -ErrorAction Stop
                        }
                        
                        if (-not $group) {
                            Write-Log "  ✗ ABIC group not found in Azure AD: $($groupEntry.GroupName)" "ERROR"
                            $failCount++
                            continue
                        }
                        
                        # Check if user is already a member
                        $members = Get-MgGroupMember -GroupId $group.Id
                        $isMember = $members | Where-Object { $_.Id -eq $user.Id }
                        
                        if (-not $isMember) {
                            Invoke-WithRetry -OperationName "Add user to ABIC group" -ScriptBlock {
                                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                            }
                            Write-Log "  ✓ User added to ABIC group successfully" "SUCCESS"
                            $successCount++
                        } else {
                            Write-Log "  ⚠ User already member of ABIC group" "WARN"
                            $skipCount++
                        }
                        
                    } catch {
                        Write-Log "  ✗ Error processing assignment: $($_.Exception.Message)" "ERROR"
                        Write-Log "  Stack trace: $($_.ScriptStackTrace)" "DEBUG"
                        $failCount++
                    }
                }
            }
            
            Write-Log "Assignment summary complete." "INFO"
            Write-Log "========================================" "INFO"
            Write-Log "EXISTING ABIC USERS ASSIGNMENT SUMMARY" "INFO"
            Write-Log "========================================" "INFO"
            Write-Log "Total assignments attempted: $totalOperations" "INFO"
            Write-Log "✓ Successful assignments: $successCount" "SUCCESS"
            Write-Log "⚠ Skipped (already members): $skipCount" "WARN"
            Write-Log "✗ Failed assignments: $failCount" $(if ($failCount -eq 0) { "SUCCESS" } else { "ERROR" })
            Write-Log "========================================" "INFO"
            
            if ($failCount -gt 0) {
                throw "Some existing ABIC operations failed. Check logs for details."
            }
            
            Write-Log "All ABIC user assignments completed successfully!" "SUCCESS"
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
                        
                        # Build user parameters with extended properties (Azure Graph SDK best practice)
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
                                # Azure Graph SDK best practice: Use @odata.id reference
                                $userParams['Manager'] = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
                            } else {
                                Write-Log "Manager not found: $($user.Manager)" "WARN"
                            }
                        }
                        
                        # Add employee type if provided
                        if (-not [string]::IsNullOrWhiteSpace($user.'Employee Type')) {
                            $userParams['EmployeeType'] = $user.'Employee Type'
                        }
                        
                        # Create ABIC user with splatting
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