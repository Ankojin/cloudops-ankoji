<#
.SYNOPSIS
    Inventory BAB VM-start Logic Apps and calculate standardized names.

.DESCRIPTION
    Central Logic Apps are located in:

        Subscription:
        d88f0b5b-6660-4607-8c6a-395820400912

        Resource Group:
        bab-core-auto-weeu-rg-01

        Location:
        West Europe

    Target naming convention:

        bab-{env}-{resource_type}-{role}-start-01

    Example:

        VM Resource Group:
        bab-dev-new-bib-swec-rg-01

        VM:
        DANBIBDBORDLV01

        Result:
        bab-dev-new-bib-db-start-01

    IMPORTANT:
        Environment and ResourceType are derived from the VM Resource Group.

        They are NOT derived from the existing Logic App name.

    Role detection:

        APWB -> appweb
        AP   -> appweb
        DB   -> db

    Inventory mode:
        READ ONLY.
        No Logic Apps are modified.

.NOTES
    PowerShell 5.1 compatible.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Inventory", "Rename")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = (Join-Path $PSScriptRoot "BAB-LogicApp-Inventory.csv"),

    [Parameter(Mandatory = $false)]
    [string]$InventoryCsv = (Join-Path $PSScriptRoot "BAB-LogicApp-Inventory.csv"),

    [Parameter(Mandatory = $false)]
    [string]$BackupFolder = (Join-Path $PSScriptRoot "BAB-LogicApp-Backups"),

    [Parameter(Mandatory = $false)]
    [switch]$DisableOld
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$AutomationSubscriptionId = "d88f0b5b-6660-4607-8c6a-395820400912"

$AutomationResourceGroup = "bab-core-auto-weeu-rg-01"

$AutomationLocation = "westeurope"

# Microsoft.Logic/workflows
#
# IMPORTANT:
# Microsoft.Logic/workflows does NOT support 2024-11-01.
#
# Supported version from the error received:
# 2019-05-01
#
$LogicAppApiVersion = "2019-05-01"

# Microsoft.Compute/virtualMachines
$VmApiVersion = "2024-07-01"

# Log file beside the script
$LogFile = Join-Path `
    $PSScriptRoot `
    ("BAB-LogicApp-Migration-{0}.log" -f `
        (Get-Date -Format "yyyyMMdd-HHmmss"))

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {

    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet(
            "INFO",
            "WARN",
            "ERROR",
            "SUCCESS",
            "DEBUG"
        )]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $line = "[{0}] [{1}] {2}" -f `
        $timestamp,
        $Level,
        $Message

    Write-Host $line

    try {

        Add-Content `
            -Path $LogFile `
            -Value $line `
            -ErrorAction Stop
    }
    catch {

        # Logging failure must never stop inventory processing.
    }
}

# ============================================================================
# PREREQUISITES
# ============================================================================

function Test-Prerequisites {

    Write-Log "Checking required PowerShell modules..."

    $requiredModules = @(
        "Az.Accounts",
        "Az.Resources"
    )

    foreach ($module in $requiredModules) {

        if (-not (Get-Module -ListAvailable -Name $module)) {

            throw `
                "Required module '$module' is not installed."
        }

        Import-Module `
            $module `
            -ErrorAction Stop
    }

    $context = Get-AzContext

    if (-not $context) {

        Write-Log `
            "No Azure context found. Starting Azure login..." `
            "WARN"

        Connect-AzAccount `
            -ErrorAction Stop
    }

    Set-AzContext `
        -SubscriptionId $AutomationSubscriptionId `
        -ErrorAction Stop |
        Out-Null

    $context = Get-AzContext

    Write-Log `
        "Authenticated as: $($context.Account.Id)"

    Write-Log `
        "Subscription: $($context.Subscription.Name)"

    Write-Log `
        "Subscription ID: $($context.Subscription.Id)"
}

# ============================================================================
# BUILD AZURE REST URI
# ============================================================================

function New-AzureResourceUri {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    if ([string]::IsNullOrWhiteSpace($ResourcePath)) {

        throw `
            "ResourcePath cannot be empty."
    }

    if ([string]::IsNullOrWhiteSpace($ApiVersion)) {

        throw `
            "ApiVersion cannot be empty."
    }

    # IMPORTANT:
    # Always construct ?api-version= explicitly.
    #
    # This prevents the previous problem where:
    #
    #     -version=2019-05-01
    #
    # was generated accidentally.

    $uri = "{0}?api-version={1}" -f `
        $ResourcePath,
        $ApiVersion

    if ($uri -notmatch '\?api-version=') {

        throw `
            "Generated URI is missing api-version: $uri"
    }

    return $uri
}

