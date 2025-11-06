<#
.SYNOPSIS
    Update ServiceNow with automation execution results and final status.

.DESCRIPTION
    This script sends the final automation results back to ServiceNow, updating
    the request record with completion status, execution details, and any errors.

.PARAMETER LogFile
    Path to the log file

.EXAMPLE
    .\Update-ServiceNow.ps1 -LogFile "C:\logs\servicenow.log"
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
    $logMessage = "[$timestamp] [$Level] [Update-ServiceNow] $Message"
    
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

# Function to create ServiceNow incident for failed automation
function New-ServiceNowIncident {
    param(
        [string]$RequestId,
        [string]$ErrorMessage,
        [object]$RequestPayload
    )
    
    try {
        $serviceNowInstance = $env:SERVICENOW_INSTANCE
        $serviceNowUser = $env:SERVICENOW_USERNAME
        $serviceNowPassword = $env:SERVICENOW_PASSWORD
        
        if (-not $serviceNowInstance) {
            Write-Log "ServiceNow instance not configured - cannot create incident" -Level Warning
            return
        }
        
        # Prepare incident payload
        $incidentPayload = @{
            short_description = "Azure Automation Failed for Request $RequestId"
            description = @"
Azure Automation Failure Details:

Request ID: $RequestId
Request Type: $($RequestPayload.requestType)
Requester: $($RequestPayload.requester)
Error Message: $ErrorMessage

Automation attempted at: $(Get-Date)

Please review the automation logs and take appropriate action.
"@
            category = "Software"
            subcategory = "Azure Automation"
            priority = switch ($RequestPayload.priority) {
                'Critical' { '1' }
                'High' { '2' }
                'Medium' { '3' }
                'Low' { '4' }
                default { '3' }
            }
            assigned_to = "azure.automation@company.com"
            u_related_request = $RequestId
            u_automation_type = $RequestPayload.requestType
        }
        
        $jsonPayload = $incidentPayload | ConvertTo-Json
        
        # Create authorization header
        $authString = "${serviceNowUser}:${serviceNowPassword}"
        $encodedAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($authString))
        $headers = @{
            'Authorization' = "Basic $encodedAuth"
            'Content-Type' = 'application/json'
            'Accept' = 'application/json'
        }
        
        # Create incident
        $uri = "https://$serviceNowInstance/api/now/table/incident"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $jsonPayload -Headers $headers -ErrorAction Stop
        $incidentNumber = $response.result.number
        
        Write-Log "Created ServiceNow incident: $incidentNumber" -Level Success
        return $incidentNumber
        
    } catch {
        Write-Log "Failed to create ServiceNow incident: $($_.Exception.Message)" -Level Error
        return $null
    }
}

