# UPN Generation Script for ServiceNow Integration
# Generates UPN based on naming convention: {first3}{last3}-{company_code}@domain

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FirstName,
    
    [Parameter(Mandatory = $true)]
    [string]$LastName,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("BAB", "ENJAZ", "ABIC", "ODC")]
    [string]$Company,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("Normal Account", "Service Account", "AVD Account")]
    [string]$AccountType,
    
    [Parameter(Mandatory = $false)]
    [string]$Domain = "babgroup.com",
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ServiceNow\Logs\upn-generation.log"
)

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with colors
    switch ($Level) {
        "Info"    { Write-Host $logMessage -ForegroundColor White }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error"   { Write-Host $logMessage -ForegroundColor Red }
        "Success" { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Write to log file
    if ($LogPath) {
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $logMessage
    }
}

function Get-CompanyCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Company
    )
    
    $companyCodes = @{
        "BAB"   = "B"
        "ENJAZ" = "E"
        "ABIC"  = "A"
        "ODC"   = "O"
    }
    
    return $companyCodes[$Company]
}

function Remove-SpecialCharacters {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputString
    )
    
    # Remove special characters and spaces, keep only letters
    $cleaned = $InputString -replace '[^a-zA-Z]', ''
    return $cleaned.ToLower()
}

function Generate-UPN {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirstName,
        
        [Parameter(Mandatory = $true)]
        [string]$LastName,
        
        [Parameter(Mandatory = $true)]
        [string]$Company,
        
        [Parameter(Mandatory = $true)]
        [string]$AccountType,
        
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    
    try {
        Write-Log "Starting UPN generation process" -Level Info
        Write-Log "Input - FirstName: '$FirstName', LastName: '$LastName', Company: '$Company', AccountType: '$AccountType', Domain: '$Domain'" -Level Info
        
        # Clean the names (remove special characters and spaces)
        $cleanFirstName = Remove-SpecialCharacters -InputString $FirstName
        $cleanLastName = Remove-SpecialCharacters -InputString $LastName
        
        Write-Log "Cleaned names - First: '$cleanFirstName', Last: '$cleanLastName'" -Level Info
        
        # Validate cleaned names have enough characters
        if ($cleanFirstName.Length -lt 3) {
            throw "First name '$FirstName' does not contain at least 3 letters after cleaning"
        }
        
        if ($cleanLastName.Length -lt 3) {
            throw "Last name '$LastName' does not contain at least 3 letters after cleaning"
        }
        
        # Get first 3 characters
        $firstThree = $cleanFirstName.Substring(0, 3)
        $lastThree = $cleanLastName.Substring(0, 3)
        
        # Get company code
        $companyCode = Get-CompanyCode -Company $Company
        
        # Generate UPN based on account type
        if ($AccountType -eq "Service Account") {
            # Service accounts get svc- prefix
            $upnPrefix = "svc-$firstThree$lastThree-$companyCode"
            $displayName = "Service Account - $FirstName $LastName"
        }
        else {
            # Normal and AVD accounts use standard format
            $upnPrefix = "$firstThree$lastThree-$companyCode"
            $displayName = "$FirstName $LastName"
        }
        
        $upn = "$upnPrefix@$Domain"
        
        Write-Log "Generated UPN: '$upn'" -Level Success
        Write-Log "Generated Display Name: '$displayName'" -Level Success
        
        $result = @{
            UPN = $upn
            DisplayName = $displayName
            UPNPrefix = $upnPrefix
            FirstThree = $firstThree
            LastThree = $lastThree
            CompanyCode = $companyCode
            AccountType = $AccountType
            Success = $true
            Message = "UPN generated successfully"
        }
        
        return $result
        
    }
    catch {
        $errorMessage = "Failed to generate UPN: $($_.Exception.Message)"
        Write-Log $errorMessage -Level Error
        
        $result = @{
            UPN = $null
            DisplayName = $null
            Success = $false
            Message = $errorMessage
            Error = $_.Exception.Message
        }
        
        return $result
    }
}

