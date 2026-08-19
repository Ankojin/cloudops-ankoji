<#
.SYNOPSIS
    Enable Azure Monitor Agent (AMA), Dependency Agent, Classic VM Insights
    Log-based metrics, existing performance-counter metrics and
    OpenTelemetry metrics on Azure VMs.

.DESCRIPTION
    This script performs the following:

      1. Validates the Azure subscription/context.
      2. Reads the existing shared DCR from Azure Resource Manager.
      3. Validates the existing OpenTelemetry configuration.
      4. Validates the existing Microsoft-Perf configuration.
      5. Adds the Classic VM Insights configuration to the EXISTING DCR
         when it is missing.

         Classic configuration added:

             Performance counter:
                 \VmInsights\DetailedMetrics
                 Sampling: 60 seconds
                 Stream: Microsoft-InsightsMetrics

             Data flow:
                 Microsoft-InsightsMetrics
                     ->
                 VMInsightsPerf-Logs-Dest
                     ->
                 bab-sit-all-wrkspc-swec-01

      6. Does NOT create a new DCR.
      7. Does NOT remove existing Microsoft-Perf configuration.
      8. Does NOT remove existing OpenTelemetry configuration.
      9. Installs AMA if missing (Windows and Linux).
     10. Installs Dependency Agent if missing (Windows and Linux).
         Dependency Agent is SKIPPED for RHEL 9 and above (unsupported).
     11. Enables System Assigned Managed Identity if required.
     12. Skips stopped VMs.
     13. Skips deallocated VMs.
     14. Skips VMs whose state isn't confirmed as Running.
     15. Skips ARO-INFRA-* resource groups.
     16. Creates the VM -> shared DCR association when missing.
     17. Corrects the VM association if it points to another DCR.
     18. Verifies the final DCR configuration.
     19. Exports detailed results to CSV.

    IMPORTANT:
      The shared DCR is modified only when the Classic configuration is
      missing. Existing DCR configuration is preserved.

.PARAMETER DcrResourceId
    Full resource ID of the shared Data Collection Rule.

.PARAMETER ResourceGroupName
    Optional. Process only VMs in this resource group.

.PARAMETER ExcludeResourceGroups
    Resource group wildcard patterns to skip.

.PARAMETER ExportCsv
    Optional CSV output path.

.PARAMETER AmaWaitSeconds
    Maximum time to wait for AMA and Dependency Agent provisioning.

.EXAMPLE
    Preview only:

    .\Enable-log-OTel-Metrics.ps1 `
        -ResourceGroupName "BAB-SIT-DEX-UPG-SWEC-RG-01" `
        -WhatIf

.EXAMPLE
    Actual execution:

    .\Enable-log-OTel-Metrics.ps1 `
        -ResourceGroupName "BAB-SIT-DEX-UPG-SWEC-RG-01"

.EXAMPLE
    Actual execution with CSV:

    .\Enable-log-OTel-Metrics.ps1 `
        -ResourceGroupName "BAB-SIT-DEX-UPG-SWEC-RG-01" `
        -ExportCsv "C:\Temp\BAB-SIT-DEX-UPG-SWEC-RG-01-Monitoring.csv"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DcrResourceId = "/subscriptions/e48414cd-f96d-4414-ae9e-da7fec844f77/resourcegroups/bab-sit-wrkspace-swec-rg-01/providers/microsoft.insights/datacollectionrules/msvmi-bab-sit-vm-monitoring-dcr",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeResourceGroups = @("ARO-INFRA-*"),

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$AmaWaitSeconds = 300
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================

$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"

$DcrApiVersion = "2024-03-11"
$AssociationApiVersion = "2024-03-11"

$AssociationName = "VirtualMachineInsightsMetricsExtension"

$ExpectedWorkspaceResourceId =
    "/subscriptions/e48414cd-f96d-4414-ae9e-da7fec844f77/resourceGroups/bab-sit-wrkspace-swec-rg-01/providers/Microsoft.OperationalInsights/workspaces/bab-sit-all-wrkspc-swec-01"

$ExpectedPerfDestinationName = "VMInsightsPerf-Logs-Dest"
$ExpectedOtelDestinationName = "AMW-Destination"

$ExpectedPerfStream = "Microsoft-Perf"
$ExpectedClassicStream = "Microsoft-InsightsMetrics"
$ExpectedOtelStream = "Microsoft-OtelPerfMetrics"

$ClassicDataSourceName = "VMInsightsPerfCounters"
$ClassicSamplingFrequency = 60
$ClassicCounterSpecifier = "\VmInsights\DetailedMetrics"

$AmaPublisher = "Microsoft.Azure.Monitor"

$WindowsAmaExtension = "AzureMonitorWindowsAgent"
$LinuxAmaExtension = "AzureMonitorLinuxAgent"

$AmaHandlerVersion = "1.0"

# Dependency Agent (required for VM Insights Map / process & connection data)
$DependencyAgentPublisher = "Microsoft.Azure.Monitoring.DependencyAgent"
$WindowsDependencyAgentExtension = "DependencyAgentWindows"
$LinuxDependencyAgentExtension = "DependencyAgentLinux"
$DependencyAgentHandlerVersion = "9.10"
$DependencyAgentSettings = @{ enableAMA = "true" }

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message = "",

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    if ([string]::IsNullOrEmpty($Message)) {
        Write-Host ""
        return
    }

    $color = @{
        INFO    = "Cyan"
        SUCCESS = "Green"
        WARNING = "Yellow"
        ERROR   = "Red"
    }[$Level]

    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

# ============================================================================
# VM POWER STATE
# ============================================================================

function Get-VMPowerState {
    param(
        [Parameter(Mandatory = $true)]
        $VM
    )

    $statuses = @()

    if ($null -ne $VM.Statuses) {
        $statuses = @($VM.Statuses)
    }

    $powerStatus = @(
        $statuses |
        Where-Object {
            $_.Code -and $_.Code -like "PowerState/*"
        } |
        Select-Object -First 1
    )

    if ($powerStatus.Count -gt 0) {

        $code = [string]$powerStatus[0].Code

        switch -Regex ($code.ToLowerInvariant()) {

            "^powerstate/running$" {
                return "VM running"
            }

            "^powerstate/stopped$" {
                return "VM stopped"
            }

            "^powerstate/deallocated$" {
                return "VM deallocated"
            }

            "^powerstate/starting$" {
                return "VM starting"
            }

            "^powerstate/stopping$" {
                return "VM stopping"
            }

            "^powerstate/deallocating$" {
                return "VM deallocating"
            }

            default {
                return $code
            }
        }
    }

    # ------------------------------------------------------------------------
    # Fallback query for environments where the original object doesn't
    # expose the PowerState status.
    # ------------------------------------------------------------------------

    try {

        $refreshVm = Get-AzVM `
            -ResourceGroupName $VM.ResourceGroupName `
            -Name $VM.Name `
            -Status `
            -ErrorAction Stop

        $refreshPowerStatus = @(
            $refreshVm.Statuses |
            Where-Object {
                $_.Code -and $_.Code -like "PowerState/*"
            } |
            Select-Object -First 1
        )

        if ($refreshPowerStatus.Count -gt 0) {

            $refreshCode =
                [string]$refreshPowerStatus[0].Code

            switch -Regex ($refreshCode.ToLowerInvariant()) {

                "^powerstate/running$" {
                    return "VM running"
                }

                "^powerstate/stopped$" {
                    return "VM stopped"
                }

                "^powerstate/deallocated$" {
                    return "VM deallocated"
                }

                "^powerstate/starting$" {
                    return "VM starting"
                }

                "^powerstate/stopping$" {
                    return "VM stopping"
                }

                "^powerstate/deallocating$" {
                    return "VM deallocating"
                }

                default {
                    return $refreshCode
                }
            }
        }
    }
    catch {
        # Do not fail the entire script on fallback.
    }

    return "Unknown"
}

# ============================================================================
# RESOURCE GROUP EXCLUSION
# ============================================================================

function Test-ExcludedResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )

    foreach ($pattern in $ExcludeResourceGroups) {

        if ($ResourceGroup -like $pattern) {
            return $true
        }
    }

    return $false
}

# ============================================================================
# AMA EXTENSION NAME
# ============================================================================

function Get-AMAExtensionName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OSType
    )

    switch ($OSType) {

        "Windows" {
            return $WindowsAmaExtension
        }

        "Linux" {
            return $LinuxAmaExtension
        }

        default {
            throw "Unsupported operating system type '$OSType'."
        }
    }
}

# ============================================================================
# DEPENDENCY AGENT EXTENSION NAME
# ============================================================================

function Get-DependencyAgentExtensionName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OSType
    )

    switch ($OSType) {

        "Windows" {
            return $WindowsDependencyAgentExtension
        }

        "Linux" {
            return $LinuxDependencyAgentExtension
        }

        default {
            throw "Unsupported operating system type '$OSType'."
        }
    }
}

# ============================================================================
# DETECT RHEL 9+ (Dependency Agent is not supported)
# ============================================================================

function Test-SkipDependencyAgent {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [string]$OSType
    )

    if ($OSType -ne "Linux") {
        return $false
    }

    # Prefer image reference from the VM object (Offer / Sku / Publisher)
    $imageRef = $null
    if ($VM.StorageProfile -and $VM.StorageProfile.ImageReference) {
        $imageRef = $VM.StorageProfile.ImageReference
    }

    if ($imageRef) {
        $offer  = [string]$imageRef.Offer
        $sku    = [string]$imageRef.Sku
        $publisher = [string]$imageRef.Publisher

        # Common RHEL image patterns: Offer "RHEL", Sku like "9_x", "9-lvm", "91-gen2", etc.
        if (
            ($publisher -match '(?i)RedHat|Red.?Hat') -or
            ($offer -match '(?i)^RHEL') -or
            ($offer -match '(?i)rhel')
        ) {
            # Extract major version from Sku or Offer (e.g. 9_2, 9-lvm-gen2, 90-gen2, rhel-9)
            $versionString = "$sku $offer"
            if ($versionString -match '(?i)(?:^|[-_])(9|1[0-9])(?:[-_.]|$)') {
                return $true
            }
        }
    }

    # Fallback: try to read OS name/version from instance view if available
    try {
        if ($VM.OSProfile -and $VM.OSProfile.ComputerName) {
            # No reliable version here; leave as non-skip
        }
    }
    catch {
        # Ignore
    }

    return $false
}

# ============================================================================
# ARM REST HELPER
# ============================================================================

function Invoke-ArmRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourcePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "PUT", "PATCH", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion,

        [Parameter(Mandatory = $false)]
        [string]$Payload
    )

    $restPath =
        $ResourcePath + "?api-version=" + $ApiVersion

    if ([string]::IsNullOrWhiteSpace($Payload)) {

        return Invoke-AzRestMethod `
            -Path $restPath `
            -Method $Method `
            -ErrorAction Stop
    }

    return Invoke-AzRestMethod `
        -Path $restPath `
        -Method $Method `
        -Payload $Payload `
        -ErrorAction Stop
}

