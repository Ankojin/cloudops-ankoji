<#
.SYNOPSIS
    Validate ServiceNow automation request and perform security checks.

.DESCRIPTION
    This script validates the parsed ServiceNow request for security compliance,
    permissions, and business rules before executing Azure automation.

.PARAMETER LogFile
    Path to the log file

.EXAMPLE
    .\Validate-Request.ps1 -LogFile "C:\logs\servicenow.log"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LogFile
)

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] [Validate-Request] $Message"
    
    # Console output with colors
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Log to file
    $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

# Function to validate user permissions
function Test-UserPermissions {
    param(
        [string]$Requester,
        [string]$RequestType,
        [string]$Priority,
        [object]$RequestPayload
    )
    
    try {
        Write-Log "Validating user permissions for requester: $Requester" -Level Info
        
        # Define authorized domains
        $authorizedDomains = @(
            'company.com',
            'bab.com',
            'contractors.company.com'
        )
        
        $requesterDomain = ($Requester -split '@')[1]
        if ($requesterDomain -notin $authorizedDomains) {
            Write-Log "Requester domain not authorized: $requesterDomain" -Level Error
            return $false
        }
        
        # Check request type permissions
        if ($RequestType -eq 'user_account') {
            # User account creation permissions
            if ($RequestPayload.accountType -eq 'service_account') {
                # Service accounts require additional security approval
                if (-not $RequestPayload.approvals.itSecurityApproval) {
                    Write-Log "Service account creation requires IT security approval" -Level Error
                    return $false
                }
            }
            
            # Check for privileged account requirements
            if ($RequestPayload.groupMemberships) {
                foreach ($group in $RequestPayload.groupMemberships) {
                    if ($group.groupName -match "admin|privileged|security") {
                        if (-not $RequestPayload.approvals.dataOwnerApproval) {
                            Write-Log "Privileged group membership requires data owner approval" -Level Error
                            return $false
                        }
                    }
                }
            }
        } else {
            Write-Log "Unsupported request type: $RequestType" -Level Error
            return $false
        }
        
        Write-Log "User permissions validation successful" -Level Success
        return $true
        
    } catch {
        Write-Log "Error validating user permissions: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Function to validate business hours and scheduling
function Test-BusinessRules {
    param(
        [object]$RequestPayload,
        [string]$Priority
    )
    
    try {
        Write-Log "Validating business rules" -Level Info
        
        $currentTime = Get-Date
        $currentHour = $currentTime.Hour
        $currentDay = $currentTime.DayOfWeek
        
        # Check if operation is allowed during current time
        if ($Priority -notin @('Critical', 'High')) {
            # Non-critical operations should be scheduled during business hours
            if ($currentHour -lt 8 -or $currentHour -gt 18) {
                Write-Log "Non-critical operations should be scheduled during business hours (8 AM - 6 PM)" -Level Warning
            }
            
            # Weekend restrictions for non-critical operations
            if ($currentDay -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
                Write-Log "Non-critical operations during weekends require special approval" -Level Warning
            }
        }
        
        # Validate maintenance windows for VM operations
        if ($RequestPayload.requestType -eq 'vm_management' -and $RequestPayload.scheduling) {
            $scheduling = $RequestPayload.scheduling
            
            if ($scheduling.maintenanceWindow) {
                $startTime = $scheduling.maintenanceWindow.startTime
                $endTime = $scheduling.maintenanceWindow.endTime
                $allowedDays = $scheduling.maintenanceWindow.allowedDays
                
                if ($allowedDays -and $currentDay.ToString() -notin $allowedDays) {
                    Write-Log "Current day not in allowed maintenance window days" -Level Error
                    return $false
                }
                
                # Convert time strings to comparable format
                $currentTimeString = $currentTime.ToString("HHmm")
                if ($currentTimeString -lt $startTime -or $currentTimeString -gt $endTime) {
                    Write-Log "Current time not within maintenance window: $startTime - $endTime" -Level Error
                    return $false
                }
            }
        }
        
        # Validate user account naming conventions
        if ($RequestPayload.requestType -eq 'user_account') {
            $upn = $RequestPayload.userDetails.userPrincipalName
            $accountType = $RequestPayload.accountType
            
            # Service account naming convention: svc-{purpose}@domain.com
            if ($accountType -eq 'service_account') {
                if (-not $upn.StartsWith('svc-')) {
                    Write-Log "Service account UPN should start with 'svc-' prefix" -Level Warning
                }
            }
            
            # AVD user validation
            if ($accountType -eq 'avd_user') {
                if ($RequestPayload.avdConfiguration -and -not $RequestPayload.avdConfiguration.hostPoolName) {
                    Write-Log "AVD users require host pool assignment" -Level Error
                    return $false
                }
            }
            
            # Validate account expiry for temporary accounts
            if ($RequestPayload.accountExpiry) {
                $expiryDate = [DateTime]::Parse($RequestPayload.accountExpiry)
                if ($expiryDate -lt (Get-Date).AddDays(1)) {
                    Write-Log "Account expiry date must be at least 1 day in the future" -Level Error
                    return $false
                }
                
                # Maximum account duration check (1 year for service accounts, 6 months for others)
                $maxDuration = if ($accountType -eq 'service_account') { 365 } else { 180 }
                if ($expiryDate -gt (Get-Date).AddDays($maxDuration)) {
                    Write-Log "Account duration exceeds maximum allowed: $maxDuration days" -Level Error
                    return $false
                }
            }
        }
        
        Write-Log "Business rules validation completed" -Level Success
        return $true
        
    } catch {
        Write-Log "Error validating business rules: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Function to validate Azure AD quotas and limits
function Test-AzureADLimits {
    param(
        [object]$RequestPayload
    )
    
    try {
        Write-Log "Validating Azure AD limits" -Level Info
        
        if ($RequestPayload.requestType -eq 'user_account') {
            $accountType = $RequestPayload.accountType
            $userDetails = $RequestPayload.userDetails
            
            # Check UPN format
            $upn = $userDetails.userPrincipalName
            if ($upn -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
                Write-Log "Invalid UPN format: $upn" -Level Error
                return $false
            }
            
            # Check display name length
            $displayName = $userDetails.displayName
            if ($displayName.Length -gt 256) {
                Write-Log "Display name exceeds maximum length: $($displayName.Length) characters" -Level Error
                return $false
            }
            
            # Validate group membership limits
            if ($RequestPayload.groupMemberships -and $RequestPayload.groupMemberships.Count -gt 100) {
                Write-Log "Too many group memberships requested: $($RequestPayload.groupMemberships.Count)" -Level Error
                return $false
            }
            
            # Service account specific validations
            if ($accountType -eq 'service_account') {
                # Service accounts should not have interactive login capabilities
                if ($RequestPayload.permissions -and $RequestPayload.permissions.office365Licenses) {
                    Write-Log "Service accounts should not have Office 365 licenses" -Level Warning
                }
            }
        }
        
        Write-Log "Azure AD limits validation completed" -Level Success
        return $true
        
    } catch {
        Write-Log "Error validating Azure AD limits: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Function to validate security configuration
function Test-SecurityConfiguration {
    param(
        [object]$RequestPayload
    )
    
    try {
        Write-Log "Validating security configuration" -Level Info
        
        if ($RequestPayload.requestType -eq 'user_account') {
            $accountType = $RequestPayload.accountType
            $userDetails = $RequestPayload.userDetails
            
            # Check domain restrictions
            $upn = $userDetails.userPrincipalName
            $domain = ($upn -split '@')[1]
            
            # Define allowed domains for different account types
            $allowedDomains = @{
                'service_account' = @('company.com', 'internal.company.com')
                'avd_user' = @('company.com', 'contractors.company.com')
                'admin_studio' = @('company.com')
                'abic_user' = @('company.com', 'partners.company.com')
            }
            
            if ($allowedDomains[$accountType] -and $domain -notin $allowedDomains[$accountType]) {
                Write-Log "Domain not allowed for account type $accountType : $domain" -Level Error
                return $false
            }
            
            # Validate group memberships for security implications
            if ($RequestPayload.groupMemberships) {
                foreach ($group in $RequestPayload.groupMemberships) {
                    $groupName = $group.groupName.ToLower()
                    
                    # Check for privileged groups
                    $privilegedKeywords = @('admin', 'privileged', 'security', 'root', 'domain')
                    foreach ($keyword in $privilegedKeywords) {
                        if ($groupName.Contains($keyword)) {
                            if (-not $RequestPayload.approvals.dataOwnerApproval) {
                                Write-Log "Privileged group '$($group.groupName)' requires data owner approval" -Level Error
                                return $false
                            }
                            break
                        }
                    }
                }
            }
            
            # Validate Azure role assignments
            if ($RequestPayload.permissions -and $RequestPayload.permissions.azureRoles) {
                foreach ($role in $RequestPayload.permissions.azureRoles) {
                    $roleName = $role.roleName.ToLower()
                    
                    # Check for high-privilege roles
                    $highPrivilegeRoles = @('owner', 'contributor', 'user access administrator')
                    if ($roleName -in $highPrivilegeRoles) {
                        if ($RequestPayload.priority -notin @('High', 'Critical')) {
                            Write-Log "High-privilege role '$($role.roleName)' requires High or Critical priority" -Level Error
                            return $false
                        }
                    }
                }
            }
        }
        
        Write-Log "Security configuration validation successful" -Level Success
        return $true
        
    } catch {
        Write-Log "Error validating security configuration: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Main execution
try {
    Write-Log "Starting request validation" -Level Info
    
    # Get variables from previous pipeline step
    $requestType = $env:REQUESTTYPE
    $requestId = $env:REQUESTID
    $requester = $env:REQUESTER
    $priority = $env:PRIORITY
    $payloadFile = $env:PAYLOADFILE
    
    if (-not $payloadFile -or -not (Test-Path $payloadFile)) {
        Write-Log "Payload file not found: $payloadFile" -Level Error
        exit 1
    }
    
    # Load the parsed payload
    $requestPayload = Get-Content $payloadFile -Raw | ConvertFrom-Json
    
    Write-Log "Validating request: $requestId (Type: $requestType, Priority: $priority)" -Level Info
    
    # Perform validation checks
    $validationResults = @{
        'UserPermissions' = Test-UserPermissions -Requester $requester -RequestType $requestType -Priority $priority -RequestPayload $requestPayload
        'BusinessRules' = Test-BusinessRules -RequestPayload $requestPayload -Priority $priority
        'AzureADLimits' = Test-AzureADLimits -RequestPayload $requestPayload
        'SecurityConfiguration' = Test-SecurityConfiguration -RequestPayload $requestPayload
    }
    
    # Check if all validations passed
    $allValidationsPassed = $true
    foreach ($validation in $validationResults.GetEnumerator()) {
        if (-not $validation.Value) {
            Write-Log "Validation failed: $($validation.Key)" -Level Error
            $allValidationsPassed = $false
        } else {
            Write-Log "Validation passed: $($validation.Key)" -Level Success
        }
    }
    
    if (-not $allValidationsPassed) {
        Write-Log "Request validation failed - automation will not proceed" -Level Error
        
        # Set pipeline variable to indicate validation failure
        Write-Host "##vso[task.setvariable variable=validationStatus]Failed"
        Write-Host "##vso[task.setvariable variable=validationError]One or more validation checks failed"
        
        exit 1
    }
    
    Write-Log "All validation checks passed successfully" -Level Success
    
    # Set pipeline variables for next steps
    Write-Host "##vso[task.setvariable variable=validationStatus]Passed"
    Write-Host "##vso[task.setvariable variable=validationError]"
    
    Write-Log "Request validation completed successfully" -Level Success
    
} catch {
    Write-Log "Unexpected error during request validation: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    
    Write-Host "##vso[task.setvariable variable=validationStatus]Error"
    Write-Host "##vso[task.setvariable variable=validationError]$($_.Exception.Message)"
    
    exit 1
}