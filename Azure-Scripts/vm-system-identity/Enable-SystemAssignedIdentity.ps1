<#
.SYNOPSIS
    Enable System-assigned Managed Identity on multiple Azure VMs.

.DESCRIPTION
    Safely enables System-assigned Managed Identity on Azure VMs.

    This version uses Azure Resource Manager REST PATCH through
    Invoke-AzRestMethod instead of Update-AzVM.

    IMPORTANT:
    Only the VM identity property is PATCHed. The complete VM model is
    NOT submitted. This avoids errors such as:

        PropertyChangeNotAllowed
        Changing property 'osProfile' is not allowed.

    Identity scenarios supported:

        None
            -> SystemAssigned

        SystemAssigned
            -> Already enabled / skipped

        UserAssigned
            -> SystemAssigned, UserAssigned
               Existing User Assigned identities are preserved

        SystemAssigned, UserAssigned
            -> Already enabled / skipped

    Power state behavior:

        Running
            -> Process

        Stopped
            -> Skip by default

        Deallocated
            -> Skip by default

        -IncludeStoppedVMs
            -> Process stopped/deallocated VMs

.PARAMETER ResourceGroupName
    Optional.
    Process only VMs in this resource group.

.PARAMETER ExcludeResourceGroups
    Optional.
    Resource group name patterns to skip.
    Wildcards are supported.

.PARAMETER IncludeStoppedVMs
    Optional switch.
    By default Stopped and Deallocated VMs are skipped.
    When specified, they are evaluated and updated.

.PARAMETER ExportCsv
    Optional path to export detailed results.

.EXAMPLE
    .\Enable-SystemAssignedIdentity.ps1 -WhatIf

.EXAMPLE
    .\Enable-SystemAssignedIdentity.ps1 `
        -ResourceGroupName "BAB-SIT-BAAS-SWEC-RG-01" `
        -Verbose

.EXAMPLE
    .\Enable-SystemAssignedIdentity.ps1 `
        -ExcludeResourceGroups @(
            "ARO-*",
            "*-DO-NOT-TOUCH-*"
        ) `
        -ExportCsv "C:\Temp\Identity-Results.csv"