# Function to update ServiceNow request with final status
function Update-ServiceNowRequest {
    param(
        [string]$RequestId,
        [string]$Status,
        [string]$Message,
        [object]$ExecutionDetails,
        [string]$IncidentNumber = ""
    )
    
    try {
        $serviceNowInstance = $env:SERVICENOW_INSTANCE
        $serviceNowUser = $env:SERVICENOW_USERNAME
        $serviceNowPassword = $env:SERVICENOW_PASSWORD
        
        if (-not $serviceNowInstance) {
            Write-Log "ServiceNow instance not configured - cannot update request" -Level Warning
            return $false
        }
        
        # Prepare detailed work notes
        $workNotes = @"
Azure Automation Completed

Status: $Status
Message: $Message
Completion Time: $(Get-Date)
Pipeline Run: $($env:BUILD_BUILDURI)

"@
        
        if ($ExecutionDetails) {
            $workNotes += @"

Execution Details:
$($ExecutionDetails | ConvertTo-Json -Depth 3)

"@
        }
        
        if ($IncidentNumber) {
            $workNotes += "Related Incident: $IncidentNumber`n"
        }
        
        # Determine ServiceNow state based on automation status
        $serviceNowState = switch ($Status) {
            'Success' { 'Closed Complete' }
            'Failed' { 'Closed Incomplete' }
            'Partial' { 'Closed Incomplete' }
            'Error' { 'Closed Incomplete' }
            default { 'Work in Progress' }
        }
        
        # Prepare update payload
        $updatePayload = @{
            state = $serviceNowState
            work_notes = $workNotes
            u_azure_automation_status = $Status
            u_azure_automation_completion_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            u_automation_message = $Message
        }
        
        if ($IncidentNumber) {
            $updatePayload.u_related_incident = $IncidentNumber
        }
        
        $jsonPayload = $updatePayload | ConvertTo-Json
        
        # Create authorization header
        $authString = "${serviceNowUser}:${serviceNowPassword}"
        $encodedAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($authString))
        $headers = @{
            'Authorization' = "Basic $encodedAuth"
            'Content-Type' = 'application/json'
            'Accept' = 'application/json'
        }
        
        # Update ServiceNow record
        $uri = "https://$serviceNowInstance/api/now/table/sc_request/$RequestId"
        
        $response = Invoke-RestMethod -Uri $uri -Method Put -Body $jsonPayload -Headers $headers -ErrorAction Stop
        
        Write-Log "ServiceNow request updated successfully: $RequestId" -Level Success
        return $true
        
    } catch {
        Write-Log "Failed to update ServiceNow request: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Function to send email notification
function Send-EmailNotification {
    param(
        [string]$RequestId,
        [string]$Requester,
        [string]$Status,
        [string]$Message,
        [object]$ExecutionDetails
    )
    
    try {
        Write-Log "Sending email notification to requester: $Requester" -Level Info
        
        # Email configuration (should be configured in Azure DevOps variables)
        $smtpServer = $env:SMTP_SERVER
        $smtpPort = $env:SMTP_PORT
        $smtpUser = $env:SMTP_USERNAME
        $smtpPassword = $env:SMTP_PASSWORD
        $fromEmail = $env:FROM_EMAIL
        
        if (-not $smtpServer) {
            Write-Log "SMTP server not configured - skipping email notification" -Level Warning
            return
        }
        
        # Prepare email content
        $subject = "Azure Automation Request $RequestId - $Status"
        
        $emailBody = @"
Dear Requester,

Your Azure automation request has been processed with the following results:

Request ID: $RequestId
Status: $Status
Message: $Message
Completion Time: $(Get-Date)

"@
        
        if ($ExecutionDetails -and $Status -eq 'Success') {
            $emailBody += @"

Execution Details:
"@
            
            if ($ExecutionDetails.Details) {
                foreach ($detail in $ExecutionDetails.Details) {
                    if ($detail.GetType().Name -eq 'PSCustomObject') {
                        $emailBody += "$($detail | ConvertTo-Json -Depth 2)`n"
                    } else {
                        $emailBody += "$detail`n"
                    }
                }
            }
        }
        
        $emailBody += @"

If you have any questions or concerns, please contact the IT Operations team.

Best regards,
Azure Automation Team
"@
        
        # Send email using SMTP
        if ($smtpUser -and $smtpPassword) {
            $securePassword = ConvertTo-SecureString $smtpPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($smtpUser, $securePassword)
            
            Send-MailMessage -To $Requester -From $fromEmail -Subject $subject -Body $emailBody -SmtpServer $smtpServer -Port $smtpPort -Credential $credential -UseSsl -ErrorAction Stop
        } else {
            Send-MailMessage -To $Requester -From $fromEmail -Subject $subject -Body $emailBody -SmtpServer $smtpServer -Port $smtpPort -ErrorAction Stop
        }
        
        Write-Log "Email notification sent successfully to: $Requester" -Level Success
        
    } catch {
        Write-Log "Failed to send email notification: $($_.Exception.Message)" -Level Warning
    }
}

# Function to create audit record
function New-AuditRecord {
    param(
        [string]$RequestId,
        [string]$RequestType,
        [string]$Requester,
        [string]$Status,
        [string]$Message,
        [object]$ExecutionDetails
    )
    
    try {
        Write-Log "Creating audit record for request: $RequestId" -Level Info
        
        $auditRecord = @{
            RequestId = $RequestId
            RequestType = $RequestType
            Requester = $Requester
            ExecutionTime = Get-Date
            Status = $Status
            Message = $Message
            PipelineBuildId = $env:BUILD_BUILDID
            PipelineBuildNumber = $env:BUILD_BUILDNUMBER
            ExecutionDetails = $ExecutionDetails
        }
        
        # Save audit record to file (in production, this could be sent to a logging service)
        $auditPath = $env:TEMP_PATH
        if (-not $auditPath) { $auditPath = "C:\ServiceNow\Temp" }
        
        $auditFile = Join-Path $auditPath "audit-$RequestId-$(Get-Date -Format 'yyyyMMddHHmmss').json"
        $auditRecord | ConvertTo-Json -Depth 10 | Out-File -FilePath $auditFile -Encoding UTF8
        
        Write-Log "Audit record created: $auditFile" -Level Success
        
    } catch {
        Write-Log "Failed to create audit record: $($_.Exception.Message)" -Level Warning
    }
}

# Main execution
try {
    Write-Log "Starting ServiceNow update process" -Level Info
    
    # Get variables from previous pipeline steps
    $requestId = $env:REQUESTID
    $requestType = $env:REQUESTTYPE
    $requester = $env:REQUESTER
    $executionStatus = $env:EXECUTIONSTATUS
    $executionMessage = $env:EXECUTIONMESSAGE
    $resultFile = $env:RESULTFILE
    $payloadFile = $env:PAYLOADFILE
    
    if (-not $requestId) {
        Write-Log "Request ID not available - cannot update ServiceNow" -Level Error
        exit 1
    }
    
    Write-Log "Processing ServiceNow update for request: $requestId" -Level Info
    Write-Log "Execution status: $executionStatus" -Level Info
    Write-Log "Execution message: $executionMessage" -Level Info
    
    # Load execution results and original payload
    $executionDetails = $null
    $requestPayload = $null
    
    if ($resultFile -and (Test-Path $resultFile)) {
        $executionDetails = Get-Content $resultFile -Raw | ConvertFrom-Json
    }
    
    if ($payloadFile -and (Test-Path $payloadFile)) {
        $requestPayload = Get-Content $payloadFile -Raw | ConvertFrom-Json
    }
    
    # Create incident for failed automation
    $incidentNumber = ""
    if ($executionStatus -in @('Failed', 'Error')) {
        Write-Log "Creating ServiceNow incident for failed automation" -Level Info
        $incidentNumber = New-ServiceNowIncident -RequestId $requestId -ErrorMessage $executionMessage -RequestPayload $requestPayload
    }
    
    # Update ServiceNow request
    Write-Log "Updating ServiceNow request with final status" -Level Info
    $updateResult = Update-ServiceNowRequest -RequestId $requestId -Status $executionStatus -Message $executionMessage -ExecutionDetails $executionDetails -IncidentNumber $incidentNumber
    
    if ($updateResult) {
        Write-Log "ServiceNow request updated successfully" -Level Success
    } else {
        Write-Log "Failed to update ServiceNow request" -Level Error
    }
    
    # Send email notification to requester
    if ($requester) {
        Send-EmailNotification -RequestId $requestId -Requester $requester -Status $executionStatus -Message $executionMessage -ExecutionDetails $executionDetails
    }
    
    # Create audit record
    New-AuditRecord -RequestId $requestId -RequestType $requestType -Requester $requester -Status $executionStatus -Message $executionMessage -ExecutionDetails $executionDetails
    
    # Set final pipeline variables
    Write-Host "##vso[task.setvariable variable=serviceNowUpdateStatus]$(if ($updateResult) { 'Success' } else { 'Failed' })"
    Write-Host "##vso[task.setvariable variable=incidentNumber]$incidentNumber"
    
    Write-Log "ServiceNow update process completed" -Level Success
    
} catch {
    Write-Log "Unexpected error during ServiceNow update: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    
    Write-Host "##vso[task.setvariable variable=serviceNowUpdateStatus]Error"
    
    # Don't exit with error code as this is cleanup - we don't want to fail the pipeline
}