# ============================================================================
# REST GET
# ============================================================================

function Invoke-AzureGet {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    # nextLink values from ARM are absolute URLs and already contain
    # api-version / skiptoken. Relative paths must include ?api-version=.
    $isAbsolute =
        $Uri -match '^https?://'

    if (
        -not $isAbsolute -and
        $Uri -notmatch '\?api-version='
    ) {

        throw `
            "Azure REST URI is missing '?api-version=': $Uri"
    }

    # Invoke-AzRestMethod works most reliably with a relative -Path
    # (including query string). Absolute nextLink URLs are converted
    # to path+query so the same call works on all Az module versions.
    $pathForRest = $Uri

    if ($isAbsolute) {

        try {

            $uriObj = [System.Uri]$Uri

            # Keep path + query (e.g. /subscriptions/...?api-version=...&$skiptoken=...)
            $pathForRest = $uriObj.PathAndQuery
        }
        catch {

            throw `
                "Unable to parse absolute Azure nextLink URL: $Uri"
        }
    }

    Write-Log `
        "GET $pathForRest" `
        "DEBUG"

    try {

        $response = Invoke-AzRestMethod `
            -Method GET `
            -Path $pathForRest `
            -ErrorAction Stop

        if (
            $response.StatusCode -lt 200 -or
            $response.StatusCode -ge 300
        ) {

            throw `
                "REST GET failed. HTTP $($response.StatusCode): $($response.Content)"
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $response.Content
            )
        ) {

            return $null
        }

        return (
            $response.Content |
            ConvertFrom-Json -Depth 100
        )
    }
    catch {

        throw $_
    }
}

# ============================================================================
# GET CENTRAL LOGIC APPS
# ============================================================================
#
# Azure Resource Manager list APIs are paginated.
# The first response only contains one page (typically up to ~100 items).
# Additional pages are retrieved by following the "nextLink" property
# until it is absent.
#
# Without following nextLink, many Logic Apps in the resource group
# would be silently skipped.
#
# ============================================================================

function Get-CentralLogicApps {

    Write-Log `
        "Getting Logic Apps from central automation subscription..."

    $resourcePath =
        "/subscriptions/$AutomationSubscriptionId" +
        "/resourceGroups/$AutomationResourceGroup" +
        "/providers/Microsoft.Logic/workflows"

    $uri = New-AzureResourceUri `
        -ResourcePath $resourcePath `
        -ApiVersion $LogicAppApiVersion

    $allLogicApps = @()
    $pageNumber   = 0

    do {

        $pageNumber++

        Write-Log `
            "Fetching Logic Apps page $pageNumber..." `
            "DEBUG"

        $result =
            Invoke-AzureGet `
                -Uri $uri

        if (-not $result) {
            break
        }

        if ($result.value) {

            $pageCount = @($result.value).Count

            Write-Log `
                "Page $pageNumber returned $pageCount Logic App(s)." `
                "INFO"

            $allLogicApps += @($result.value)
        }
        else {

            Write-Log `
                "Page $pageNumber returned no items." `
                "DEBUG"
        }

        # nextLink is an absolute URL when present; empty/null when done.
        if (
            $result.PSObject.Properties.Name -contains "nextLink" -and
            -not [string]::IsNullOrWhiteSpace([string]$result.nextLink)
        ) {

            $uri = [string]$result.nextLink
        }
        else {

            $uri = $null
        }

    } while ($uri)

    Write-Log `
        "Total Logic Apps collected (all pages): $($allLogicApps.Count)" `
        "SUCCESS"

    return @($allLogicApps)
}

# ============================================================================
# GET INDIVIDUAL LOGIC APP
# ============================================================================