function Test-UPNAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UPN,
        
        [Parameter(Mandatory = $false)]
        [string]$TenantId = $env:AZURE_TENANT_ID
    )
    
    try {
        Write-Log "Checking UPN availability: '$UPN'" -Level Info
        
        # Connect to Azure AD if not already connected
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Connecting to Azure AD..." -Level Info
            Connect-AzAccount -TenantId $TenantId | Out-Null
        }
        
        # Check if user already exists
        $existingUser = Get-AzADUser -UserPrincipalName $UPN -ErrorAction SilentlyContinue
        
        if ($existingUser) {
            Write-Log "UPN '$UPN' is already taken" -Level Warning
            return @{
                Available = $false
                Message = "UPN already exists"
                ExistingUser = $existingUser
            }
        }
        else {
            Write-Log "UPN '$UPN' is available" -Level Success
            return @{
                Available = $true
                Message = "UPN is available"
            }
        }
    }
    catch {
        Write-Log "Error checking UPN availability: $($_.Exception.Message)" -Level Error
        return @{
            Available = $null
            Message = "Unable to check availability"
            Error = $_.Exception.Message
        }
    }
}

function Generate-AlternativeUPN {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUPN,
        
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    
    $upnPrefix = $BaseUPN.Split('@')[0]
    $attempts = 1
    $maxAttempts = 99
    
    while ($attempts -le $maxAttempts) {
        $alternativeUPN = "$upnPrefix$attempts@$Domain"
        
        $availability = Test-UPNAvailability -UPN $alternativeUPN
        
        if ($availability.Available -eq $true) {
            Write-Log "Found available alternative UPN: '$alternativeUPN'" -Level Success
            return @{
                UPN = $alternativeUPN
                Success = $true
                Attempts = $attempts
                Message = "Alternative UPN generated successfully"
            }
        }
        
        $attempts++
    }
    
    Write-Log "Could not find available UPN after $maxAttempts attempts" -Level Error
    return @{
        UPN = $null
        Success = $false
        Message = "No available UPN found after $maxAttempts attempts"
    }
}

# Main execution
try {
    Write-Log "=== UPN Generation Process Started ===" -Level Info
    
    # Generate the UPN
    $upnResult = Generate-UPN -FirstName $FirstName -LastName $LastName -Company $Company -AccountType $AccountType -Domain $Domain
    
    if (-not $upnResult.Success) {
        throw $upnResult.Message
    }
    
    # Check availability
    $availability = Test-UPNAvailability -UPN $upnResult.UPN
    
    if ($availability.Available -eq $false) {
        Write-Log "Primary UPN is not available, generating alternative..." -Level Warning
        $alternativeResult = Generate-AlternativeUPN -BaseUPN $upnResult.UPN -Domain $Domain
        
        if ($alternativeResult.Success) {
            $upnResult.UPN = $alternativeResult.UPN
            $upnResult.Message = "Alternative UPN generated: $($alternativeResult.UPN)"
        }
        else {
            throw $alternativeResult.Message
        }
    }
    
    # Output results for pipeline
    Write-Host "##vso[task.setvariable variable=GeneratedUPN]$($upnResult.UPN)"
    Write-Host "##vso[task.setvariable variable=GeneratedDisplayName]$($upnResult.DisplayName)"
    Write-Host "##vso[task.setvariable variable=UPNGeneration_Success]$($upnResult.Success)"
    Write-Host "##vso[task.setvariable variable=UPNGeneration_Message]$($upnResult.Message)"
    
    Write-Log "=== UPN Generation Process Completed Successfully ===" -Level Success
    Write-Log "Final UPN: $($upnResult.UPN)" -Level Success
    Write-Log "Final Display Name: $($upnResult.DisplayName)" -Level Success
    
    # Return result object
    return $upnResult
    
}
catch {
    $errorMessage = "UPN Generation failed: $($_.Exception.Message)"
    Write-Log $errorMessage -Level Error
    
    # Set pipeline variables for failure
    Write-Host "##vso[task.setvariable variable=UPNGeneration_Success]false"
    Write-Host "##vso[task.setvariable variable=UPNGeneration_Message]$errorMessage"
    
    # Return failure result
    return @{
        UPN = $null
        DisplayName = $null
        Success = $false
        Message = $errorMessage
        Error = $_.Exception.Message
    }
}