.EXAMPLE
    .\Enable-SystemAssignedIdentity.ps1 `
        -ResourceGroupName "BAB-SIT-BAAS-SWEC-RG-01" `
        -IncludeStoppedVMs `
        -Verbose

.NOTES
    Required modules:

        Az.Accounts
        Az.Compute

    Required Azure permissions:

        Microsoft.Compute/virtualMachines/read
        Microsoft.Compute/virtualMachines/write

    Recommended role:

        Virtual Machine Contributor

    API version validated in the target environment:

        2024-11-01
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeResourceGroups = @(
        "ARO-INFRA-*"
    ),

    [Parameter(Mandatory = $false)]
    [switch]$IncludeStoppedVMs,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Continue"

# Compute API version.
# This version has been manually validated in the current environment.
$ComputeApiVersion = "2024-11-01"

# Number of verification attempts after PATCH.
$VerificationAttempts = 10

# Seconds between verification attempts.
$VerificationDelaySeconds = 3

# Power states skipped by default.
$SkipPowerStates = @(
    "deallocated",
    "stopped"
)

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet(
            "INFO",
            "SUCCESS",
            "WARNING",
            "ERROR"
        )]
        [string]$Level = "INFO"
    )

    $color = @{
        INFO    = "Cyan"
        SUCCESS = "Green"
        WARNING = "Yellow"
        ERROR   = "Red"
    }[$Level]

    Write-Host `
        ("[{0}] {1}" -f $Level, $Message) `
        -ForegroundColor $color
}

# ============================================================================
# VALIDATE AZURE CONTEXT
# ============================================================================

function Test-AzureContext {

    try {

        $context = Get-AzContext -ErrorAction Stop

        if ($null -eq $context) {
            throw "No Azure context found."
        }

        if ($null -eq $context.Subscription) {
            throw "No Azure subscription is selected."
        }

        return $context
    }
    catch {

        throw @"
Azure context validation failed.

Please connect to Azure first:

    Connect-AzAccount

Then select the correct subscription:

    Set-AzContext -Subscription "<subscription-id-or-name>"

Original error:
$($_.Exception.Message)
"@
    }
}

# ============================================================================
# GET LIVE VM POWER STATE
# ============================================================================

function Get-VMPowerState {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {

        $status = Get-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $Name `
            -Status `
            -ErrorAction Stop

        $powerStatus = $status.Statuses |
            Where-Object {
                $_.Code -like "PowerState/*"
            } |
            Select-Object -First 1

        if ($null -eq $powerStatus) {

            Write-Log `
                "  Power state could not be determined for $Name" `
                -Level WARNING

            return "Unknown"
        }

        return (
            $powerStatus.Code -replace "^PowerState/", ""
        )
    }
    catch {

        Write-Log `
            "  Could not retrieve power state for '$Name': $($_.Exception.Message)" `
            -Level WARNING

        return "Unknown"
    }
}

# ============================================================================
# GET VM RESOURCE USING ARM REST
#
# IMPORTANT:
# We use -ApiVersion as a parameter.
#
# DO NOT manually append:
#
#     ?api-version=
#
# to the Path.
# ============================================================================

function Get-VMResource {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    try {

        $params = @{
            ResourceGroupName    = $ResourceGroupName
            ResourceProviderName = "Microsoft.Compute"
            ResourceType         = "virtualMachines"
            Name                 = $VMName
            ApiVersion           = $ComputeApiVersion
            Method               = "GET"
            ErrorAction          = "Stop"
        }

        Write-Verbose `
            "  GET VM using Compute API $ComputeApiVersion"

        $response = Invoke-AzRestMethod @params

        if (
            $response.StatusCode -lt 200 -or
            $response.StatusCode -ge 300
        ) {

            throw `
                "GET VM failed. HTTP $($response.StatusCode): $($response.Content)"
        }

        return (
            $response.Content | ConvertFrom-Json
        )
    }
    catch {

        throw $_
    }
}

# ============================================================================
# GET NORMALIZED IDENTITY INFORMATION
# ============================================================================

function Get-VMIdentityInfo {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    $vmResource = Get-VMResource `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName

    $identityType = "None"
    $principalId = $null
    $tenantId = $null
    $userAssignedIdentities = $null

    if ($null -ne $vmResource.identity) {

        if (
            -not [string]::IsNullOrWhiteSpace(
                [string]$vmResource.identity.type
            )
        ) {

            $identityType = [string]$vmResource.identity.type
        }

        $principalId = $vmResource.identity.principalId
        $tenantId = $vmResource.identity.tenantId

        if ($null -ne $vmResource.identity.userAssignedIdentities) {

            $userAssignedIdentities =
                $vmResource.identity.userAssignedIdentities
        }
    }

    return [PSCustomObject]@{

        IdentityType            = $identityType
        PrincipalId             = $principalId
        TenantId                = $tenantId
        UserAssignedIdentities  = $userAssignedIdentities
        VMResource              = $vmResource
    }
}

# ============================================================================
# CREATE IDENTITY PATCH PAYLOAD
#
# This is the critical part.
#
# We never send osProfile, storageProfile, networkProfile, etc.
# ============================================================================