function Get-LogicApp {

    param(
        [Parameter(Mandatory = $true)]
        [string]$LogicAppName
    )

    $encodedName =
        [System.Uri]::EscapeDataString(
            $LogicAppName
        )

    $resourcePath =
        "/subscriptions/$AutomationSubscriptionId" +
        "/resourceGroups/$AutomationResourceGroup" +
        "/providers/Microsoft.Logic/workflows/$encodedName"

    $uri = New-AzureResourceUri `
        -ResourcePath $resourcePath `
        -ApiVersion $LogicAppApiVersion

    return (
        Invoke-AzureGet `
            -Uri $uri
    )
}

# ============================================================================
# EXTRACT RECURRENCE SCHEDULE
# ============================================================================

function Get-RecurrenceSchedule {

    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition
    )

    if (-not $Definition) {

        return $null
    }

    if (-not $Definition.triggers) {

        return $null
    }

    foreach (
        $property in
        $Definition.triggers.PSObject.Properties
    ) {

        $trigger =
            $property.Value

        if (
            [string]$trigger.type -ne
            "Recurrence"
        ) {

            continue
        }

        $recurrence =
            $trigger.recurrence

        if (-not $recurrence) {

            continue
        }

        $hour = $null
        $minute = $null
        $timeZone = ""

        # --------------------------------------------------------------------
        # Schedule.hours
        # --------------------------------------------------------------------

        if ($recurrence.schedule) {

            if (
                $null -ne
                $recurrence.schedule.hours
            ) {

                $hours =
                    @(
                        $recurrence.schedule.hours
                    )

                if ($hours.Count -gt 0) {

                    $hour =
                        [int]$hours[0]
                }
            }

            # ----------------------------------------------------------------
            # Schedule.minutes
            # ----------------------------------------------------------------

            if (
                $null -ne
                $recurrence.schedule.minutes
            ) {

                $minutes =
                    @(
                        $recurrence.schedule.minutes
                    )

                if ($minutes.Count -gt 0) {

                    $minute =
                        [int]$minutes[0]
                }
            }
        }

        # --------------------------------------------------------------------
        # Time zone
        # --------------------------------------------------------------------

        if ($recurrence.timeZone) {

            $timeZone =
                [string]$recurrence.timeZone
        }

        # --------------------------------------------------------------------
        # Fallback: startTime
        # --------------------------------------------------------------------

        if (
            ($null -eq $hour -or
             $null -eq $minute) -and
            $recurrence.startTime
        ) {

            try {

                $start =
                    [DateTimeOffset]::Parse(
                        [string]$recurrence.startTime
                    )

                $hour =
                    $start.Hour

                $minute =
                    $start.Minute
            }
            catch {

                Write-Log `
                    "Could not parse recurrence startTime '$($recurrence.startTime)'." `
                    "WARN"
            }
        }

        if (
            $null -ne $hour -and
            $null -ne $minute
        ) {

            return [PSCustomObject]@{

                TriggerName =
                    $property.Name

                Frequency =
                    [string]$recurrence.frequency

                Interval =
                    [string]$recurrence.interval

                Hour =
                    [int]$hour

                Minute =
                    [int]$minute

                HHMM =
                    "{0:D2}{1:D2}" -f `
                        [int]$hour,
                        [int]$minute

                TimeZone =
                    $timeZone
            }
        }
    }

    return $null
}

# ============================================================================
# FIND VM RESOURCE IDS IN WORKFLOW DEFINITION
# ============================================================================