# ============================================================================
# ARM RESPONSE PARSER
# ============================================================================

function Convert-ArmResponseContent {
    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    if ($null -eq $Response) {
        throw "Azure Resource Manager returned no response."
    }

    if (
        $null -eq $Response.Content -or
        [string]::IsNullOrWhiteSpace([string]$Response.Content)
    ) {
        return $null
    }

    if ($Response.Content -is [string]) {

        return $Response.Content |
            ConvertFrom-Json `
                -ErrorAction Stop
    }

    return $Response.Content
}

# ============================================================================
# GET SHARED DCR
# ============================================================================

function Get-SharedDcr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DcrResourceId
    )

    $response =
        Invoke-ArmRest `
            -ResourcePath $DcrResourceId `
            -Method GET `
            -ApiVersion $DcrApiVersion

    $dcr =
        Convert-ArmResponseContent `
            -Response $response

    if ($null -eq $dcr) {
        throw "The shared DCR returned an empty response."
    }

    return $dcr
}

# ============================================================================
# TEST CLASSIC CONFIGURATION
# ============================================================================

function Test-ClassicDcrConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        $Dcr
    )

    $properties = $null

    if ($Dcr.properties) {
        $properties = $Dcr.properties
    }
    elseif (
        $Dcr.dataFlows -or
        $Dcr.dataSources -or
        $Dcr.destinations
    ) {
        $properties = $Dcr
    }
    else {
        throw "DCR response does not contain expected properties/dataSources/dataFlows/destinations."
    }

    $result = [PSCustomObject]@{
        PerformanceCounterFound = $false
        ClassicDataSourceFound  = $false
        ClassicStreamFound      = $false
        ClassicDataFlowFound    = $false
        DestinationFound        = $false
        WorkspaceCorrect        = $false
        FullyConfigured         = $false
    }

    # ------------------------------------------------------------------------
    # Existing performance counter sources
    # ------------------------------------------------------------------------

    $performanceCounters = @()

    if (
        $properties.dataSources -and
        $properties.dataSources.performanceCounters
    ) {

        $performanceCounters = @(
            $properties.dataSources.performanceCounters
        )
    }

    foreach ($pc in $performanceCounters) {

        $streams = @($pc.streams)
        $counters = @($pc.counterSpecifiers)

        if (
            $streams -contains $ExpectedClassicStream
        ) {

            $result.PerformanceCounterFound = $true
        }

        if (
            [string]$pc.name -eq
                $ClassicDataSourceName
        ) {

            $result.ClassicDataSourceFound = $true
        }

        if (
            ($streams -contains $ExpectedClassicStream) -and
            ($counters -contains $ClassicCounterSpecifier)
        ) {

            $result.ClassicStreamFound = $true
        }
    }

    # ------------------------------------------------------------------------
    # Classic data flow
    # ------------------------------------------------------------------------

    $dataFlows = @()

    if ($properties.dataFlows) {
        $dataFlows = @($properties.dataFlows)
    }

    foreach ($flow in $dataFlows) {

        $streams = @($flow.streams)
        $destinations = @($flow.destinations)

        if (
            ($streams -contains $ExpectedClassicStream) -and
            ($destinations -contains $ExpectedPerfDestinationName)
        ) {

            $result.ClassicDataFlowFound = $true
        }
    }

    # ------------------------------------------------------------------------
    # Destination
    # ------------------------------------------------------------------------

    $logAnalyticsDestinations = @()

    if (
        $properties.destinations -and
        $properties.destinations.logAnalytics
    ) {

        $logAnalyticsDestinations = @(
            $properties.destinations.logAnalytics
        )
    }

    foreach ($destination in $logAnalyticsDestinations) {

        if (
            [string]$destination.name -eq
                $ExpectedPerfDestinationName
        ) {

            $result.DestinationFound = $true

            if (
                [string]$destination.workspaceResourceId -eq
                $ExpectedWorkspaceResourceId
            ) {

                $result.WorkspaceCorrect = $true
            }
        }
    }

    $result.FullyConfigured =
        $result.ClassicDataSourceFound -and
        $result.ClassicStreamFound -and
        $result.ClassicDataFlowFound -and
        $result.DestinationFound -and
        $result.WorkspaceCorrect

    return $result
}

# ============================================================================
# TEST COMPLETE DCR CONFIGURATION
# ============================================================================

function Test-DCRConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        $Dcr
    )

    $properties = $null

    if ($Dcr.properties) {
        $properties = $Dcr.properties
    }
    else {
        $properties = $Dcr
    }

    Write-Log "Validating existing DCR..." 

    # ------------------------------------------------------------------------
    # Performance counters / Microsoft-Perf
    # ------------------------------------------------------------------------

    $performanceCounters = @()

    if (
        $properties.dataSources -and
        $properties.dataSources.performanceCounters
    ) {

        $performanceCounters = @(
            $properties.dataSources.performanceCounters
        )
    }

    if ($performanceCounters.Count -gt 0) {

        Write-Log `
            "  Performance counter data sources found: $($performanceCounters.Count)" `
            -Level SUCCESS

        foreach ($pc in $performanceCounters) {

            Write-Log `
                "    $($pc.name) / $($pc.samplingFrequencyInSeconds)s / $(@($pc.streams) -join ', ')"
        }
    }
    else {

        Write-Log `
            "  No performance-counter data source found" `
            -Level ERROR
    }

    # ------------------------------------------------------------------------
    # Data flows
    # ------------------------------------------------------------------------

    $dataFlows = @()

    if ($properties.dataFlows) {
        $dataFlows = @($properties.dataFlows)
    }

    $perfFlowFound = $false
    $classicFlowFound = $false
    $otelFlowFound = $false

    foreach ($flow in $dataFlows) {

        $streams = @($flow.streams)
        $destinations = @($flow.destinations)

        if (
            ($streams -contains $ExpectedPerfStream) -and
            ($destinations -contains $ExpectedPerfDestinationName)
        ) {

            $perfFlowFound = $true

            Write-Log `
                "  Microsoft-Perf -> $ExpectedPerfDestinationName found" `
                -Level SUCCESS
        }

        if (
            ($streams -contains $ExpectedClassicStream) -and
            ($destinations -contains $ExpectedPerfDestinationName)
        ) {

            $classicFlowFound = $true

            Write-Log `
                "  Microsoft-InsightsMetrics -> $ExpectedPerfDestinationName found" `
                -Level SUCCESS
        }

        if (
            ($streams -contains $ExpectedOtelStream) -and
            ($destinations -contains $ExpectedOtelDestinationName)
        ) {

            $otelFlowFound = $true

            Write-Log `
                "  Microsoft-OtelPerfMetrics -> $ExpectedOtelDestinationName found" `
                -Level SUCCESS
        }
    }

    if (-not $perfFlowFound) {

        Write-Log `
            "  Microsoft-Perf data flow not found" `
            -Level WARNING
    }

    if (-not $classicFlowFound) {

        Write-Log `
            "  Microsoft-InsightsMetrics data flow not found" `
            -Level WARNING
    }

    if (-not $otelFlowFound) {

        Write-Log `
            "  Microsoft-OtelPerfMetrics data flow not found" `
            -Level ERROR
    }

    # ------------------------------------------------------------------------
    # Log Analytics destination
    # ------------------------------------------------------------------------

    $logAnalyticsDestinations = @()

    if (
        $properties.destinations -and
        $properties.destinations.logAnalytics
    ) {

        $logAnalyticsDestinations = @(
            $properties.destinations.logAnalytics
        )
    }

    $destinationFound = $false
    $workspaceCorrect = $false

    foreach ($destination in $logAnalyticsDestinations) {

        if (
            [string]$destination.name -eq
                $ExpectedPerfDestinationName
        ) {

            $destinationFound = $true

            Write-Log `
                "  $ExpectedPerfDestinationName destination found" `
                -Level SUCCESS

            Write-Log `
                "    WorkspaceResourceId: $($destination.workspaceResourceId)"

            if (
                [string]$destination.workspaceResourceId -eq
                $ExpectedWorkspaceResourceId
            ) {

                $workspaceCorrect = $true

                Write-Log `
                    "  Log Analytics workspace is correct" `
                    -Level SUCCESS
            }
            else {

                Write-Log `
                    "  Log Analytics workspace mismatch" `
                    -Level ERROR
            }
        }
    }

    if (-not $destinationFound) {

        Write-Log `
            "$ExpectedPerfDestinationName destination missing" `
            -Level ERROR
    }

    # ------------------------------------------------------------------------
    # AMW destination
    # ------------------------------------------------------------------------

    $monitoringAccounts = @()

    if (
        $properties.destinations -and
        $properties.destinations.monitoringAccounts
    ) {

        $monitoringAccounts = @(
            $properties.destinations.monitoringAccounts
        )
    }

    $amwDestinationFound = $false

    foreach ($destination in $monitoringAccounts) {

        if (
            [string]$destination.name -eq
                $ExpectedOtelDestinationName
        ) {

            $amwDestinationFound = $true

            Write-Log `
                "  $ExpectedOtelDestinationName destination found" `
                -Level SUCCESS

            if ($destination.accountResourceId) {

                Write-Log `
                    "    AccountResourceId: $($destination.accountResourceId)"
            }
        }
    }

    if (-not $amwDestinationFound) {

        Write-Log `
            "$ExpectedOtelDestinationName destination missing" `
            -Level ERROR
    }

    # ------------------------------------------------------------------------
    # Classic source validation
    # ------------------------------------------------------------------------

    $classic =
        Test-ClassicDcrConfiguration `
            -Dcr $Dcr

    if ($classic.FullyConfigured) {

        Write-Log `
            "  Classic VM Insights Log-based metrics configuration is present" `
            -Level SUCCESS
    }
    else {

        Write-Log `
            "  Classic VM Insights Log-based metrics configuration is incomplete" `
            -Level WARNING
    }

    # ------------------------------------------------------------------------
    # Result
    # ------------------------------------------------------------------------

    return [PSCustomObject]@{
        PerfFlowFound        = $perfFlowFound
        ClassicFlowFound     = $classic.ClassicDataFlowFound
        ClassicConfigured    = $classic.FullyConfigured
        OTelFlowFound        = $otelFlowFound
        DestinationFound     = $destinationFound
        WorkspaceCorrect     = $workspaceCorrect
        AMWDestinationFound  = $amwDestinationFound
    }
}

# ============================================================================
# ADD CLASSIC CONFIGURATION TO EXISTING DCR
# ============================================================================

function Add-ClassicConfigurationToDcr {
    param(
        [Parameter(Mandatory = $true)]
        $Dcr
    )

    if (-not $Dcr.properties) {
        throw "Cannot modify DCR because the ARM response doesn't contain properties."
    }

    $properties =
        $Dcr.properties

    # ------------------------------------------------------------------------
    # Ensure dataSources object
    # ------------------------------------------------------------------------

    if (-not $properties.dataSources) {

        $properties |
            Add-Member `
                -MemberType NoteProperty `
                -Name "dataSources" `
                -Value ([PSCustomObject]@{}) `
                -Force
    }

    # ------------------------------------------------------------------------
    # Existing performance counters
    # ------------------------------------------------------------------------

    $performanceCounters = @()

    if ($properties.dataSources.performanceCounters) {

        $performanceCounters = @(
            $properties.dataSources.performanceCounters
        )
    }

    # ------------------------------------------------------------------------
    # Check for existing Classic source
    # ------------------------------------------------------------------------

    $classicSource = @(
        $performanceCounters |
        Where-Object {

            (
                @($_.streams) -contains
                    $ExpectedClassicStream
            ) -and
            (
                @($_.counterSpecifiers) -contains
                    $ClassicCounterSpecifier
            )
        } |
        Select-Object -First 1
    )

    if ($classicSource.Count -eq 0) {

        Write-Log `
            "Adding Classic VM Insights performance-counter data source..."

        $newClassicSource = [PSCustomObject]@{
            counterSpecifiers = @(
                $ClassicCounterSpecifier
            )

            name =
                $ClassicDataSourceName

            samplingFrequencyInSeconds =
                $ClassicSamplingFrequency

            streams = @(
                $ExpectedClassicStream
            )
        }

        $performanceCounters +=
            $newClassicSource

        $properties.dataSources.performanceCounters =
            $performanceCounters

        Write-Log `
            "Classic performance-counter data source prepared" `
            -Level SUCCESS
    }
    else {

        Write-Log `
            "Classic VM Insights performance-counter data source already exists" `
            -Level SUCCESS
    }

    # ------------------------------------------------------------------------
    # Ensure dataFlows
    # ------------------------------------------------------------------------

    $dataFlows = @()

    if ($properties.dataFlows) {

        $dataFlows =
            @($properties.dataFlows)
    }

    # ------------------------------------------------------------------------
    # Check Classic data flow
    # ------------------------------------------------------------------------

    $classicFlow = @(
        $dataFlows |
        Where-Object {

            (
                @($_.streams) -contains
                    $ExpectedClassicStream
            ) -and
            (
                @($_.destinations) -contains
                    $ExpectedPerfDestinationName
            )
        } |
        Select-Object -First 1
    )

    if ($classicFlow.Count -eq 0) {

        Write-Log `
            "Adding Microsoft-InsightsMetrics data flow..."

        $newClassicFlow = [PSCustomObject]@{
            destinations = @(
                $ExpectedPerfDestinationName
            )

            streams = @(
                $ExpectedClassicStream
            )
        }

        $dataFlows +=
            $newClassicFlow

        $properties.dataFlows =
            $dataFlows

        Write-Log `
            "Classic Microsoft-InsightsMetrics data flow prepared" `
            -Level SUCCESS
    }
    else {

        Write-Log `
            "Classic Microsoft-InsightsMetrics data flow already exists" `
            -Level SUCCESS
    }

    # ------------------------------------------------------------------------
    # Ensure Log Analytics destination exists and points to expected LAW.
    #
    # We DO NOT create a duplicate destination.
    # ------------------------------------------------------------------------

    $logAnalyticsDestinations = @()

    if (
        $properties.destinations -and
        $properties.destinations.logAnalytics
    ) {

        $logAnalyticsDestinations =
            @($properties.destinations.logAnalytics)
    }

    $targetDestination = @(
        $logAnalyticsDestinations |
        Where-Object {
            $_.name -eq $ExpectedPerfDestinationName
        } |
        Select-Object -First 1
    )

    if ($targetDestination.Count -eq 0) {

        throw @"
The existing DCR does not contain the required Log Analytics destination '$ExpectedPerfDestinationName'.

The script will NOT create a new destination automatically because the destination configuration should be explicitly controlled.
"@
    }

    if (
        [string]$targetDestination[0].workspaceResourceId -ne
        $ExpectedWorkspaceResourceId
    ) {

        throw @"
The existing destination '$ExpectedPerfDestinationName' does not point to the expected Log Analytics workspace.

Expected:
$ExpectedWorkspaceResourceId

Actual:
$($targetDestination[0].workspaceResourceId)

The script will NOT change the destination automatically.
"@
    }

    return $Dcr
}

# ============================================================================
# UPDATE EXISTING DCR
#
# This sends the full current DCR resource back to Azure after merging only
# the missing Classic configuration.
# ============================================================================

function Update-SharedDcr {
    param(
        [Parameter(Mandatory = $true)]
        $Dcr
    )

    if (-not $Dcr.properties) {
        throw "Cannot update DCR because properties are missing."
    }

    # ------------------------------------------------------------------------
    # Build a clean PUT body.
    #
    # Read-only properties such as id, type, etag, systemData,
    # provisioningState and immutableId are intentionally not included.
    # ------------------------------------------------------------------------

    $body = [ordered]@{}

    if ($Dcr.location) {
        $body.location = $Dcr.location
    }

    if ($Dcr.kind) {
        $body.kind = $Dcr.kind
    }

    if ($Dcr.identity) {
        $body.identity = $Dcr.identity
    }

    if ($Dcr.tags) {
        $body.tags = $Dcr.tags
    }

    if ($Dcr.sku) {
        $body.sku = $Dcr.sku
    }

    # ------------------------------------------------------------------------
    # Copy all current DCR properties.
    # ------------------------------------------------------------------------

    $body.properties =
        $Dcr.properties

    $payload =
        $body |
        ConvertTo-Json -Depth 100

    Write-Log `
        "Updating existing shared DCR..." `
        -Level WARNING

    $response =
        Invoke-ArmRest `
            -ResourcePath $DcrResourceId `
            -Method PUT `
            -ApiVersion $DcrApiVersion `
            -Payload $payload

    $updated =
        Convert-ArmResponseContent `
            -Response $response

    if (-not $updated) {

        throw `
            "Azure returned an empty response after updating the DCR."
    }

    Write-Log `
        "Shared DCR update completed" `
        -Level SUCCESS

    return $updated
}

# ============================================================================
# GET VM DCR ASSOCIATIONS
# ============================================================================

function Get-VMDataCollectionRuleAssociations {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmResourceId
    )

    $associationPath =
        $VmResourceId +
        "/providers/Microsoft.Insights/dataCollectionRuleAssociations"

    $response =
        Invoke-ArmRest `
            -ResourcePath $associationPath `
            -Method GET `
            -ApiVersion $AssociationApiVersion

    $body =
        Convert-ArmResponseContent `
            -Response $response

    if ($null -eq $body) {
        return @()
    }

    if ($body.value) {
        return @($body.value)
    }

    return @()
}

# ============================================================================
# CREATE DCR ASSOCIATION
# ============================================================================

function New-VMDataCollectionRuleAssociationRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$AssociationName,

        [Parameter(Mandatory = $true)]
        [string]$DcrResourceId
    )

    $associationPath =
        $VmResourceId +
        "/providers/Microsoft.Insights/dataCollectionRuleAssociations/" +
        $AssociationName

    $payloadObject = @{
        properties = @{
            dataCollectionRuleId = $DcrResourceId

            description =
                "Association of shared VM Insights data collection rule."
        }
    }

    $payload =
        $payloadObject |
        ConvertTo-Json -Depth 20

    return Invoke-ArmRest `
        -ResourcePath $associationPath `
        -Method PUT `
        -ApiVersion $AssociationApiVersion `
        -Payload $payload
}

# ============================================================================
# DELETE DCR ASSOCIATION
# ============================================================================

function Remove-VMDataCollectionRuleAssociationRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$AssociationName
    )

    $associationPath =
        $VmResourceId +
        "/providers/Microsoft.Insights/dataCollectionRuleAssociations/" +
        $AssociationName

    return Invoke-ArmRest `
        -ResourcePath $associationPath `
        -Method DELETE `
        -ApiVersion $AssociationApiVersion
}

# ============================================================================
# INSTALL / UPDATE AMA
# ============================================================================

function Install-OrUpdate-AMA {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [string]$VMResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$OSType
    )

    $amaName =
        Get-AMAExtensionName `
            -OSType $OSType

    Write-Log `
        "  AMA extension: $amaName"

    $existingAma =
        Get-AzVMExtension `
            -ResourceGroupName $VMResourceGroup `
            -VMName $VMName `
            -Name $amaName `
            -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------------
    # Already healthy
    # ------------------------------------------------------------------------

    if (
        $existingAma -and
        $existingAma.ProvisioningState -eq "Succeeded"
    ) {

        Write-Log `
            "  AMA already installed and healthy" `
            -Level SUCCESS

        return [PSCustomObject]@{
            Success          = $true
            Installed        = $false
            AlreadyInstalled = $true
            Message =
                "AMA already installed and provisioning succeeded"
        }
    }

    # ------------------------------------------------------------------------
    # WhatIf
    # ------------------------------------------------------------------------

    if (
        -not $PSCmdlet.ShouldProcess(
            "$VMName ($VMResourceGroup)",
            "Install/update $amaName"
        )
    ) {

        Write-Log `
            "  [WhatIf] Would install/update AMA"

        return [PSCustomObject]@{
            Success          = $true
            Installed        = $false
            AlreadyInstalled = $false
            Message =
                "WhatIf - AMA would be installed/updated"
        }
    }

    try {

        # --------------------------------------------------------------------
        # System Assigned Managed Identity
        # --------------------------------------------------------------------

        $identityType =
            [string]$VM.Identity.Type

        if ([string]::IsNullOrWhiteSpace($identityType)) {

            Write-Log `
                "  System Assigned Managed Identity not present"

            Write-Log `
                "  Enabling System Assigned Managed Identity..."

            Update-AzVM `
                -ResourceGroupName $VMResourceGroup `
                -VMName $VMName `
                -IdentityType SystemAssigned `
                -ErrorAction Stop |
                Out-Null

            Write-Log `
                "  System Assigned Managed Identity enabled" `
                -Level SUCCESS
        }
        else {

            Write-Log `
                "  Managed identity already configured: $identityType"
        }

        # --------------------------------------------------------------------
        # Install AMA
        # --------------------------------------------------------------------

        Write-Log `
            "  Installing/updating AMA..."

        Set-AzVMExtension `
            -ResourceGroupName $VMResourceGroup `
            -VMName $VMName `
            -Name $amaName `
            -Publisher $AmaPublisher `
            -ExtensionType $amaName `
            -TypeHandlerVersion $AmaHandlerVersion `
            -EnableAutomaticUpgrade $true `
            -Location $VM.Location `
            -ErrorAction Stop |
            Out-Null

        Write-Log `
            "  AMA deployment submitted" `
            -Level SUCCESS

        # --------------------------------------------------------------------
        # Wait for AMA
        # --------------------------------------------------------------------

        $elapsed = 0
        $amaSucceeded = $false

        while ($elapsed -lt $AmaWaitSeconds) {

            Start-Sleep -Seconds 10

            $elapsed += 10

            $checkAma =
                Get-AzVMExtension `
                    -ResourceGroupName $VMResourceGroup `
                    -VMName $VMName `
                    -Name $amaName `
                    -ErrorAction SilentlyContinue

            if (
                $checkAma -and
                $checkAma.ProvisioningState -eq "Succeeded"
            ) {

                $amaSucceeded = $true
                break
            }

            $currentState =
                if ($checkAma) {
                    [string]$checkAma.ProvisioningState
                }
                else {
                    "NotFound"
                }

            Write-Log `
                "  AMA state: $currentState - waiting ($elapsed/$AmaWaitSeconds sec)"
        }

        if ($amaSucceeded) {

            Write-Log `
                "  AMA provisioning succeeded" `
                -Level SUCCESS

            return [PSCustomObject]@{
                Success          = $true
                Installed        = $true
                AlreadyInstalled = $false
                Message =
                    "AMA installed successfully"
            }
        }

        Write-Log `
            "  AMA did not reach Succeeded within $AmaWaitSeconds seconds" `
            -Level ERROR

        return [PSCustomObject]@{
            Success          = $false
            Installed        = $false
            AlreadyInstalled = $false
            Message =
                "AMA provisioning timeout"
        }
    }
    catch {

        Write-Log `
            "  AMA installation failed: $($_.Exception.Message)" `
            -Level ERROR

        return [PSCustomObject]@{
            Success          = $false
            Installed        = $false
            AlreadyInstalled = $false
            Message =
                $_.Exception.Message
        }
    }
}

# ============================================================================
# INSTALL / UPDATE DEPENDENCY AGENT
# ============================================================================

function Install-OrUpdate-DependencyAgent {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [string]$VMResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$OSType
    )

    # --------------------------------------------------------------------
    # Skip on RHEL 9 and later (Dependency Agent is not supported)
    # --------------------------------------------------------------------

    if (
        Test-SkipDependencyAgent `
            -VM $VM `
            -OSType $OSType
    ) {

        Write-Log `
            "  Dependency Agent skipped (RHEL 9+ / unsupported)" `
            -Level WARNING

        return [PSCustomObject]@{
            Success          = $true
            Installed        = $false
            AlreadyInstalled = $false
            Skipped          = $true
            Message =
                "Skipped - Dependency Agent not supported on RHEL 9 and above"
        }
    }

    $daName =
        Get-DependencyAgentExtensionName `
            -OSType $OSType

    Write-Log `
        "  Dependency Agent extension: $daName"

    $existingDa =
        Get-AzVMExtension `
            -ResourceGroupName $VMResourceGroup `
            -VMName $VMName `
            -Name $daName `
            -ErrorAction SilentlyContinue

    # --------------------------------------------------------------------
    # Already healthy
    # --------------------------------------------------------------------

    if (
        $existingDa -and
        $existingDa.ProvisioningState -eq "Succeeded"
    ) {

        Write-Log `
            "  Dependency Agent already installed and healthy" `
            -Level SUCCESS

        return [PSCustomObject]@{
            Success          = $true
            Installed        = $false
            AlreadyInstalled = $true
            Skipped          = $false
            Message =
                "Dependency Agent already installed and provisioning succeeded"
        }
    }

    # --------------------------------------------------------------------
    # WhatIf
    # --------------------------------------------------------------------

    if (
        -not $PSCmdlet.ShouldProcess(
            "$VMName ($VMResourceGroup)",
            "Install/update $daName"
        )
    ) {

        Write-Log `
            "  [WhatIf] Would install/update Dependency Agent"

        return [PSCustomObject]@{
            Success          = $true
            Installed        = $false
            AlreadyInstalled = $false
            Skipped          = $false
            Message =
                "WhatIf - Dependency Agent would be installed/updated"
        }
    }

    try {

        Write-Log `
            "  Installing/updating Dependency Agent..."

        Set-AzVMExtension `
            -ResourceGroupName $VMResourceGroup `
            -VMName $VMName `
            -Name $daName `
            -Publisher $DependencyAgentPublisher `
            -ExtensionType $daName `
            -TypeHandlerVersion $DependencyAgentHandlerVersion `
            -Settings $DependencyAgentSettings `
            -EnableAutomaticUpgrade $true `
            -Location $VM.Location `
            -ErrorAction Stop |
            Out-Null

        Write-Log `
            "  Dependency Agent deployment submitted" `
            -Level SUCCESS

        # --------------------------------------------------------------------
        # Wait for Dependency Agent (reuse AmaWaitSeconds)
        # --------------------------------------------------------------------

        $elapsed = 0
        $daSucceeded = $false

        while ($elapsed -lt $AmaWaitSeconds) {

            Start-Sleep -Seconds 10

            $elapsed += 10

            $checkDa =
                Get-AzVMExtension `
                    -ResourceGroupName $VMResourceGroup `
                    -VMName $VMName `
                    -Name $daName `
                    -ErrorAction SilentlyContinue

            if (
                $checkDa -and
                $checkDa.ProvisioningState -eq "Succeeded"
            ) {

                $daSucceeded = $true
                break
            }

            $currentState =
                if ($checkDa) {
                    [string]$checkDa.ProvisioningState
                }
                else {
                    "NotFound"
                }

            Write-Log `
                "  Dependency Agent state: $currentState - waiting ($elapsed/$AmaWaitSeconds sec)"
        }

        if ($daSucceeded) {

            Write-Log `
                "  Dependency Agent provisioning succeeded" `
                -Level SUCCESS

            return [PSCustomObject]@{
                Success          = $true
                Installed        = $true
                AlreadyInstalled = $false
                Skipped          = $false
                Message =
                    "Dependency Agent installed successfully"
            }
        }

        Write-Log `
            "  Dependency Agent did not reach Succeeded within $AmaWaitSeconds seconds" `
            -Level ERROR

        return [PSCustomObject]@{
            Success          = $false
            Installed        = $false
            AlreadyInstalled = $false
            Skipped          = $false
            Message =
                "Dependency Agent provisioning timeout"
        }
    }
    catch {

        Write-Log `
            "  Dependency Agent installation failed: $($_.Exception.Message)" `
            -Level ERROR

        return [PSCustomObject]@{
            Success          = $false
            Installed        = $false
            AlreadyInstalled = $false
            Skipped          = $false
            Message =
                $_.Exception.Message
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

try {

    Write-Log "============================================================"
    Write-Log "Azure VM Monitoring Enablement"
    Write-Log "============================================================"

    Write-Log `
        "Subscription : $SubscriptionId"

    Write-Log `
        "DCR          : $DcrResourceId"

    Write-Log `
        "Workspace    : $ExpectedWorkspaceResourceId"

    Write-Log `
        "Association  : $AssociationName"

    Write-Log `
        "Classic      : Microsoft-InsightsMetrics -> $ExpectedPerfDestinationName"

    if ($ResourceGroupName) {

        Write-Log `
            "Target RG    : $ResourceGroupName"
    }
    else {

        Write-Log `
            "Target RG    : ALL RESOURCE GROUPS"
    }

    Write-Log "============================================================"

    # ========================================================================
    # AZURE CONTEXT
    # ========================================================================

    $context =
        Get-AzContext

    if (-not $context) {

        throw `
            "No Azure PowerShell context found. Run Connect-AzAccount first."
    }

    Write-Log `
        "Azure Account : $($context.Account.Id)"

    Write-Log `
        "Subscription  : $($context.Subscription.Name)"

    Write-Log `
        "SubscriptionId: $($context.Subscription.Id)"

    if (
        $context.Subscription.Id -ne
        $SubscriptionId
    ) {

        throw @"
Current Azure subscription does not match expected subscription.

Expected:
$SubscriptionId

Current:
$($context.Subscription.Id)
"@
    }

    # ========================================================================
    # GET DCR
    # ========================================================================

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "READING SHARED DCR"
    Write-Log "============================================================"

    $dcr =
        Get-SharedDcr `
            -DcrResourceId $DcrResourceId

    Write-Log `
        "DCR found: $($dcr.name)" `
        -Level SUCCESS

    Write-Log `
        "Location : $($dcr.location)"

    Write-Log `
        "ETag     : $($dcr.etag)"

    # ========================================================================
    # VALIDATE DCR BEFORE CHANGE
    # ========================================================================

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "VALIDATING EXISTING DCR"
    Write-Log "============================================================"

    $dcrValidation =
        Test-DCRConfiguration `
            -Dcr $dcr

    # ========================================================================
    # ADD CLASSIC CONFIGURATION IF MISSING
    # ========================================================================

    if (-not $dcrValidation.ClassicConfigured) {

        Write-Log ""
        Write-Log "============================================================"
        Write-Log "CLASSIC LOG-BASED METRICS"
        Write-Log "============================================================"

        Write-Log `
            "Classic VM Insights configuration is missing." `
            -Level WARNING

        Write-Log `
            "Required configuration:"

        Write-Log `
            "  Data source : $ClassicDataSourceName"

        Write-Log `
            "  Counter     : $ClassicCounterSpecifier"

        Write-Log `
            "  Stream      : $ExpectedClassicStream"

        Write-Log `
            "  Destination : $ExpectedPerfDestinationName"

        if (
            $PSCmdlet.ShouldProcess(
                $DcrResourceId,
                "Add Classic VM Insights Microsoft-InsightsMetrics configuration"
            )
        ) {

            $dcrToUpdate =
                Add-ClassicConfigurationToDcr `
                    -Dcr $dcr

            $updatedDcr =
                Update-SharedDcr `
                    -Dcr $dcrToUpdate

            # ---------------------------------------------------------------
            # Re-read after update
            # ---------------------------------------------------------------

            Write-Log `
                "Re-reading DCR after update..."

            $dcr =
                Get-SharedDcr `
                    -DcrResourceId $DcrResourceId

            $dcrValidation =
                Test-DCRConfiguration `
                    -Dcr $dcr

            if (-not $dcrValidation.ClassicConfigured) {

                throw `
                    "The Classic VM Insights configuration could not be verified after updating the DCR."
            }

            Write-Log `
                "Classic VM Insights configuration verified after DCR update" `
                -Level SUCCESS
        }
        else {

            Write-Log `
                "[WhatIf] Would add Classic VM Insights configuration" `
                -Level INFO
        }
    }
    else {

        Write-Log ""
        Write-Log `
            "Classic VM Insights configuration already exists" `
            -Level SUCCESS
    }

    # ========================================================================
    # FINAL SHARED DCR VALIDATION
    # ========================================================================

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "FINAL DCR VALIDATION"
    Write-Log "============================================================"

    $dcr =
        Get-SharedDcr `
            -DcrResourceId $DcrResourceId

    $dcrValidation =
        Test-DCRConfiguration `
            -Dcr $dcr

    if (-not $dcrValidation.OtelFlowFound) {

        throw `
            "OpenTelemetry configuration is missing from the shared DCR."
    }

    if (-not $dcrValidation.DestinationFound) {

        throw `
            "VMInsightsPerf-Logs-Dest is missing from the shared DCR."
    }

    if (-not $dcrValidation.WorkspaceCorrect) {

        throw `
            "VMInsightsPerf-Logs-Dest does not point to the expected Log Analytics workspace."
    }

    if (-not $dcrValidation.ClassicConfigured) {

        if (-not $WhatIfPreference) {

            throw `
                "Classic VM Insights configuration is still missing after the DCR update."
        }
    }

    Write-Log ""
    Write-Log `
        "Shared DCR validation completed" `
        -Level SUCCESS

    # ========================================================================
    # DISCOVER VMs
    # ========================================================================

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "DISCOVERING VMs"
    Write-Log "============================================================"

    if ($ResourceGroupName) {

        $allVMs = @(
            Get-AzVM `
                -ResourceGroupName $ResourceGroupName `
                -Status `
                -ErrorAction Stop
        )
    }
    else {

        $allVMs = @(
            Get-AzVM `
                -Status `
                -ErrorAction Stop
        )
    }

    Write-Log `
        "Total VMs discovered: $($allVMs.Count)"

    if ($allVMs.Count -eq 0) {

        Write-Log `
            "No VMs found in selected scope." `
            -Level WARNING

        return
    }

    # ========================================================================
    # RESULTS
    # ========================================================================

    $results =
        [System.Collections.Generic.List[PSCustomObject]]::new()

    $counters = @{
        Total                    = 0
        Processed                = 0
        Success                  = 0

        AMAInstalled             = 0
        AMAAlreadyInstalled      = 0
        AMAInstallationFailed    = 0

        DAInstalled              = 0
        DAAlreadyInstalled       = 0
        DAInstallationFailed     = 0
        DASkippedRHEL9Plus       = 0

        AssociationCreated       = 0
        AssociationAlreadyOK     = 0
        AssociationCorrected     = 0
        AssociationFailed        = 0

        ClassicMetricsReady      = 0
        OpenTelemetryReady       = 0

        SkippedARO               = 0
        SkippedStopped           = 0
        SkippedDeallocated       = 0
        SkippedUnknownPowerState = 0

        Failed                   = 0
        WhatIf                   = 0
    }

    # ========================================================================
    # PROCESS VMs
    # ========================================================================

    $i = 0

    foreach ($vm in $allVMs) {

        $i++
        $counters.Total++

        $vmName =
            [string]$vm.Name

        $vmRG =
            [string]$vm.ResourceGroupName

        $vmId =
            [string]$vm.Id

        $osType =
            [string]$vm.StorageProfile.OsDisk.OsType

        Write-Progress `
            -Activity "Configuring Azure VM Monitoring" `
            -Status "$vmName ($i/$($allVMs.Count))" `
            -PercentComplete (($i / $allVMs.Count) * 100)

        Write-Log ""
        Write-Log "============================================================"

        Write-Log `
            "[$i/$($allVMs.Count)] $vmName ($vmRG)"

        # --------------------------------------------------------------------
        # Power state
        # --------------------------------------------------------------------

        $powerState =
            Get-VMPowerState `
                -VM $vm

        Write-Log `
            "  OS Type     : $osType"

        Write-Log `
            "  Power State : $powerState"

        # --------------------------------------------------------------------
        # Result object
        # --------------------------------------------------------------------

        $result = [PSCustomObject]@{

            VMName =
                $vmName

            ResourceGroup =
                $vmRG

            OSType =
                $osType

            PowerState =
                $powerState

            AMAStatus =
                $null

            AMAAction =
                $null

            DependencyAgentStatus =
                $null

            DependencyAgentAction =
                $null

            DCRAssociationStatus =
                $null

            DCRAssociationAction =
                $null

            ClassicMetricsStatus =
                if ($dcrValidation.ClassicConfigured) {
                    "Configured - Microsoft-InsightsMetrics -> $ExpectedPerfDestinationName"
                }
                else {
                    "Not configured"
                }

            OpenTelemetryStatus =
                if ($dcrValidation.OtelFlowFound) {
                    "Configured - Microsoft-OtelPerfMetrics -> $ExpectedOtelDestinationName"
                }
                else {
                    "Not configured"
                }

            Status =
                $null

            Message =
                $null

            AssociationName =
                $AssociationName

            DcrResourceId =
                $DcrResourceId

            WorkspaceResourceId =
                $ExpectedWorkspaceResourceId

            Timestamp =
                (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        # ====================================================================
        # ARO EXCLUSION
        # ====================================================================

        if (
            Test-ExcludedResourceGroup `
                -ResourceGroup $vmRG
        ) {

            Write-Log `
                "  Resource group excluded: $vmRG" `
                -Level WARNING

            $result.Status =
                "SkippedARO"

            $result.Message =
                "Resource group matches exclusion pattern"

            $counters.SkippedARO++

            $results.Add($result)

            continue
        }

        # ====================================================================
        # DEALLOCATED
        # ====================================================================

        if (
            $powerState -eq
                "VM deallocated"
        ) {

            Write-Log `
                "  VM is deallocated - skipping" `
                -Level WARNING

            $result.Status =
                "SkippedDeallocated"

            $result.Message =
                "VM is deallocated"

            $counters.SkippedDeallocated++

            $results.Add($result)

            continue
        }

        # ====================================================================
        # STOPPED
        # ====================================================================

        if (
            $powerState -eq
                "VM stopped"
        ) {

            Write-Log `
                "  VM is stopped - skipping" `
                -Level WARNING

            $result.Status =
                "SkippedStopped"

            $result.Message =
                "VM is stopped"

            $counters.SkippedStopped++

            $results.Add($result)

            continue
        }

        # ====================================================================
        # ONLY RUNNING
        # ====================================================================

        if (
            $powerState -ne
                "VM running"
        ) {

            Write-Log `
                "  VM is not confirmed as Running - skipping" `
                -Level WARNING

            $result.Status =
                "SkippedUnknownPowerState"

            $result.Message =
                "VM state is not confirmed as Running: $powerState"

            $counters.SkippedUnknownPowerState++

            $results.Add($result)

            continue
        }

        Write-Log `
            "  VM confirmed as Running" `
            -Level SUCCESS

        $counters.Processed++

        # ====================================================================
        # AMA
        # ====================================================================

        $amaResult =
            Install-OrUpdate-AMA `
                -VM $vm `
                -VMResourceGroup $vmRG `
                -VMName $vmName `
                -OSType $osType

        if ($amaResult.Success) {

            $result.AMAStatus =
                "Succeeded"

            $result.AMAAction =
                $amaResult.Message
        }
        else {

            $result.AMAStatus =
                "Failed"

            $result.AMAAction =
                $amaResult.Message

            $counters.AMAInstallationFailed++
            $counters.Failed++

            $result.Status =
                "Failed"

            $result.Message =
                "AMA failed: $($amaResult.Message)"

            $results.Add($result)

            continue
        }

        if ($amaResult.Installed) {

            $counters.AMAInstalled++
        }
        elseif ($amaResult.AlreadyInstalled) {

            $counters.AMAAlreadyInstalled++
        }

        # ====================================================================
        # DEPENDENCY AGENT
        # ====================================================================

        $daResult =
            Install-OrUpdate-DependencyAgent `
                -VM $vm `
                -VMResourceGroup $vmRG `
                -VMName $vmName `
                -OSType $osType

        if ($daResult.Skipped) {

            $result.DependencyAgentStatus =
                "Skipped"

            $result.DependencyAgentAction =
                $daResult.Message

            $counters.DASkippedRHEL9Plus++
        }
        elseif ($daResult.Success) {

            $result.DependencyAgentStatus =
                "Succeeded"

            $result.DependencyAgentAction =
                $daResult.Message

            if ($daResult.Installed) {
                $counters.DAInstalled++
            }
            elseif ($daResult.AlreadyInstalled) {
                $counters.DAAlreadyInstalled++
            }
        }
        else {

            $result.DependencyAgentStatus =
                "Failed"

            $result.DependencyAgentAction =
                $daResult.Message

            $counters.DAInstallationFailed++
            $counters.Failed++

            $result.Status =
                "Failed"

            $result.Message =
                "Dependency Agent failed: $($daResult.Message)"

            $results.Add($result)

            continue
        }

        # ====================================================================
        # GET DCR ASSOCIATIONS
        # ====================================================================

        Write-Log `
            "  Checking VM DCR associations..."

        try {

            $existingAssociations =
                @(
                    Get-VMDataCollectionRuleAssociations `
                        -VmResourceId $vmId
                )

            $existing =
                $existingAssociations |
                Where-Object {
                    [string]$_.name -ieq
                        $AssociationName
                } |
                Select-Object -First 1
        }
        catch {

            Write-Log `
                "  Failed to query DCR associations: $($_.Exception.Message)" `
                -Level ERROR

            $result.DCRAssociationStatus =
                "Failed"

            $result.DCRAssociationAction =
                $_.Exception.Message

            $result.Status =
                "Failed"

            $result.Message =
                "Failed to query existing DCR associations"

            $counters.AssociationFailed++
            $counters.Failed++

            $results.Add($result)

            continue
        }

        # ====================================================================
        # ALREADY CORRECT
        # ====================================================================

        if (
            $existing -and
            [string]$existing.properties.dataCollectionRuleId -eq
                $DcrResourceId
        ) {

            Write-Log `
                "  DCR association already points to target DCR" `
                -Level SUCCESS

            $result.DCRAssociationStatus =
                "Succeeded"

            $result.DCRAssociationAction =
                "Already configured"

            $counters.AssociationAlreadyOK++
        }

        # ====================================================================
        # WRONG DCR
        # ====================================================================

        elseif ($existing) {

            $existingDcrId =
                [string]$existing.properties.dataCollectionRuleId

            Write-Log `
                "  Existing association points to another DCR" `
                -Level WARNING

            Write-Log `
                "    Existing DCR: $existingDcrId"

            Write-Log `
                "    Target DCR  : $DcrResourceId"

            if (
                $PSCmdlet.ShouldProcess(
                    $vmName,
                    "Replace DCR association '$AssociationName'"
                )
            ) {

                try {

                    Write-Log `
                        "  Removing incorrect association..."

                    Remove-VMDataCollectionRuleAssociationRest `
                        -VmResourceId $vmId `
                        -AssociationName $AssociationName |
                        Out-Null

                    Start-Sleep -Seconds 3

                    Write-Log `
                        "  Creating correct DCR association..."

                    New-VMDataCollectionRuleAssociationRest `
                        -VmResourceId $vmId `
                        -AssociationName $AssociationName `
                        -DcrResourceId $DcrResourceId |
                        Out-Null

                    Write-Log `
                        "  DCR association corrected" `
                        -Level SUCCESS

                    $result.DCRAssociationStatus =
                        "Succeeded"

                    $result.DCRAssociationAction =
                        "Incorrect association replaced"

                    $counters.AssociationCorrected++
                }
                catch {

                    Write-Log `
                        "  Failed to correct association: $($_.Exception.Message)" `
                        -Level ERROR

                    $result.DCRAssociationStatus =
                        "Failed"

                    $result.DCRAssociationAction =
                        $_.Exception.Message

                    $result.Status =
                        "Failed"

                    $result.Message =
                        "DCR association correction failed"

                    $counters.AssociationFailed++
                    $counters.Failed++

                    $results.Add($result)

                    continue
                }
            }
            else {

                Write-Log `
                    "  [WhatIf] Would replace incorrect association"

                $result.DCRAssociationStatus =
                    "WhatIf"

                $result.DCRAssociationAction =
                    "Would replace incorrect association"

                $counters.WhatIf++
            }
        }

        # ====================================================================
        # ASSOCIATION MISSING
        # ====================================================================

        else {

            Write-Log `
                "  Target DCR association not found"

            if (
                $PSCmdlet.ShouldProcess(
                    $vmName,
                    "Create DCR association '$AssociationName'"
                )
            ) {

                try {

                    New-VMDataCollectionRuleAssociationRest `
                        -VmResourceId $vmId `
                        -AssociationName $AssociationName `
                        -DcrResourceId $DcrResourceId |
                        Out-Null

                    Write-Log `
                        "  DCR association created" `
                        -Level SUCCESS

                    $result.DCRAssociationStatus =
                        "Succeeded"

                    $result.DCRAssociationAction =
                        "Created"

                    $counters.AssociationCreated++
                }
                catch {

                    Write-Log `
                        "  Failed to create DCR association: $($_.Exception.Message)" `
                        -Level ERROR

                    $result.DCRAssociationStatus =
                        "Failed"

                    $result.DCRAssociationAction =
                        $_.Exception.Message

                    $result.Status =
                        "Failed"

                    $result.Message =
                        "DCR association creation failed"

                    $counters.AssociationFailed++
                    $counters.Failed++

                    $results.Add($result)

                    continue
                }
            }
            else {

                Write-Log `
                    "  [WhatIf] Would create DCR association"

                $result.DCRAssociationStatus =
                    "WhatIf"

                $result.DCRAssociationAction =
                    "Would create association"

                $counters.WhatIf++
            }
        }

        # ====================================================================
        # MONITORING STATUS
        # ====================================================================

        if ($dcrValidation.ClassicConfigured) {
            $counters.ClassicMetricsReady++
        }

        if ($dcrValidation.OtelFlowFound) {
            $counters.OpenTelemetryReady++
        }

        # ====================================================================
        # FINAL STATUS
        # ====================================================================

        if ($WhatIfPreference) {

            $result.Status =
                "WhatIf"

            $result.Message =
                "WhatIf - VM actions evaluated; shared DCR configuration validated"

            $counters.WhatIf++
        }
        else {

            $result.Status =
                "Success"

            $result.Message =
                "AMA ready; Dependency Agent ready (or skipped for RHEL 9+); DCR association ready; Classic VM Insights and OpenTelemetry configuration ready"

            $counters.Success++
        }

        $results.Add($result)
    }

    Write-Progress `
        -Activity "Configuring Azure VM Monitoring" `
        -Completed

    # ========================================================================
    # FINAL SUMMARY
    # ========================================================================

    Write-Log ""

    Write-Log "============================================================"

    Write-Log `
        "FINAL SUMMARY"

    Write-Log "============================================================"

    Write-Log `
        "Total VMs discovered       : $($counters.Total)"

    Write-Log `
        "VMs processed              : $($counters.Processed)"

    Write-Log `
        "Successful                 : $($counters.Success)" `
        -Level SUCCESS

    Write-Log "------------------------------------------------------------"

    Write-Log `
        "AMA installed              : $($counters.AMAInstalled)" `
        -Level SUCCESS

    Write-Log `
        "AMA already installed      : $($counters.AMAAlreadyInstalled)" `
        -Level SUCCESS

    if ($counters.AMAInstallationFailed -gt 0) {

        Write-Log `
            "AMA installation failed    : $($counters.AMAInstallationFailed)" `
            -Level ERROR
    }
    else {

        Write-Log `
            "AMA installation failed    : $($counters.AMAInstallationFailed)"
    }

    Write-Log "------------------------------------------------------------"

    Write-Log `
        "Dependency Agent installed : $($counters.DAInstalled)" `
        -Level SUCCESS

    Write-Log `
        "Dependency Agent already OK: $($counters.DAAlreadyInstalled)" `
        -Level SUCCESS

    Write-Log `
        "Dependency Agent skipped (RHEL 9+): $($counters.DASkippedRHEL9Plus)" `
        -Level WARNING

    if ($counters.DAInstallationFailed -gt 0) {

        Write-Log `
            "Dependency Agent failed    : $($counters.DAInstallationFailed)" `
            -Level ERROR
    }
    else {

        Write-Log `
            "Dependency Agent failed    : $($counters.DAInstallationFailed)"
    }

    Write-Log "------------------------------------------------------------"

    Write-Log `
        "DCR associations created   : $($counters.AssociationCreated)" `
        -Level SUCCESS

    Write-Log `
        "DCR associations OK        : $($counters.AssociationAlreadyOK)" `
        -Level SUCCESS

    Write-Log `
        "DCR associations corrected: $($counters.AssociationCorrected)" `
        -Level SUCCESS

    if ($counters.AssociationFailed -gt 0) {

        Write-Log `
            "DCR association failures   : $($counters.AssociationFailed)" `
            -Level ERROR
    }
    else {

        Write-Log `
            "DCR association failures   : $($counters.AssociationFailed)"
    }

    Write-Log "------------------------------------------------------------"

    Write-Log `
        "Classic Metrics ready      : $($counters.ClassicMetricsReady)" `
        -Level SUCCESS

    Write-Log `
        "OpenTelemetry ready        : $($counters.OpenTelemetryReady)" `
        -Level SUCCESS

    Write-Log "------------------------------------------------------------"

    Write-Log `
        "Skipped ARO-INFRA-*        : $($counters.SkippedARO)" `
        -Level WARNING

    Write-Log `
        "Skipped stopped            : $($counters.SkippedStopped)" `
        -Level WARNING

    Write-Log `
        "Skipped deallocated       : $($counters.SkippedDeallocated)" `
        -Level WARNING

    Write-Log `
        "Skipped unknown state      : $($counters.SkippedUnknownPowerState)" `
        -Level WARNING

    Write-Log "------------------------------------------------------------"

    if ($counters.Failed -gt 0) {

        Write-Log `
            "Failed                     : $($counters.Failed)" `
            -Level ERROR
    }
    else {

        Write-Log `
            "Failed                     : $($counters.Failed)"
    }

    Write-Log `
        "WhatIf actions             : $($counters.WhatIf)"

    Write-Log "============================================================"

    # ========================================================================
    # CSV
    # ========================================================================

    if ($ExportCsv) {

        $exportDirectory =
            Split-Path -Parent $ExportCsv

        if (
            $exportDirectory -and
            -not (Test-Path $exportDirectory)
        ) {

            New-Item `
                -ItemType Directory `
                -Path $exportDirectory `
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

    return $results
}
catch {

    Write-Progress `
        -Activity "Configuring Azure VM Monitoring" `
        -Completed

    Write-Log ""

    Write-Log "============================================================"

    Write-Log `
        "FATAL ERROR"

    Write-Log "============================================================"

    $fatalMessage =
        [string]$_.Exception.Message

    if ([string]::IsNullOrWhiteSpace($fatalMessage)) {
        $fatalMessage = "An unknown error occurred."
    }

    Write-Log `
        $fatalMessage `
        -Level ERROR

    throw
}