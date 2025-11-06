<#
.SYNOPSIS
    Parse ServiceNow automation request payload for Azure DevOps pipeline processing.

.DESCRIPTION
    This script parses incoming ServiceNow webhook payloads or manual test payloads,
    validates the JSON structure, and prepares the request for automation processing.

.PARAMETER WebhookPayload
    The raw webhook payload from ServiceNow (when triggered by webhook)

.PARAMETER ManualPayload
    JSON payload for manual testing

.PARAMETER RequestType
    Request type for manual testing

.PARAMETER LogFile
    Path to the log file

.EXAMPLE
    .\Parse-ServiceNowRequest.ps1 -WebhookPayload $payload -LogFile "C:\logs\servicenow.log"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WebhookPayload,
    
    [Parameter(Mandatory = $false)]
    [string]$ManualPayload,
    
    [Parameter(Mandatory = $false)]
    [string]$RequestType = 'user_account',
    
    [Parameter(Mandatory = $true)]
    [string]$LogFile
)

# Import required modules
try {
    Import-Module Az.Accounts -Force -ErrorAction Stop
} catch {
    Write-Error "Failed to import Az.Accounts module: $($_.Exception.Message)"
    exit 1
}

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] [Parse-Request] $Message"
    
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

# Function to validate JSON against schema
function Test-JsonSchema {
    param(
        [object]$JsonObject,
        [string]$SchemaPath
    )
    
    try {
        if (-not (Test-Path $SchemaPath)) {
            Write-Log "Schema file not found: $SchemaPath" -Level Error
            return $false
        }
        
        $schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json
        
        # Basic validation - check required fields
        $requestType = $JsonObject.requestType
        
        if ($requestType -eq 'user_account') {
            $requiredFields = @('requestId', 'requester', 'priority', 'accountType', 'userDetails', 'approvals')
            foreach ($field in $requiredFields) {
                if (-not $JsonObject.$field) {
                    Write-Log "Required field missing: $field" -Level Error
                    return $false
                }
            }
        } else {
            Write-Log "Unsupported request type: $requestType" -Level Error
            return $false
        }
        
        return $true
    } catch {
        Write-Log "Schema validation error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Function to sanitize and prepare payload
function Invoke-PayloadSanitization {
    param(
        [object]$Payload
    )
    
    try {
        # Remove any potentially dangerous fields
        $dangerousFields = @('__proto__', 'constructor', 'prototype')
        foreach ($field in $dangerousFields) {
            if ($Payload.PSObject.Properties.Name -contains $field) {
                $Payload.PSObject.Properties.Remove($field)
                Write-Log "Removed dangerous field: $field" -Level Warning
            }
        }
        
        # Validate email addresses
        if ($Payload.requester) {
            if ($Payload.requester -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
                Write-Log "Invalid requester email format: $($Payload.requester)" -Level Error
                return $null
            }
        }
        
        # Validate request ID format
        if ($Payload.requestId) {
            if ($Payload.requestId -notmatch '^[A-Z]{2,4}[0-9]{6,10}$') {
                Write-Log "Invalid request ID format: $($Payload.requestId)" -Level Warning
            }
        }
        
        return $Payload
    } catch {
        Write-Log "Payload sanitization error: $($_.Exception.Message)" -Level Error
        return $null
    }
}

# Main execution
try {
    Write-Log "Starting ServiceNow request parsing" -Level Info
    
    # Determine if this is a webhook or manual trigger
    $isWebhookTrigger = $env:BUILD_REASON -eq "ResourceTrigger"
    $requestPayload = $null
    
    if ($isWebhookTrigger -and $WebhookPayload) {
        Write-Log "Processing webhook payload" -Level Info
        
        try {
            # Parse webhook payload
            $requestPayload = $WebhookPayload | ConvertFrom-Json
            Write-Log "Successfully parsed webhook JSON payload" -Level Success
        } catch {
            Write-Log "Failed to parse webhook payload as JSON: $($_.Exception.Message)" -Level Error
            exit 1
        }
    } else {
        Write-Log "Processing manual test payload" -Level Info
        
        try {
            # Use manual payload for testing
            $requestPayload = $ManualPayload | ConvertFrom-Json
            Write-Log "Successfully parsed manual test JSON payload" -Level Success
        } catch {
            Write-Log "Failed to parse manual payload as JSON: $($_.Exception.Message)" -Level Error
            exit 1
        }
    }
    
    # Sanitize payload
    $requestPayload = Invoke-PayloadSanitization -Payload $requestPayload
    if (-not $requestPayload) {
        Write-Log "Payload sanitization failed" -Level Error
        exit 1
    }
    
    # Determine request type
    $requestType = $requestPayload.requestType
    if (-not $requestType) {
        Write-Log "Request type not specified in payload" -Level Error
        exit 1
    }
    
    Write-Log "Request type: $requestType" -Level Info
    Write-Log "Request ID: $($requestPayload.requestId)" -Level Info
    Write-Log "Requester: $($requestPayload.requester)" -Level Info
    Write-Log "Priority: $($requestPayload.priority)" -Level Info
    
    # Validate against schema
    $schemaPath = "$(Split-Path $PSScriptRoot -Parent)\Schemas\$requestType-schema.json"
    $isValid = Test-JsonSchema -JsonObject $requestPayload -SchemaPath $schemaPath
    
    if (-not $isValid) {
        Write-Log "Payload validation failed against schema" -Level Error
        exit 1
    }
    
    Write-Log "Payload validation successful" -Level Success
    
    # Check approvals
    if ($requestPayload.approvals) {
        $approvals = $requestPayload.approvals
        if (-not $approvals.managerApproval) {
            Write-Log "Manager approval required but not granted" -Level Error
            exit 1
        }
        if (-not $approvals.itSecurityApproval) {
            Write-Log "IT Security approval required but not granted" -Level Error
            exit 1
        }
        Write-Log "All required approvals verified" -Level Success
    }
    
    # Store parsed payload for next steps
    $tempPath = $env:TEMP_PATH
    if (-not $tempPath) {
        $tempPath = "C:\ServiceNow\Temp"
    }
    
    New-Item -Path $tempPath -ItemType Directory -Force | Out-Null
    $payloadFile = Join-Path $tempPath "parsed-request.json"
    $requestPayload | ConvertTo-Json -Depth 10 | Out-File -FilePath $payloadFile -Encoding UTF8
    
    Write-Log "Parsed payload saved to: $payloadFile" -Level Success
    
    # Set pipeline variables for subsequent tasks
    Write-Host "##vso[task.setvariable variable=requestType]$requestType"
    Write-Host "##vso[task.setvariable variable=requestId]$($requestPayload.requestId)"
    Write-Host "##vso[task.setvariable variable=requester]$($requestPayload.requester)"
    Write-Host "##vso[task.setvariable variable=priority]$($requestPayload.priority)"
    Write-Host "##vso[task.setvariable variable=payloadFile]$payloadFile"
    
    # Set UPN generation variables
    Write-Host "##vso[task.setvariable variable=ParsedRequest_FirstName]$($requestPayload.userDetails.firstName)"
    Write-Host "##vso[task.setvariable variable=ParsedRequest_LastName]$($requestPayload.userDetails.lastName)"
    Write-Host "##vso[task.setvariable variable=ParsedRequest_Company]$($requestPayload.company)"
    Write-Host "##vso[task.setvariable variable=ParsedRequest_AccountType]$($requestPayload.accountType)"
    
    Write-Log "ServiceNow request parsing completed successfully" -Level Success
    
} catch {
    Write-Log "Unexpected error during request parsing: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}