function New-IdentityPatchPayload {

    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentIdentityType,

        [Parameter(Mandatory = $false)]
        $UserAssignedIdentities
    )

    # ------------------------------------------------------------------------
    # No identity
    # ------------------------------------------------------------------------

    if (
        [string]::IsNullOrWhiteSpace($CurrentIdentityType) -or
        $CurrentIdentityType -eq "None"
    ) {

        $payload = @{
            identity = @{
                type = "SystemAssigned"
            }
        }

        return (
            $payload | ConvertTo-Json -Depth 20
        )
    }

    # ------------------------------------------------------------------------
    # User Assigned only
    #
    # Preserve all existing UAMI resource IDs.
    # ------------------------------------------------------------------------

    if ($CurrentIdentityType -eq "UserAssigned") {

        if ($null -eq $UserAssignedIdentities) {

            throw `
                "VM reports UserAssigned identity but no userAssignedIdentities were returned."
        }

        $identityMap = @{}

        foreach (
            $property in
            $UserAssignedIdentities.PSObject.Properties
        ) {

            $identityMap[$property.Name] = @{}
        }

        $payload = @{
            identity = @{
                type                  = "SystemAssigned, UserAssigned"
                userAssignedIdentities = $identityMap
            }
        }

        return (
            $payload | ConvertTo-Json -Depth 20
        )
    }

    # ------------------------------------------------------------------------
    # Already contains SystemAssigned
    # ------------------------------------------------------------------------

    if (
        $CurrentIdentityType -eq "SystemAssigned" -or
        $CurrentIdentityType -eq "SystemAssigned, UserAssigned"
    ) {

        return $null
    }

    # ------------------------------------------------------------------------
    # Handle possible formatting variation.
    # ------------------------------------------------------------------------

    if (
        $CurrentIdentityType.Replace(" ", "").ToLower() `
            -eq "systemassigned,userassigned"
    ) {

        return $null
    }

    throw `
        "Unsupported VM identity type: '$CurrentIdentityType'"
}

# ============================================================================
# PATCH VM IDENTITY
# ============================================================================

function Set-VMSystemAssignedIdentity {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    try {

        # --------------------------------------------------------------------
        # Get current identity
        # --------------------------------------------------------------------

        $identityInfo = Get-VMIdentityInfo `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName

        $currentType =
            $identityInfo.IdentityType

        Write-Verbose `
            "  Current identity type: $currentType"

        # --------------------------------------------------------------------
        # Already SystemAssigned
        # --------------------------------------------------------------------

        if (
            $currentType -eq "SystemAssigned" -or
            $currentType -eq "SystemAssigned, UserAssigned" -or
            $currentType.Replace(" ", "").ToLower() `
                -eq "systemassigned,userassigned"
        ) {

            return @{
                Success                = $true
                Changed                = $false
                IdentityType           = $currentType
                PrincipalId            = $identityInfo.PrincipalId
                Message                = "System-assigned identity already enabled"
            }
        }

        # --------------------------------------------------------------------
        # Build minimal PATCH
        # --------------------------------------------------------------------

        $body = New-IdentityPatchPayload `
            -CurrentIdentityType $currentType `
            -UserAssignedIdentities $identityInfo.UserAssignedIdentities

        if ($null -eq $body) {

            return @{
                Success                = $true
                Changed                = $false
                IdentityType           = $currentType
                PrincipalId            = $identityInfo.PrincipalId
                Message                = "System-assigned identity already enabled"
            }
        }

        Write-Verbose "  PATCH payload:"
        Write-Verbose "  $body"

        # --------------------------------------------------------------------
        # PATCH only identity
        # --------------------------------------------------------------------

        $patchParams = @{
            ResourceGroupName    = $ResourceGroupName
            ResourceProviderName = "Microsoft.Compute"
            ResourceType         = "virtualMachines"
            Name                 = $VMName
            ApiVersion           = $ComputeApiVersion
            Method               = "PATCH"
            Payload              = $body
            ErrorAction          = "Stop"
        }

        Write-Verbose `
            "  PATCH VM using Compute API $ComputeApiVersion"

        $patchResponse =
            Invoke-AzRestMethod @patchParams

        if (
            $patchResponse.StatusCode -lt 200 -or
            $patchResponse.StatusCode -ge 300
        ) {

            throw @"
PATCH VM failed.

VM:
    $VMName

Resource Group:
    $ResourceGroupName

HTTP Status:
    $($patchResponse.StatusCode)

Response:
$($patchResponse.Content)
"@
        }

        Write-Verbose `
            "  PATCH returned HTTP $($patchResponse.StatusCode)"

        # --------------------------------------------------------------------
        # Verify identity.
        #
        # Azure identity changes can take several seconds to become visible.
        # --------------------------------------------------------------------

        $verified = $false
        $verifiedIdentity = $null

        for (
            $attempt = 1;
            $attempt -le $VerificationAttempts;
            $attempt++
        ) {

            Write-Verbose `
                "  Verification attempt $attempt/$VerificationAttempts"

            Start-Sleep `
                -Seconds $VerificationDelaySeconds

            try {

                $verifiedIdentity =
                    Get-VMIdentityInfo `
                        -ResourceGroupName $ResourceGroupName `
                        -VMName $VMName

                $verifyType =
                    $verifiedIdentity.IdentityType

                Write-Verbose `
                    "  Verified identity type: $verifyType"

                if (
                    $verifyType -eq "SystemAssigned" -or
                    $verifyType -eq "SystemAssigned, UserAssigned" -or
                    $verifyType.Replace(" ", "").ToLower() `
                        -eq "systemassigned,userassigned"
                ) {

                    $verified = $true
                    break
                }
            }
            catch {

                Write-Verbose `
                    "  Verification attempt failed: $($_.Exception.Message)"
            }
        }

        # --------------------------------------------------------------------
        # Verification failed
        # --------------------------------------------------------------------

        if (-not $verified) {

            throw @"
PATCH completed successfully, but System-assigned identity
could not be verified after $VerificationAttempts attempts.

VM:
    $VMName

Resource Group:
    $ResourceGroupName
"@
        }

        # --------------------------------------------------------------------
        # Success
        # --------------------------------------------------------------------

        return @{
            Success      = $true
            Changed      = $true
            IdentityType = $verifiedIdentity.IdentityType
            PrincipalId  = $verifiedIdentity.PrincipalId
            Message      = "System-assigned identity enabled successfully"
        }
    }
    catch {

        throw $_
    }
}

# ============================================================================
# MAIN
# ============================================================================

try {

    Write-Log "============================================================"
    Write-Log "Enable System-assigned Managed Identity on Azure VMs"
    Write-Log "============================================================"

    # ------------------------------------------------------------------------
    # Validate Azure context
    # ------------------------------------------------------------------------

    $context = Test-AzureContext

    Write-Log "Subscription     : $($context.Subscription.Name)"
    Write-Log "Subscription ID  : $($context.Subscription.Id)"
    Write-Log "Tenant ID        : $($context.Tenant.Id)"
    Write-Log "Compute API      : $ComputeApiVersion"

    # ------------------------------------------------------------------------
    # Discover VMs
    # ------------------------------------------------------------------------

    Write-Log "Discovering VMs..."

    if ($ResourceGroupName) {

        Write-Log `
            "Resource Group filter: $ResourceGroupName"

        $allVMs = @(
            Get-AzVM `
                -ResourceGroupName $ResourceGroupName `
                -ErrorAction Stop
        )
    }
    else {

        $allVMs = @(
            Get-AzVM `
                -ErrorAction Stop
        )
    }

    Write-Log `
        "Total VMs discovered: $($allVMs.Count)"

    # ------------------------------------------------------------------------
    # Apply Resource Group exclusions
    # ------------------------------------------------------------------------

    $vms = @(
        $allVMs | Where-Object {

            $currentVM = $_
            $currentRG = $_.ResourceGroupName

            $excluded = $false

            foreach ($pattern in $ExcludeResourceGroups) {

                if (
                    -not [string]::IsNullOrWhiteSpace($pattern) -and
                    $currentRG -like $pattern
                ) {

                    $excluded = $true

                    Write-Log `
                        "Excluding $($currentVM.Name) - RG '$currentRG' matches '$pattern'" `
                        -Level WARNING

                    break
                }
            }

            -not $excluded
        }
    )

    Write-Log `
        "VMs selected for processing: $($vms.Count)"

    if (-not $IncludeStoppedVMs) {

        Write-Log `
            "Stopped/Deallocated VMs will be skipped." `
            -Level INFO

        Write-Log `
            "Use -IncludeStoppedVMs to process them." `
            -Level INFO
    }
    else {

        Write-Log `
            "IncludeStoppedVMs enabled." `
            -Level WARNING

        Write-Log `
            "Stopped/Deallocated VMs will be processed." `
            -Level WARNING
    }

    Write-Log "============================================================"

    # ------------------------------------------------------------------------
    # Results
    # ------------------------------------------------------------------------

    $results =
        [System.Collections.Generic.List[PSCustomObject]]::new()

    $counters = @{
        Total               = 0
        AlreadyEnabled      = 0
        SuccessfullyEnabled = 0
        Skipped             = 0
        Failed              = 0
        WhatIf              = 0
    }

    # ------------------------------------------------------------------------
    # Process each VM
    # ------------------------------------------------------------------------

    $i = 0

    foreach ($vm in $vms) {

        $i++

        $counters.Total++

        $vmName = $vm.Name
        $vmRG   = $vm.ResourceGroupName

        $percentComplete = 0

        if ($vms.Count -gt 0) {

            $percentComplete =
                [math]::Round(
                    ($i / $vms.Count) * 100,
                    0
                )
        }

        Write-Progress `
            -Activity "Enabling System-assigned Managed Identity" `
            -Status "$vmName ($i/$($vms.Count))" `
            -PercentComplete $percentComplete

        Write-Log `
            "[$i/$($vms.Count)] $vmName ($vmRG)"

        # --------------------------------------------------------------------
        # Result object
        # --------------------------------------------------------------------

        $result = [PSCustomObject]@{

            VMName               = $vmName
            ResourceGroup        = $vmRG
            PowerState           = $null
            CurrentIdentityType  = $null
            TargetIdentityType   = $null
            Status               = $null
            Message              = $null
            PrincipalId          = $null
            Timestamp            = (
                Get-Date
            ).ToString("yyyy-MM-dd HH:mm:ss")
        }

        # --------------------------------------------------------------------
        # Live power state
        # --------------------------------------------------------------------

        $powerState =
            Get-VMPowerState `
                -ResourceGroupName $vmRG `
                -Name $vmName

        $result.PowerState = $powerState

        if (
            -not $IncludeStoppedVMs -and
            $SkipPowerStates -contains $powerState.ToLower()
        ) {

            Write-Log `
                "  Skipped - power state: $powerState" `
                -Level WARNING

            $result.Status =
                "Skipped"

            $result.Message =
                "VM power state is '$powerState'; skipped by default"

            $counters.Skipped++

            $results.Add($result)

            continue
        }

        # --------------------------------------------------------------------
        # Get current identity
        # --------------------------------------------------------------------

        try {

            $identityInfo =
                Get-VMIdentityInfo `
                    -ResourceGroupName $vmRG `
                    -VMName $vmName

            $currentIdentityType =
                $identityInfo.IdentityType

            $result.CurrentIdentityType =
                $currentIdentityType

            Write-Log `
                "  Current identity: $currentIdentityType"

            # ----------------------------------------------------------------
            # Already SystemAssigned
            # ----------------------------------------------------------------

            if (
                $currentIdentityType -eq "SystemAssigned" -or
                $currentIdentityType -eq "SystemAssigned, UserAssigned" -or
                $currentIdentityType.Replace(" ", "").ToLower() `
                    -eq "systemassigned,userassigned"
            ) {

                Write-Log `
                    "  System-assigned identity already enabled" `
                    -Level SUCCESS

                $result.TargetIdentityType =
                    $currentIdentityType

                $result.Status =
                    "AlreadyEnabled"

                $result.Message =
                    "System-assigned identity already present"

                $result.PrincipalId =
                    $identityInfo.PrincipalId

                $counters.AlreadyEnabled++

                $results.Add($result)

                continue
            }

            # ----------------------------------------------------------------
            # Determine target type
            # ----------------------------------------------------------------

            if ($currentIdentityType -eq "UserAssigned") {

                $result.TargetIdentityType =
                    "SystemAssigned, UserAssigned"

                Write-Log `
                    "  Existing User Assigned identity detected" `
                    -Level INFO

                Write-Log `
                    "  Existing UAMI will be preserved" `
                    -Level INFO
            }
            else {

                $result.TargetIdentityType =
                    "SystemAssigned"
            }
        }
        catch {

            Write-Log `
                "  Failed to retrieve VM identity: $($_.Exception.Message)" `
                -Level ERROR

            $result.Status =
                "Failed"

            $result.Message =
                "Unable to retrieve VM identity: $($_.Exception.Message)"

            $counters.Failed++

            $results.Add($result)

            continue
        }

        # --------------------------------------------------------------------
        # WhatIf
        # --------------------------------------------------------------------

        if (
            $WhatIfPreference
        ) {

            Write-Log `
                "  [WhatIf] Would set identity to '$($result.TargetIdentityType)'" `
                -Level INFO

            $result.Status =
                "WhatIf"

            $result.Message =
                "Would enable System-assigned identity"

            $counters.WhatIf++

            $results.Add($result)

            continue
        }

        # --------------------------------------------------------------------
        # ShouldProcess
        # --------------------------------------------------------------------

        $actionDescription =
            "Set VM identity to '$($result.TargetIdentityType)' using ARM PATCH"

        if (
            $PSCmdlet.ShouldProcess(
                "$vmRG/$vmName",
                $actionDescription
            )
        ) {

            try {

                $identityResult =
                    Set-VMSystemAssignedIdentity `
                        -ResourceGroupName $vmRG `
                        -VMName $vmName

                if ($identityResult.Success) {

                    if ($identityResult.Changed) {

                        Write-Log `
                            "  System-assigned identity enabled successfully" `
                            -Level SUCCESS

                        Write-Log `
                            "  Identity type: $($identityResult.IdentityType)" `
                            -Level SUCCESS

                        Write-Log `
                            "  Principal ID: $($identityResult.PrincipalId)" `
                            -Level SUCCESS

                        $result.Status =
                            "Success"

                        $result.Message =
                            $identityResult.Message

                        $result.PrincipalId =
                            $identityResult.PrincipalId

                        $counters.SuccessfullyEnabled++
                    }
                    else {

                        Write-Log `
                            "  Identity already enabled" `
                            -Level SUCCESS

                        $result.Status =
                            "AlreadyEnabled"

                        $result.Message =
                            $identityResult.Message

                        $result.PrincipalId =
                            $identityResult.PrincipalId

                        $counters.AlreadyEnabled++
                    }
                }
                else {

                    throw `
                        "Identity update returned unsuccessful result."
                }
            }
            catch {

                Write-Log `
                    "  Failed: $($_.Exception.Message)" `
                    -Level ERROR

                $result.Status =
                    "Failed"

                $result.Message =
                    $_.Exception.Message

                $counters.Failed++
            }
        }

        $results.Add($result)
    }

    # ------------------------------------------------------------------------
    # Complete progress
    # ------------------------------------------------------------------------

    Write-Progress `
        -Activity "Enabling System-assigned Managed Identity" `
        -Completed

    # =========================================================================
    # FINAL SUMMARY
    # =========================================================================

    Write-Log "============================================================"
    Write-Log "FINAL SUMMARY"
    Write-Log "============================================================"

    Write-Log `
        "Total VMs processed          : $($counters.Total)"

    Write-Log `
        "Already enabled              : $($counters.AlreadyEnabled)" `
        -Level SUCCESS

    Write-Log `
        "Successfully enabled         : $($counters.SuccessfullyEnabled)" `
        -Level SUCCESS

    Write-Log `
        "WhatIf                       : $($counters.WhatIf)" `
        -Level INFO

    Write-Log `
        "Skipped (stopped/deallocated): $($counters.Skipped)" `
        -Level WARNING

    if ($counters.Failed -gt 0) {

        Write-Log `
            "Failed                       : $($counters.Failed)" `
            -Level ERROR
    }
    else {

        Write-Log `
            "Failed                       : $($counters.Failed)" `
            -Level INFO
    }

    Write-Log "============================================================"

    # =========================================================================
    # EXPORT CSV
    # =========================================================================

    if ($ExportCsv) {

        try {

            $parentPath =
                Split-Path `
                    -Parent `
                    $ExportCsv

            if (
                $parentPath -and
                -not (Test-Path $parentPath)
            ) {

                New-Item `
                    -Path $parentPath `
                    -ItemType Directory `
                    -Force |
                    Out-Null
            }

            $results |
                Export-Csv `
                    -Path $ExportCsv `
                    -NoTypeInformation `
                    -Encoding UTF8

            Write-Log `
                "Detailed results exported to: $ExportCsv" `
                -Level SUCCESS
        }
        catch {

            Write-Log `
                "CSV export failed: $($_.Exception.Message)" `
                -Level ERROR
        }
    }

    # =========================================================================
    # RESULT TABLE
    # =========================================================================

    Write-Log "============================================================"
    Write-Log "RESULT DETAILS"
    Write-Log "============================================================"

    $results |
        Select-Object `
            VMName,
            ResourceGroup,
            PowerState,
            CurrentIdentityType,
            TargetIdentityType,
            Status,
            PrincipalId |
        Format-Table -AutoSize

    return $results
}
catch {

    Write-Log `
        "FATAL ERROR: $($_.Exception.Message)" `
        -Level ERROR

    throw
}