function Get-VmResourceIdsFromObject {

    param(
        [Parameter(Mandatory = $true)]
        [object]$Object
    )

    $results =
        New-Object System.Collections.Generic.List[string]

    function Search-Object {

        param(
            [object]$Current
        )

        if ($null -eq $Current) {

            return
        }

        # --------------------------------------------------------------------
        # String
        # --------------------------------------------------------------------

        if ($Current -is [string]) {

            $pattern =
                '(?i)/subscriptions/[0-9a-f-]+' +
                '/resourceGroups/[^/"'']+' +
                '/providers/Microsoft\.Compute/' +
                'virtualMachines/[^/"''\s\)\],]+'

            $matches =
                [regex]::Matches(
                    $Current,
                    $pattern
                )

            foreach ($match in $matches) {

                $value =
                    $match.Value.TrimEnd(
                        '/',
                        '"',
                        "'",
                        ')',
                        ']',
                        ','
                    )

                if (
                    -not $results.Contains(
                        $value
                    )
                ) {

                    $results.Add(
                        $value
                    )
                }
            }

            return
        }

        # --------------------------------------------------------------------
        # IDictionary
        # --------------------------------------------------------------------

        if (
            $Current -is
            [System.Collections.IDictionary]
        ) {

            foreach ($key in $Current.Keys) {

                Search-Object `
                    -Current $Current[$key]
            }

            return
        }

        # --------------------------------------------------------------------
        # PSCustomObject
        # --------------------------------------------------------------------

        if (
            $Current -is
            [System.Management.Automation.PSCustomObject]
        ) {

            foreach (
                $property in
                $Current.PSObject.Properties
            ) {

                Search-Object `
                    -Current $property.Value
            }

            return
        }

        # --------------------------------------------------------------------
        # Enumerable
        # --------------------------------------------------------------------

        if (
            $Current -is
            [System.Collections.IEnumerable] -and
            -not ($Current -is [string])
        ) {

            foreach ($item in $Current) {

                Search-Object `
                    -Current $item
            }
        }
    }

    Search-Object `
        -Current $Object

    return @(
        $results
    )
}

# ============================================================================
# GET VM
# ============================================================================

function Get-VmFromResourceId {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $parts =
        $ResourceId.Trim('/').Split('/')

    $subscriptionId = $null
    $resourceGroup  = $null
    $vmName         = $null

    for (
        $i = 0;
        $i -lt $parts.Count;
        $i++
    ) {

        if (
            $parts[$i] -ieq
            "subscriptions"
        ) {

            if (
                $i + 1 -lt
                $parts.Count
            ) {

                $subscriptionId =
                    $parts[$i + 1]
            }
        }

        if (
            $parts[$i] -ieq
            "resourceGroups"
        ) {

            if (
                $i + 1 -lt
                $parts.Count
            ) {

                $resourceGroup =
                    $parts[$i + 1]
            }
        }

        if (
            $parts[$i] -ieq
            "virtualMachines"
        ) {

            if (
                $i + 1 -lt
                $parts.Count
            ) {

                $vmName =
                    $parts[$i + 1]
            }
        }
    }

    if (
        -not $subscriptionId -or
        -not $resourceGroup -or
        -not $vmName
    ) {

        return $null
    }

    $encodedVmName =
        [System.Uri]::EscapeDataString(
            $vmName
        )

    $resourcePath =
        "/subscriptions/$subscriptionId" +
        "/resourceGroups/$resourceGroup" +
        "/providers/Microsoft.Compute" +
        "/virtualMachines/$encodedVmName"

    $uri =
        New-AzureResourceUri `
            -ResourcePath $resourcePath `
            -ApiVersion $VmApiVersion

    try {

        return (
            Invoke-AzureGet `
                -Uri $uri
        )
    }
    catch {

        Write-Log `
            "Unable to retrieve VM '$ResourceId': $($_.Exception.Message)" `
            "WARN"

        return $null
    }
}

# ============================================================================
# DETECT VM ROLE
# ============================================================================

function Get-ServerRole {

    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $upperName =
        $VmName.ToUpperInvariant()

    # ------------------------------------------------------------------------
    # Order matters: more specific patterns first.
    # APWB -> appweb
    # AP   -> appweb
    # WB   -> appweb
    # DB   -> db
    # ------------------------------------------------------------------------

    if (
        $upperName -match "APWB"
    ) {

        return [PSCustomObject]@{

            Role =
                "appweb"

            Pattern =
                "APWB"
        }
    }

    if (
        $upperName -match "AP"
    ) {

        return [PSCustomObject]@{

            Role =
                "appweb"

            Pattern =
                "AP"
        }
    }

    if (
        $upperName -match "WB"
    ) {

        return [PSCustomObject]@{

            Role =
                "appweb"

            Pattern =
                "WB"
        }
    }

    if (
        $upperName -match "DB"
    ) {

        return [PSCustomObject]@{

            Role =
                "db"

            Pattern =
                "DB"
        }
    }

    return [PSCustomObject]@{

        Role =
            "unknown"

        Pattern =
            ""
    }
}

# ============================================================================
# PARSE VM RESOURCE GROUP
# ============================================================================
#
# Supported patterns (case-insensitive). Resource type may contain hyphens.
#
#   1. bab-{env}-{resource_type}-swec-rg-##
#      e.g. bab-dev-new-bib-swec-rg-01
#           bab-sit-baas-swec-rg-01
#
#   2. bab-{env}-{resource_type}-{region}-rg-##
#      region = swec | br | weeu | neeu | ...
#      e.g. bab-dev-ppl-br-rg-01
#           bab-sit-ppl-br-rg-01
#
#   3. bab-{env}-{resource_type}-rg-##
#      (no region token)
#      e.g. bab-sit-abic-ibm-rg-01
#           BAB-SIT-ABIC-IBM-RG-01
#           BAB-SIT-PPL-BR-RG-01   (BR treated as part of resource_type
#                                   unless matched by pattern 2 first)
#
#   4. {org}-{env}-{resource_type}-swec-rg-##
#      org = enj | ...
#      e.g. enj-dev-amk-swec-rg-01
#
#   5. {env}-{resource_type}-swec-rg-##
#      (no org prefix)
#      e.g. sit-sde-swec-rg-01
#           SIT-SDE-SWEC-RG-01
#
#   6. {env}-{resource_type}-rg-##
#      e.g. sit-sde-rg-01
#
# Known environment tokens are preferred when disambiguating.
#
# ============================================================================

function Get-ResourceGroupComponents {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $rg =
        $ResourceGroupName.Trim()

    # Known environment tokens (lowercase). Used to validate / prefer matches.
    $knownEnvs = @(
        "dev", "sit", "uat", "prod", "prd", "test", "tst", "qa", "ppd", "preprod"
    )

    # Known region tokens that appear before -rg-##
    $knownRegions = @(
        "swec", "br", "weeu", "neeu", "eus", "wus", "cus", "seas", "jpe", "aue"
    )

    $regexOptions =
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # ------------------------------------------------------------------------
    # Pattern list – first successful match wins.
    # More specific patterns (with region / org) are listed first.
    # ------------------------------------------------------------------------

    $patterns = @(

        # 1+2: bab-{env}-{resource_type}-{region}-rg-##
        #      region is a known region token
        (
            '^bab-(?<env>[^-]+)-(?<resource_type>.+)-(?<region>' +
            ($knownRegions -join '|') +
            ')-rg-\d+$'
        ),

        # 3: bab-{env}-{resource_type}-rg-##  (no region)
        '^bab-(?<env>[^-]+)-(?<resource_type>.+)-rg-\d+$',

        # 4: {org}-{env}-{resource_type}-{region}-rg-##
        #    org is a short alphabetic prefix that is NOT a known env
        (
            '^(?<org>[a-z]{2,5})-(?<env>[^-]+)-(?<resource_type>.+)-(?<region>' +
            ($knownRegions -join '|') +
            ')-rg-\d+$'
        ),

        # 5: {env}-{resource_type}-{region}-rg-##  (no org)
        (
            '^(?<env>[^-]+)-(?<resource_type>.+)-(?<region>' +
            ($knownRegions -join '|') +
            ')-rg-\d+$'
        ),

        # 6: {env}-{resource_type}-rg-##  (no org, no region)
        '^(?<env>[^-]+)-(?<resource_type>.+)-rg-\d+$'
    )

    foreach ($pattern in $patterns) {

        $match =
            [regex]::Match(
                $rg,
                $pattern,
                $regexOptions
            )

        if (-not $match.Success) {
            continue
        }

        $environment =
            $match.Groups["env"].Value.ToLowerInvariant()

        $resourceType =
            $match.Groups["resource_type"].Value.ToLowerInvariant()

        # If the pattern captured an "org" that is actually a known env,
        # the match is wrong (e.g. pattern 4 matching a bab-less env-first name).
        # Skip those – a later pattern will handle them.
        if (
            $match.Groups["org"].Success -and
            $knownEnvs -contains $match.Groups["org"].Value.ToLowerInvariant()
        ) {
            continue
        }

        # Prefer matches where env is a known environment token.
        # Still accept unknown env tokens so unusual names are not blocked,
        # but only if resource_type is non-empty.
        if (
            [string]::IsNullOrWhiteSpace($environment) -or
            [string]::IsNullOrWhiteSpace($resourceType)
        ) {
            continue
        }

        # Strip trailing region-like tokens that may have been absorbed into
        # resource_type when a more specific pattern did not match
        # (defensive; patterns 1/2/4/5 already isolate region).
        foreach ($region in $knownRegions) {
            if ($resourceType -match ("^(?<rt>.+)-" + [regex]::Escape($region) + "$")) {
                $resourceType = $Matches["rt"]
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($resourceType)) {
            continue
        }

        return [PSCustomObject]@{

            Environment =
                $environment

            ResourceType =
                $resourceType

            ParseStatus =
                "Success"
        }
    }

    return [PSCustomObject]@{

        Environment =
            ""

        ResourceType =
            ""

        ParseStatus =
            "ManualReview"
    }
}

# ============================================================================
# BUILD TARGET LOGIC APP NAME
# ============================================================================

function Get-ProposedLogicAppName {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    return (
        "bab-{0}-{1}-{2}-start-01" -f `
            $Environment,
            $ResourceType,
            $Role
    )
}

# ============================================================================
# INVENTORY
# ============================================================================

function Invoke-Inventory {

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "BAB VM START LOGIC APP INVENTORY"
    Write-Log "============================================================"

    Write-Log `
        "Automation Subscription : $AutomationSubscriptionId"

    Write-Log `
        "Automation Resource Group: $AutomationResourceGroup"

    Write-Log `
        "Automation Location      : $AutomationLocation"

    Write-Log `
        "Logic App API Version    : $LogicAppApiVersion"

    Write-Log `
        "VM API Version           : $VmApiVersion"

    Write-Log `
        "Environment/ResourceType source: VM Resource Group"

    # ------------------------------------------------------------------------
    # Get Logic Apps
    # ------------------------------------------------------------------------

    $logicApps =
        Get-CentralLogicApps

    Write-Log `
        "Logic Apps discovered: $($logicApps.Count)" `
        "SUCCESS"

    $inventory =
        New-Object System.Collections.Generic.List[object]

    # ------------------------------------------------------------------------
    # Process Logic Apps
    # ------------------------------------------------------------------------

    foreach ($logicAppSummary in $logicApps) {

        $logicAppName =
            [string]$logicAppSummary.name

        Write-Log ""
        Write-Log `
            "Processing Logic App: $logicAppName"

        try {

            $logicApp =
                Get-LogicApp `
                    -LogicAppName $logicAppName

            if (
                -not $logicApp.properties.definition
            ) {

                Write-Log `
                    "No workflow definition found." `
                    "WARN"

                continue
            }

            $definition =
                $logicApp.properties.definition

            # ----------------------------------------------------------------
            # Schedule
            # ----------------------------------------------------------------

            $schedule =
                Get-RecurrenceSchedule `
                    -Definition $definition

            if (-not $schedule) {

                Write-Log `
                    "No recurrence schedule found." `
                    "WARN"

                $inventory.Add(
                    [PSCustomObject]@{

                        ExistingLogicApp =
                            $logicAppName

                        ExistingLogicAppId =
                            $logicApp.id

                        ExistingState =
                            [string]$logicApp.properties.state

                        Environment =
                            ""

                        ResourceType =
                            ""

                        TriggerName =
                            ""

                        Frequency =
                            ""

                        Interval =
                            ""

                        StartHHMM =
                            ""

                        TimeZone =
                            ""

                        VmName =
                            ""

                        VmResourceId =
                            ""

                        VmSubscriptionId =
                            ""

                        VmResourceGroup =
                            ""

                        VmLocation =
                            ""

                        DetectedPattern =
                            ""

                        Role =
                            "unknown"

                        ProposedLogicApp =
                            ""

                        GroupKey =
                            ""

                        Status =
                            "ManualReview-NoSchedule"
                    }
                )

                continue
            }

            Write-Log `
                "Schedule: $($schedule.HHMM) [$($schedule.TimeZone)]"

            # ----------------------------------------------------------------
            # Find VM resource IDs
            # ----------------------------------------------------------------

            $vmIds =
                Get-VmResourceIdsFromObject `
                    -Object $definition

            Write-Log `
                "VM resource IDs discovered: $($vmIds.Count)"

            if ($vmIds.Count -eq 0) {

                Write-Log `
                    "No VM resource IDs found in workflow definition." `
                    "WARN"

                $inventory.Add(
                    [PSCustomObject]@{

                        ExistingLogicApp =
                            $logicAppName

                        ExistingLogicAppId =
                            $logicApp.id

                        ExistingState =
                            [string]$logicApp.properties.state

                        Environment =
                            ""

                        ResourceType =
                            ""

                        TriggerName =
                            $schedule.TriggerName

                        Frequency =
                            $schedule.Frequency

                        Interval =
                            $schedule.Interval

                        StartHHMM =
                            $schedule.HHMM

                        TimeZone =
                            $schedule.TimeZone

                        VmName =
                            ""

                        VmResourceId =
                            ""

                        VmSubscriptionId =
                            ""

                        VmResourceGroup =
                            ""

                        VmLocation =
                            ""

                        DetectedPattern =
                            ""

                        Role =
                            "unknown"

                        ProposedLogicApp =
                            ""

                        GroupKey =
                            ""

                        Status =
                            "ManualReview-NoVMFound"
                    }
                )

                continue
            }

            # ----------------------------------------------------------------
            # Process each VM
            # ----------------------------------------------------------------

            foreach ($vmId in $vmIds) {

                Write-Log `
                    "Processing VM resource ID: $vmId" `
                    "DEBUG"

                $vm =
                    Get-VmFromResourceId `
                        -ResourceId $vmId

                if (-not $vm) {

                    $inventory.Add(
                        [PSCustomObject]@{

                            ExistingLogicApp =
                                $logicAppName

                            ExistingLogicAppId =
                                $logicApp.id

                            ExistingState =
                                [string]$logicApp.properties.state

                            Environment =
                                ""

                            ResourceType =
                                ""

                            TriggerName =
                                $schedule.TriggerName

                            Frequency =
                                $schedule.Frequency

                            Interval =
                                $schedule.Interval

                            StartHHMM =
                                $schedule.HHMM

                            TimeZone =
                                $schedule.TimeZone

                            VmName =
                                ""

                            VmResourceId =
                                $vmId

                            VmSubscriptionId =
                                ""

                            VmResourceGroup =
                                ""

                            VmLocation =
                                ""

                            DetectedPattern =
                                ""

                            Role =
                                "unknown"

                            ProposedLogicApp =
                                ""

                            GroupKey =
                                ""

                            Status =
                                "ManualReview-VMNotFound"
                        }
                    )

                    continue
                }

                $vmName =
                    [string]$vm.name

                # ----------------------------------------------------------------
                # Get resource group from VM resource ID.
                # ----------------------------------------------------------------

                $vmResourceGroup =
                    (
                        $vm.id -split
                        "/resourceGroups/"
                    )[1] -split "/"

                $vmResourceGroup =
                    [string]$vmResourceGroup[0]

                Write-Log `
                    "VM: $vmName"

                Write-Log `
                    "VM Resource Group: $vmResourceGroup"

                # ----------------------------------------------------------------
                # Resource Group -> Environment + Resource Type
                # ----------------------------------------------------------------

                $rgInfo =
                    Get-ResourceGroupComponents `
                        -ResourceGroupName $vmResourceGroup

                Write-Log `
                    "Environment: $($rgInfo.Environment)" `
                    "DEBUG"

                Write-Log `
                    "Resource Type: $($rgInfo.ResourceType)" `
                    "DEBUG"

                # ----------------------------------------------------------------
                # VM name -> Role
                # ----------------------------------------------------------------

                $roleInfo =
                    Get-ServerRole `
                        -VmName $vmName

                Write-Log `
                    "Role: $($roleInfo.Role) [$($roleInfo.Pattern)]"

                # ----------------------------------------------------------------
                # VM subscription
                # ----------------------------------------------------------------

                $vmSubscriptionId =
                    (
                        $vm.id -split
                        "/subscriptions/"
                    )[1] -split "/"

                $vmSubscriptionId =
                    [string]$vmSubscriptionId[0]

                # ----------------------------------------------------------------
                # Proposed Logic App
                # ----------------------------------------------------------------

                $proposedName =
                    ""

                if (
                    $rgInfo.ParseStatus -eq
                    "Success" -and
                    $roleInfo.Role -ne
                    "unknown"
                ) {

                    $proposedName =
                        Get-ProposedLogicAppName `
                            -Environment $rgInfo.Environment `
                            -ResourceType $rgInfo.ResourceType `
                            -Role $roleInfo.Role
                }

                # ----------------------------------------------------------------
                # Group key
                #
                # Same RG + same role + same time =
                # same new Logic App.
                #
                # DB and AppWeb are intentionally separate.
                # ----------------------------------------------------------------

                $groupKey =
                    "{0}|{1}|{2}|{3}|{4}|{5}" -f `
                        $vmSubscriptionId,
                        $vmResourceGroup,
                        $rgInfo.Environment,
                        $rgInfo.ResourceType,
                        $roleInfo.Role,
                        $schedule.HHMM

                # ----------------------------------------------------------------
                # Status
                # ----------------------------------------------------------------

                $status =
                    "Ready"

                if (
                    $rgInfo.ParseStatus -ne
                    "Success"
                ) {

                    $status =
                        "ManualReview-ResourceGroupParsing"
                }
                elseif (
                    $roleInfo.Role -eq
                    "unknown"
                ) {

                    $status =
                        "ManualReview-UnknownRole"
                }

                # ----------------------------------------------------------------
                # Add inventory row
                # ----------------------------------------------------------------

                $inventory.Add(
                    [PSCustomObject]@{

                        ExistingLogicApp =
                            $logicAppName

                        ExistingLogicAppId =
                            $logicApp.id

                        ExistingState =
                            [string]$logicApp.properties.state

                        Environment =
                            $rgInfo.Environment

                        ResourceType =
                            $rgInfo.ResourceType

                        TriggerName =
                            $schedule.TriggerName

                        Frequency =
                            $schedule.Frequency

                        Interval =
                            $schedule.Interval

                        StartHHMM =
                            $schedule.HHMM

                        TimeZone =
                            $schedule.TimeZone

                        VmName =
                            $vmName

                        VmResourceId =
                            $vm.id

                        VmSubscriptionId =
                            $vmSubscriptionId

                        VmResourceGroup =
                            $vmResourceGroup

                        VmLocation =
                            [string]$vm.location

                        DetectedPattern =
                            $roleInfo.Pattern

                        Role =
                            $roleInfo.Role

                        ProposedLogicApp =
                            $proposedName

                        GroupKey =
                            $groupKey

                        Status =
                            $status
                    }
                )
            }
        }
        catch {

            Write-Log `
                "Failed processing '$logicAppName': $($_.Exception.Message)" `
                "ERROR"
        }
    }

    # =========================================================================
    # COLLISION CHECK
    # =========================================================================

    Write-Log ""
    Write-Log `
        "Checking proposed Logic App names for collisions..."

    $readyRows = @(
        $inventory |
        Where-Object {
            $_.Status -eq "Ready" -and
            -not [string]::IsNullOrWhiteSpace(
                $_.ProposedLogicApp
            )
        }
    )

    $duplicateTargets =
        $readyRows |
        Group-Object ProposedLogicApp |
        Where-Object {
            $_.Count -gt 1
        }

    if ($duplicateTargets.Count -gt 0) {

        foreach ($duplicate in $duplicateTargets) {

            Write-Log `
                "Target '$($duplicate.Name)' has $($duplicate.Count) inventory rows." `
                "WARN"
        }
    }
    else {

        Write-Log `
            "No proposed Logic App name collisions found." `
            "SUCCESS"
    }

    # =========================================================================
    # EXPORT CSV
    # =========================================================================

    $inventory |
        Sort-Object `
            Environment,
            ResourceType,
            Role,
            StartHHMM,
            VmResourceGroup,
            VmName |
        Export-Csv `
            -Path $OutputCsv `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Log ""
    Write-Log `
        "Inventory CSV created successfully." `
        "SUCCESS"

    Write-Log `
        "CSV: $OutputCsv" `
        "SUCCESS"

    # =========================================================================
    # SUMMARY
    # =========================================================================

    $readyCount =
        @(
            $inventory |
            Where-Object {
                $_.Status -eq "Ready"
            }
        ).Count

    $manualReviewCount =
        @(
            $inventory |
            Where-Object {
                $_.Status -like "ManualReview*"
            }
        ).Count

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "INVENTORY SUMMARY"
    Write-Host "============================================================"

    Write-Host `
        "Logic Apps discovered : $($logicApps.Count)"

    Write-Host `
        "Inventory rows         : $($inventory.Count)"

    Write-Host `
        "Ready rows             : $readyCount"

    Write-Host `
        "Manual review rows     : $manualReviewCount"

    Write-Host ""

    Write-Host "Role summary:"
    Write-Host ""

    $inventory |
        Group-Object Role |
        Select-Object `
            Name,
            Count |
        Format-Table -AutoSize

    Write-Host ""

    Write-Host "Proposed Logic Apps:"
    Write-Host ""

    $inventory |
        Where-Object {
            $_.Status -eq "Ready"
        } |
        Select-Object `
            ProposedLogicApp,
            Environment,
            ResourceType,
            Role,
            StartHHMM,
            TimeZone,
            VmResourceGroup,
            VmName |
        Sort-Object `
            ProposedLogicApp,
            VmName |
        Format-Table -AutoSize

    Write-Host ""

    return $inventory
}

# ============================================================================
# MAIN
# ============================================================================

try {

    Write-Log `
        "============================================================"

    Write-Log `
        "Starting BAB VM Start Logic App management script."

    Write-Log `
        "Mode: $Mode"

    Write-Log `
        "Script directory: $PSScriptRoot"

    Write-Log `
        "Output CSV: $OutputCsv"

    Write-Log `
        "============================================================"

    Test-Prerequisites

    switch ($Mode) {

        "Inventory" {

            Invoke-Inventory |
                Out-Null
        }

        "Rename" {

            # ----------------------------------------------------------------
            # IMPORTANT:
            #
            # Rename/Create functionality is intentionally NOT executed yet.
            #
            # We first validate the generated inventory.
            #
            # The next production phase will:
            #
            #   1. Read the validated inventory
            #   2. Group DB and AppWeb independently
            #   3. Backup existing Logic App definition
            #   4. Create the new Logic App
            #   5. Preserve the recurrence schedule
            #   6. Split DB and AppWeb VMs correctly
            #   7. Validate the new workflow
            #   8. Disable the old Logic App
            #   9. Never delete the old Logic App
            #
            # ----------------------------------------------------------------

            Write-Log `
                "Rename mode is intentionally disabled in this version." `
                "WARN"

            Write-Log `
                "Run Inventory mode first and validate BAB-LogicApp-Inventory.csv." `
                "WARN"
        }
    }

    Write-Log ""
    Write-Log `
        "$Mode operation completed successfully." `
        "SUCCESS"
}
catch {

    Write-Log `
        "FATAL ERROR: $($_.Exception.Message)" `
        "ERROR"

    throw
}