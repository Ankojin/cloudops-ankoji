<#
.SYNOPSIS
    Creates standardized VM-start Logic Apps from an inventory CSV.

.DESCRIPTION
    Creates the ProposedLogicApp in the central automation subscription.

    Migration flow:

        Existing Logic App
              |
              v
        Backup definition
              |
              v
        Identify VM resource IDs/actions
              |
              v
        Replace ONLY Microsoft.Compute VM resource IDs
              |
              v
        Validate VM replacement
              |
              v
        Create NEW Logic App in West Europe
              |
              v
        Validate NEW Logic App
              |
              v
        Enable NEW Logic App
              |
              v
        Optionally disable OLD Logic App

    OLD LOGIC APPS ARE NEVER DELETED.

    IMPORTANT:
        Function App IDs, Storage IDs, Key Vault IDs, etc. are NOT modified.

    FUNCTION + VMLISTS PATTERN (preferred for current templates):

        Many existing Logic Apps call a Function App and pass VM resource
        IDs inside body.RequestScopes.VMLists (an array of full resource
        ID strings).  When this pattern is detected the script:

            - Leaves the Function App ID and overall action structure
              completely unchanged.
            - Rewrites the VMLists array so it contains exactly the
              target VM resource IDs from the inventory CSV for that
              ProposedLogicApp.
            - Supports 1->1 and 1->N for a single source Logic App.
            - Multiple source Logic Apps mapped to one target are rejected
              unless the migration is explicitly implemented as a merge.
            - Extra VMs that were present in the template but are not part
              of the target inventory are dropped.

    CLASSIC / DIRECT ARM ACTION PATTERN (legacy fallback):

        MULTI-VM BEHAVIOUR:
            If source contains the same number of VM IDs as target rows,
            source VM IDs are mapped to target rows in discovery order.

        SINGLE-VM BEHAVIOUR:
            If source contains one VM and target contains one VM,
            only that VM resource ID is replaced.

            If source contains one VM and target contains multiple VMs,
            the VM action containing the source VM is cloned for each
            target VM (top-level actions only).

    NEW LOGIC APPS ARE ALWAYS CREATED IN WEST EUROPE.

    PowerShell 7.1+ compatible.
#>

[CmdletBinding(SupportsShouldProcess)]
param(

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Validate",
        "Rename"
    )]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$InventoryCsv = (
        Join-Path $PSScriptRoot "BAB-LogicApp-Inventory.csv"
    ),

    [Parameter(Mandatory = $false)]
    [string]$BackupFolder = (
        Join-Path $PSScriptRoot "BAB-LogicApp-Backups"
    ),

    [Parameter(Mandatory = $false)]
    [string]$ResultsCsv = (
        Join-Path $PSScriptRoot "BAB-LogicApp-Rename-Results.csv"
    ),

    [Parameter(Mandatory = $false)]
    [string]$TestResourceGroup,

    [Parameter(Mandatory = $false)]
    [int]$TestVmCount = 0,

    [Parameter(Mandatory = $false)]
    [switch]$DisableOld
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$AutomationSubscriptionId =
    "d88f0b5b-6660-4607-8c6a-395820400912"

$AutomationResourceGroup =
    "bab-core-auto-weeu-rg-01"

# IMPORTANT:
# All NEW Logic Apps are created in West Europe.
$AutomationLocation =
    "westeurope"

$LogicApiVersion =
    "2019-05-01"

$LogFile =
    Join-Path `
        $PSScriptRoot `
        (
            "BAB-VMStart-Rename-{0}.log" -f `
            (Get-Date -Format "yyyyMMdd-HHmmss")
        )

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {

    param(

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message = "",

        [ValidateSet(
            "INFO",
            "WARN",
            "ERROR",
            "SUCCESS",
            "DEBUG"
        )]
        [string]$Level = "INFO"
    )

    $timestamp =
        Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $line =
        "[{0}] [{1}] {2}" -f `
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
        # Logging must never stop migration.
    }
}

# ============================================================================
# ERROR DETAILS
# ============================================================================

function Get-ExceptionDetails {

    param(

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message =
        $ErrorRecord.Exception.Message

    $category =
        $ErrorRecord.CategoryInfo.ToString()

    $fullyQualified =
        $ErrorRecord.FullyQualifiedErrorId

    $position =
        $ErrorRecord.InvocationInfo.PositionMessage

    return @"
Message:
$message

Category:
$category

FullyQualifiedErrorId:
$fullyQualified

Position:
$position
"@
}

# ============================================================================
# AZURE INITIALIZATION
# ============================================================================

function Initialize-Azure {

    Write-Log ""
    Write-Log "Checking Azure connection..."

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {

        throw "Az.Accounts module is not installed."
    }

    if (-not (Get-Module -ListAvailable -Name Az.Resources)) {

        throw "Az.Resources module is not installed."
    }

    Import-Module `
        Az.Accounts `
        -ErrorAction Stop

    Import-Module `
        Az.Resources `
        -ErrorAction Stop

    $context =
        Get-AzContext

    if (-not $context) {

        Write-Log `
            "No Azure login detected. Starting Connect-AzAccount..." `
            "WARN"

        Connect-AzAccount `
            -ErrorAction Stop
    }

    Set-AzContext `
        -SubscriptionId $AutomationSubscriptionId `
        -ErrorAction Stop |
        Out-Null

    $context =
        Get-AzContext

    Write-Log `
        "Azure account: $($context.Account.Id)"

    Write-Log `
        "Automation subscription: $($context.Subscription.Id)"

    if (
        $context.Subscription.Id.ToLowerInvariant() -ne
        $AutomationSubscriptionId.ToLowerInvariant()
    ) {

        throw "Unable to switch to automation subscription."
    }

    Write-Log `
        "Azure initialization successful." `
        "SUCCESS"
}

# ============================================================================
# URI
# ============================================================================

function New-AzureUri {

    param(

        [Parameter(Mandatory = $true)]
        [string]$ResourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    return (
        "{0}?api-version={1}" -f `
            $ResourcePath,
            $ApiVersion
    )
}

# ============================================================================
# REST GET
# ============================================================================

function Invoke-AzureGet {

    param(

        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if ($Uri -notmatch '\?api-version=') {

        throw "Invalid Azure URI. Missing ?api-version=: $Uri"
    }

    Write-Log `
        "GET $Uri" `
        "DEBUG"

    try {

        $response =
            Invoke-AzRestMethod `
                -Method GET `
                -Path $Uri `
                -ErrorAction Stop
    }
    catch {

        throw `
            "Azure REST GET failed: $($_.Exception.Message)"
    }

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

    try {

        return (
            $response.Content |
                ConvertFrom-Json -Depth 100
        )
    }
    catch {

        throw `
            "Unable to parse Azure REST response as JSON: $($_.Exception.Message)"
    }
}

# ============================================================================
# REST PUT
# ============================================================================

function Invoke-AzurePut {

    param(

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [object]$Body
    )

    if ($Uri -notmatch '\?api-version=') {

        throw "Invalid Azure URI. Missing ?api-version=: $Uri"
    }

    $json =
        $Body |
            ConvertTo-Json `
                -Depth 100 `
                -Compress

    Write-Log `
        "PUT $Uri" `
        "DEBUG"

    try {

        $response =
            Invoke-AzRestMethod `
                -Method PUT `
                -Path $Uri `
                -Payload $json `
                -ErrorAction Stop
    }
    catch {

        throw `
            "Azure REST PUT failed: $($_.Exception.Message)"
    }

    if (
        $response.StatusCode -lt 200 -or
        $response.StatusCode -ge 300
    ) {

        throw `
            "REST PUT failed. HTTP $($response.StatusCode): $($response.Content)"
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $response.Content
        )
    ) {

        return $null
    }

    try {

        return (
            $response.Content |
                ConvertFrom-Json -Depth 100
        )
    }
    catch {

        throw `
            "Unable to parse Azure REST PUT response as JSON: $($_.Exception.Message)"
    }
}

# ============================================================================
# GET LOGIC APP
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

    $uri =
        New-AzureUri `
            -ResourcePath $resourcePath `
            -ApiVersion $LogicApiVersion

    return (
        Invoke-AzureGet `
            -Uri $uri
    )
}

# ============================================================================
# TEST LOGIC APP EXISTS
# ============================================================================

function Test-LogicAppExists {

    param(

        [Parameter(Mandatory = $true)]
        [string]$LogicAppName
    )

    try {

        $app =
            Get-LogicApp `
                -LogicAppName $LogicAppName

        return ($null -ne $app)
    }
    catch {

        $message =
            $_.Exception.Message

        if (
            $message -match "404" -or
            $message -match "ResourceNotFound" -or
            $message -match "NotFound"
        ) {

            return $false
        }

        throw
    }
}

# ============================================================================
# GET DEFINITION
# ============================================================================

function Get-LogicAppDefinition {

    param(

        [Parameter(Mandatory = $true)]
        [object]$LogicApp
    )

    if (-not $LogicApp.properties) {

        throw `
            "Logic App '$($LogicApp.name)' has no properties."
    }

    if (-not $LogicApp.properties.definition) {

        throw `
            "Logic App '$($LogicApp.name)' has no workflow definition."
    }

    return $LogicApp.properties.definition
}

# ============================================================================
# GET PARAMETERS
# ============================================================================

function Get-LogicAppParameters {

    param(

        [Parameter(Mandatory = $true)]
        [object]$LogicApp
    )

    if ($LogicApp.properties.parameters) {

        return $LogicApp.properties.parameters
    }

    return $null
}

# ============================================================================
# GET STATE
# ============================================================================

function Get-LogicAppState {

    param(

        [Parameter(Mandatory = $true)]
        [object]$LogicApp
    )

    if (
        $LogicApp.properties -and
        $LogicApp.properties.state
    ) {

        return [string]$LogicApp.properties.state
    }

    return "Unknown"
}

# ============================================================================
# BACKUP
# ============================================================================

function Backup-LogicApp {

    param(

        [Parameter(Mandatory = $true)]
        [object]$LogicApp,

        [Parameter(Mandatory = $true)]
        [string]$Folder
    )

    if (-not (Test-Path $Folder)) {

        New-Item `
            -ItemType Directory `
            -Path $Folder `
            -Force |
            Out-Null
    }

    $safeName =
        $LogicApp.name -replace '[\\/:*?"<>|]', '_'

    $timestamp =
        Get-Date -Format "yyyyMMdd-HHmmss"

    $backupPath =
        Join-Path `
            $Folder `
            "$safeName-$timestamp.json"

    $LogicApp |
        ConvertTo-Json `
            -Depth 100 |
        Set-Content `
            -Path $backupPath `
            -Encoding UTF8

    Write-Log `
        "Backup created: $backupPath" `
        "SUCCESS"

    return $backupPath
}

# ============================================================================
# VM RESOURCE ID REGEX
# ============================================================================

$script:VmResourceIdPattern =
    '(?i)/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' +
    '/resourceGroups/[^/"''\s\)\],]+' +
    '/providers/Microsoft\.Compute/virtualMachines/[^/"''\s\)\],]+'

$script:VmResourceIdExactPattern =
    '(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' +
    '/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+$'

# ============================================================================
# NORMALIZE VM RESOURCE ID
# ============================================================================

function Normalize-VmResourceId {

    param(

        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if (
        [string]::IsNullOrWhiteSpace($ResourceId)
    ) {

        return $null
    }

    $value =
        $ResourceId.Trim()

    $value =
        $value.Trim(
            '"',
            "'",
            ')',
            ']',
            ',',
            ' '
        )

    return $value
}

# ============================================================================
# TEST VM RESOURCE ID
# ============================================================================

function Test-IsVmResourceId {

    param(

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if (
        [string]::IsNullOrWhiteSpace($Value)
    ) {

        return $false
    }

    return (
        $Value -match $script:VmResourceIdExactPattern
    )
}

# ============================================================================
# EXTRACT VM IDS FROM STRING
# ============================================================================

function Get-VmResourceIdsFromString {

    param(

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $result = @()

    if (
        [string]::IsNullOrWhiteSpace($Value)
    ) {

        return @()
    }

    $matches =
        [regex]::Matches(
            $Value,
            $script:VmResourceIdPattern
        )

    foreach ($match in $matches) {

        $id =
            Normalize-VmResourceId `
                -ResourceId $match.Value

        if (
            $id -and
            (
                $result |
                    Where-Object {
                        $_.Equals(
                            $id,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            ).Count -eq 0
        ) {

            $result += $id
        }
    }

    return @($result)
}

# ============================================================================
# GET PROPERTY VALUE SAFELY
# ============================================================================

function Get-ObjectPropertyValue {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {

        return $null
    }

    $property =
        $Object.PSObject.Properties[
            $PropertyName
        ]

    if ($null -eq $property) {

        return $null
    }

    return $property.Value
}

# ============================================================================
# FIND ALL VM RESOURCE IDS IN DEFINITION
# ============================================================================
#
# IMPORTANT:
# This implementation intentionally avoids strongly typed .NET collections.
#
# The previous implementation could generate:
#
#     Argument types do not match
#
# during recursive object traversal.
#
# ============================================================================

function Get-VmResourceIdsFromDefinition {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Definition
    )

    # Use a script-scoped collector to avoid nested-function scoping issues
    # with PowerShell closures / variable capture.
    $script:__vmIdCollector = @()

    function Search-Object {

        param(
            [AllowNull()]
            [object]$Current
        )

        if ($null -eq $Current) {
            return
        }

        if ($Current -is [string]) {
            $ids = @(Get-VmResourceIdsFromString -Value $Current)
            foreach ($id in $ids) {
                $exists = $script:__vmIdCollector | Where-Object {
                    $_.Equals($id, [System.StringComparison]::OrdinalIgnoreCase)
                }
                if ($null -eq $exists) {
                    $script:__vmIdCollector += $id
                }
            }
            return
        }

        # Dictionaries (Hashtable, OrderedDictionary, etc.)
        if ($Current -is [System.Collections.IDictionary]) {
            foreach ($key in @($Current.Keys)) {
                Search-Object -Current $Current[$key]
            }
            return
        }

        # Arrays / lists (but not strings)
        if (
            $Current -is [System.Collections.IEnumerable] -and
            -not ($Current -is [string]) -and
            -not ($Current -is [System.Collections.IDictionary])
        ) {
            foreach ($item in $Current) {
                Search-Object -Current $item
            }
            return
        }

        # PSCustomObject / any other object with properties
        if ($null -ne $Current.PSObject -and $null -ne $Current.PSObject.Properties) {
            foreach ($property in @($Current.PSObject.Properties)) {
                Search-Object -Current $property.Value
            }
        }
    }

    Search-Object -Current $Definition

    $found = @($script:__vmIdCollector)

    # ------------------------------------------------------------------
    # FALLBACK: full JSON string scan
    # This catches IDs that the recursive walker may miss due to
    # PowerShell type / depth / enumeration quirks after ConvertFrom-Json.
    # ------------------------------------------------------------------
    if ($found.Count -eq 0) {
        try {
            $json = $Definition | ConvertTo-Json -Depth 100 -Compress
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $found = @(Get-VmResourceIdsFromString -Value $json)
            }
        }
        catch {
            # Fallback must never throw
        }
    }

    Remove-Variable -Name __vmIdCollector -Scope Script -ErrorAction SilentlyContinue

    return @($found)
}

# ============================================================================
# FIND VM ACTION CANDIDATES
# ============================================================================
#
# FIXED:
#   - No generic List.Add()
#   - No typed collection operations
#   - Handles nested actions recursively
#   - Records the complete action object
#
# ============================================================================

function Find-VmActionCandidates {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Actions,

        [string]$ActionPath = ""
    )

    $results = @()

    if ($null -eq $Actions) {
        return @()
    }

    foreach ($property in @($Actions.PSObject.Properties)) {

        $actionName = [string]$property.Name
        $action = $property.Value

        if ($null -eq $action) {
            continue
        }

        $currentPath = if ([string]::IsNullOrWhiteSpace($ActionPath)) {
            $actionName
        } else {
            "$ActionPath.$actionName"
        }

        # First inspect nested containers. A parent action must not compete
        # with the actual child action that contains the VM resource ID.
        $nestedResults = @()

        $nestedActions = Get-ObjectPropertyValue -Object $action -PropertyName "actions"
        if ($null -ne $nestedActions) {
            $nestedResults += @(Find-VmActionCandidates -Actions $nestedActions -ActionPath $currentPath)
        }

        $ifObject = Get-ObjectPropertyValue -Object $action -PropertyName "if"
        if ($null -ne $ifObject) {
            $ifActions = Get-ObjectPropertyValue -Object $ifObject -PropertyName "actions"
            if ($null -ne $ifActions) {
                $nestedResults += @(Find-VmActionCandidates -Actions $ifActions -ActionPath "$currentPath.if")
            }

            $elseObject = Get-ObjectPropertyValue -Object $ifObject -PropertyName "else"
            if ($null -ne $elseObject) {
                $elseActions = Get-ObjectPropertyValue -Object $elseObject -PropertyName "actions"
                if ($null -ne $elseActions) {
                    $nestedResults += @(Find-VmActionCandidates -Actions $elseActions -ActionPath "$currentPath.if.else")
                }
            }
        }

        $foreachObject = Get-ObjectPropertyValue -Object $action -PropertyName "foreach"
        if ($null -ne $foreachObject) {
            $foreachActions = Get-ObjectPropertyValue -Object $foreachObject -PropertyName "actions"
            if ($null -ne $foreachActions) {
                $nestedResults += @(Find-VmActionCandidates -Actions $foreachActions -ActionPath "$currentPath.foreach")
            }
        }

        $untilObject = Get-ObjectPropertyValue -Object $action -PropertyName "until"
        if ($null -ne $untilObject) {
            $untilActions = Get-ObjectPropertyValue -Object $untilObject -PropertyName "actions"
            if ($null -ne $untilActions) {
                $nestedResults += @(Find-VmActionCandidates -Actions $untilActions -ActionPath "$currentPath.until")
            }
        }

        # VM IDs directly/anywhere in the parent action.
        $actionVmIds = @(Get-VmResourceIdsFromDefinition -Definition $action)

        # If the VM IDs are already represented by child actions, do not add
        # the parent as a competing candidate.
        $childVmIds = @()
        foreach ($child in $nestedResults) {
            $childVmIds += @($child.VmIds)
        }

        $directCandidateVmIds = @()
        foreach ($vmId in $actionVmIds) {
            $foundInChild = $false
            foreach ($childVmId in $childVmIds) {
                if ($vmId.Equals($childVmId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $foundInChild = $true
                    break
                }
            }
            if (-not $foundInChild) {
                $directCandidateVmIds += $vmId
            }
        }

        if ($directCandidateVmIds.Count -gt 0) {
            $results += [PSCustomObject]@{
                Name   = $actionName
                Path   = $currentPath
                Action = $action
                VmIds  = @($directCandidateVmIds | Select-Object -Unique)
            }
        }

        if ($nestedResults.Count -gt 0) {
            $results += $nestedResults
        }
    }

    return @($results)
}

# ============================================================================
# CLONE OBJECT
# ============================================================================

function Copy-Object {

    param(

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object
    )

    if ($null -eq $Object) {

        return $null
    }

    return (
        $Object |
            ConvertTo-Json `
                -Depth 100 `
                -Compress |
            ConvertFrom-Json `
                -Depth 100
    )
}

# ============================================================================
# SAFE VM RESOURCE ID REPLACEMENT
# ============================================================================

function Replace-VmResourceIdSafe {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$OldVmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$NewVmResourceId
    )

    if ($null -eq $Object) {

        throw "Cannot replace VM resource ID in a null object."
    }

    $oldId =
        Normalize-VmResourceId `
            -ResourceId $OldVmResourceId

    $newId =
        Normalize-VmResourceId `
            -ResourceId $NewVmResourceId

    if (
        -not (Test-IsVmResourceId -Value $oldId)
    ) {

        throw `
            "Old VM resource ID is not valid: $oldId"
    }

    if (
        -not (Test-IsVmResourceId -Value $newId)
    ) {

        throw `
            "New VM resource ID is not valid: $newId"
    }

    Write-Log ""
    Write-Log "Safe VM replacement started." "DEBUG"
    Write-Log "OLD VM: $oldId" "DEBUG"
    Write-Log "NEW VM: $newId" "DEBUG"

    $json =
        $Object |
            ConvertTo-Json `
                -Depth 100 `
                -Compress

    $escapedOldId =
        [regex]::Escape($oldId)

    $updatedJson =
        [regex]::Replace(
            $json,
            $escapedOldId,
            {
                param($match)

                return $newId
            },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

    if ($updatedJson -eq $json) {

        throw `
            "VM replacement failed. Old VM resource ID was not found: $oldId"
    }

    $updatedObject =
        $updatedJson |
            ConvertFrom-Json `
                -Depth 100

    Write-Log `
        "VM resource ID replacement completed." `
        "SUCCESS"

    return $updatedObject
}

# ============================================================================
# FIND ACTION CONTAINING VM
# ============================================================================

function Find-ActionForVm {

    param(

        [Parameter(Mandatory = $true)]
        [object[]]$Candidates,

        [Parameter(Mandatory = $true)]
        [string]$VmResourceId
    )

    $normalizedVm = Normalize-VmResourceId -ResourceId $VmResourceId
    $matches = @()

    foreach ($candidate in $Candidates) {
        foreach ($candidateVmId in @($candidate.VmIds)) {
            if ($candidateVmId.Equals($normalizedVm, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += $candidate
                break
            }
        }
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    if ($matches.Count -gt 1) {
        Write-Log "VM '$normalizedVm' appears in multiple VM action candidates. Migration is ambiguous." "ERROR"
        foreach ($match in $matches) {
            Write-Log "Candidate action: $($match.Path)" "ERROR"
        }
        throw "VM '$normalizedVm' appears in multiple VM action candidates. Refusing to guess which action to modify."
    }

    return $matches[0]
}

# ============================================================================
# REPLACE VM ID IN TOP-LEVEL ACTION
# ============================================================================

function Set-TopLevelAction {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $true)]
        [string]$ActionName,

        [Parameter(Mandatory = $true)]
        [object]$NewAction
    )

    if ($null -eq $Definition.actions) {

        throw "Workflow definition does not contain actions."
    }

    $property =
        $Definition.actions.PSObject.Properties[
            $ActionName
        ]

    if ($null -eq $property) {

        return $false
    }

    $property.Value =
        $NewAction

    return $true
}

# ============================================================================
# UPDATE DEFINITION FOR SINGLE VM
# ============================================================================
#
# This function was referenced by the original script but was missing.
#
# ============================================================================

function Update-DefinitionForVm {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $true)]
        [string]$TemplateVmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmResourceId
    )

    $newDefinition =
        Copy-Object `
            -Object $Definition

    # ------------------------------------------------------------------------
    # First attempt: replace only inside the identified VM action.
    # ------------------------------------------------------------------------

    if ($newDefinition.actions) {

        $candidates =
            @(
                Find-VmActionCandidates `
                    -Actions $newDefinition.actions
            )

        $candidate =
            Find-ActionForVm `
                -Candidates $candidates `
                -VmResourceId $TemplateVmResourceId

        if ($candidate) {

            $updatedAction =
                Replace-VmResourceIdSafe `
                    -Object (
                        Copy-Object `
                            -Object $candidate.Action
                    ) `
                    -OldVmResourceId $TemplateVmResourceId `
                    -NewVmResourceId $TargetVmResourceId

            if (
                $candidate.Path -eq $candidate.Name
            ) {

                $success =
                    Set-TopLevelAction `
                        -Definition $newDefinition `
                        -ActionName $candidate.Name `
                        -NewAction $updatedAction

                if ($success) {

                    return $newDefinition
                }
            }
        }
    }

    # ------------------------------------------------------------------------
    # Fallback:
    #
    # Exact VM resource ID replacement only.
    #
    # This does NOT touch other resource IDs.
    # ------------------------------------------------------------------------

    return (
        Replace-VmResourceIdSafe `
            -Object $newDefinition `
            -OldVmResourceId $TemplateVmResourceId `
            -NewVmResourceId $TargetVmResourceId
    )
}

# ============================================================================
# BUILD SINGLE TARGET VM ACTION
# ============================================================================

function New-TargetVmAction {

    param(

        [Parameter(Mandatory = $true)]
        [object]$SourceAction,

        [Parameter(Mandatory = $true)]
        [string]$SourceVmId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmId
    )

    $actionCopy =
        Copy-Object `
            -Object $SourceAction

    return (
        Replace-VmResourceIdSafe `
            -Object $actionCopy `
            -OldVmResourceId $SourceVmId `
            -NewVmResourceId $TargetVmId
    )
}

# ============================================================================
# GET TEMPLATE
# ============================================================================

function Get-TemplateForTarget {

    param(

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $candidateRows =
        @(
            $Rows |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace(
                        $_.ExistingLogicApp
                    )
                }
        )

    if ($candidateRows.Count -eq 0) {

        return $null
    }

    # ------------------------------------------------------------------------
    # Prefer enabled source.
    # ------------------------------------------------------------------------

    foreach ($row in $candidateRows) {

        $existing =
            Get-LogicApp `
                -LogicAppName $row.ExistingLogicApp

        if (-not $existing) {

            continue
        }

        $state =
            Get-LogicAppState `
                -LogicApp $existing

        Write-Log `
            "Template candidate: $($row.ExistingLogicApp) | State: $state" `
            "DEBUG"

        if (
            $state -ieq "Enabled"
        ) {

            Write-Log `
                "Selected enabled template: $($row.ExistingLogicApp)" `
                "SUCCESS"

            return $existing
        }
    }

    # ------------------------------------------------------------------------
    # If all disabled, use first available.
    # ------------------------------------------------------------------------

    foreach ($row in $candidateRows) {

        $existing =
            Get-LogicApp `
                -LogicAppName $row.ExistingLogicApp

        if ($existing) {

            Write-Log `
                "All template candidates are disabled. Using: $($row.ExistingLogicApp)" `
                "WARN"

            return $existing
        }
    }

    return $null
}

# ============================================================================
# DETECT FUNCTION + VMLISTS PATTERN
# ============================================================================
#
# These Logic Apps call a Function App and pass VM resource IDs in:
#   inputs.body.RequestScopes.VMLists  (array of full resource ID strings)
#
# ============================================================================

function Test-IsFunctionVmListsPattern {

    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition
    )

    $json = $null
    try {
        $json = $Definition | ConvertTo-Json -Depth 100 -Compress
    }
    catch {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($json)) {
        return $false
    }

    # Must contain both a Function action and a VMLists array that holds at least one Compute VM ID
    if ($json -notmatch '"type"\s*:\s*"Function"') {
        return $false
    }

    if ($json -notmatch '"VMLists"') {
        return $false
    }

    $ids = @(Get-VmResourceIdsFromString -Value $json)
    return ($ids.Count -gt 0)
}

# ============================================================================
# REWRITE VMLISTS ARRAYS IN DEFINITION
# ============================================================================
#
# Walks the object graph and replaces the contents of every property
# named "VMLists" that currently holds an array of strings with the
# supplied list of target VM resource IDs.
#
# All other properties (Function App ID, Scope structure, etc.) remain
# untouched.
#
# ============================================================================

function Set-VmListsInDefinition {

    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $true)]
        [string[]]$NewVmResourceIds
    )

    $newIds = @(
        $NewVmResourceIds |
            ForEach-Object { Normalize-VmResourceId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($newIds.Count -eq 0) {
        throw "Set-VmListsInDefinition received an empty list of target VM resource IDs."
    }

    foreach ($id in $newIds) {
        if (-not (Test-IsVmResourceId -Value $id)) {
            throw "Invalid target VM resource ID supplied to Set-VmListsInDefinition: $id"
        }
    }

    # Mutable object avoids PowerShell child-scope assignment problems.
    $counter = [PSCustomObject]@{ Value = 0 }

    function Walk-And-Replace {
        param([AllowNull()][object]$Current)

        if ($null -eq $Current) { return }

        if ($Current -is [System.Collections.IDictionary]) {
            foreach ($key in @($Current.Keys)) {
                if ([string]$key -ieq "VMLists") {
                    $Current[$key] = @($newIds)
                    $counter.Value++
                } else {
                    Walk-And-Replace -Current $Current[$key]
                }
            }
            return
        }

        if ($Current -is [System.Collections.IEnumerable] -and
            -not ($Current -is [string]) -and
            -not ($Current -is [System.Collections.IDictionary])) {
            foreach ($item in $Current) {
                Walk-And-Replace -Current $item
            }
            return
        }

        if ($null -ne $Current.PSObject -and $null -ne $Current.PSObject.Properties) {
            foreach ($property in @($Current.PSObject.Properties)) {
                if ($property.Name -ieq "VMLists") {
                    $property.Value = @($newIds)
                    $counter.Value++
                } else {
                    Walk-And-Replace -Current $property.Value
                }
            }
        }
    }

    Walk-And-Replace -Current $Definition

    if ($counter.Value -eq 0) {
        throw "Set-VmListsInDefinition could not locate any VMLists property to update."
    }

    Write-Log "Rewrote $($counter.Value) VMLists array(s) with $($newIds.Count) target VM ID(s)." "SUCCESS"
    return $Definition
}

# ============================================================================
# BUILD TARGET DEFINITION
# ============================================================================

function New-TargetDefinition {

    param(

        [Parameter(Mandatory = $true)]
        [object]$TemplateLogicApp,

        [Parameter(Mandatory = $true)]
        [object[]]$TargetRows
    )

    $definition =
        Get-LogicAppDefinition `
            -LogicApp $TemplateLogicApp

    if ($TargetRows.Count -eq 0) {
        throw "No VM rows supplied for target."
    }

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "BUILDING TARGET DEFINITION"
    Write-Log "============================================================"

    Write-Log "Template Logic App: $($TemplateLogicApp.name)"
    Write-Log "Target VM rows: $($TargetRows.Count)"

    # ------------------------------------------------------------------------
    # Discover ALL source VM IDs (robust extractor + JSON fallback).
    # ------------------------------------------------------------------------

    $templateVmIds =
        @(
            Get-VmResourceIdsFromDefinition `
                -Definition $definition
        )

    if ($templateVmIds.Count -eq 0) {
        throw `
            "Template Logic App '$($TemplateLogicApp.name)' does not contain a Microsoft.Compute virtual machine resource ID."
    }

    Write-Log `
        "Template contains $($templateVmIds.Count) unique VM resource IDs." `
        "INFO"

    for ($i = 0; $i -lt $templateVmIds.Count; $i++) {
        Write-Log "Source VM [$($i + 1)]: $($templateVmIds[$i])" "DEBUG"
    }

    # ------------------------------------------------------------------------
    # Build the list of target VM resource IDs from the inventory rows.
    # ------------------------------------------------------------------------

    $targetVmIds = @()
    foreach ($row in $TargetRows) {
        $tid = Normalize-VmResourceId -ResourceId ([string]$row.VmResourceId)
        if (-not (Test-IsVmResourceId -Value $tid)) {
            throw "Invalid target VM resource ID for '$($row.VmName)': $tid"
        }
        $targetVmIds += $tid
    }

    Write-Log "Target VM IDs to apply: $($targetVmIds.Count)" "INFO"
    foreach ($tid in $targetVmIds) {
        Write-Log "  -> $tid" "DEBUG"
    }

    # ========================================================================
    # PREFERRED PATH: Function App + RequestScopes.VMLists pattern
    # ========================================================================
    #
    # These Logic Apps call a Function and pass the list of VMs in
    # body.RequestScopes.VMLists.  We simply rewrite that array to contain
    # exactly the target VMs.  Function App ID and all other structure stay
    # unchanged.
    #

    if (Test-IsFunctionVmListsPattern -Definition $definition) {

        Write-Log ""
        Write-Log "Detected Function + VMLists pattern. Using VMLists rewrite mode." "SUCCESS"

        $newDefinition = Copy-Object -Object $definition

        $newDefinition = Set-VmListsInDefinition `
            -Definition $newDefinition `
            -NewVmResourceIds $targetVmIds

        # Final validation
        $finalVmIds = @(Get-VmResourceIdsFromDefinition -Definition $newDefinition)

        Write-Log "Final workflow contains $($finalVmIds.Count) unique VM resource ID(s)." "INFO"
        foreach ($id in $finalVmIds) {
            Write-Log "Final VM ID: $id" "DEBUG"
        }

        foreach ($expected in $targetVmIds) {
            $found = $false
            foreach ($id in $finalVmIds) {
                if ($id.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                throw "Final workflow validation failed. Target VM is missing: $expected"
            }
        }

        # Old source IDs that are not in the target list must be gone
        foreach ($oldId in $templateVmIds) {
            $stillWanted = $false
            foreach ($t in $targetVmIds) {
                if ($oldId.Equals($t, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $stillWanted = $true
                    break
                }
            }
            if (-not $stillWanted) {
                foreach ($id in $finalVmIds) {
                    if ($id.Equals($oldId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Final workflow validation failed. Unwanted old VM ID still present: $oldId"
                    }
                }
            }
        }

        Write-Log "Final VM definition validation successful (Function/VMLists mode)." "SUCCESS"
        return $newDefinition
    }

    # ========================================================================
    # LEGACY PATH: direct ARM / action-based VM start (original logic)
    # ========================================================================

    Write-Log ""
    Write-Log "Function + VMLists pattern not detected. Falling back to classic action-based migration." "WARN"

    # Discover VM actions
    $vmActions = @()
    if ($definition.actions) {
        $vmActions = @(Find-VmActionCandidates -Actions $definition.actions)
    }

    Write-Log "VM action candidates discovered: $($vmActions.Count)" "INFO"

    for ($i = 0; $i -lt $vmActions.Count; $i++) {
        $actionVmIds = @($vmActions[$i].VmIds)
        Write-Log "VM action [$($i + 1)]: $($vmActions[$i].Path) | VM IDs: $($actionVmIds.Count)" "DEBUG"
        foreach ($id in $actionVmIds) {
            Write-Log "  -> $id" "DEBUG"
        }
    }

    # ------------------------------------------------------------------------
    # SINGLE SOURCE VM
    # ------------------------------------------------------------------------

    if ($templateVmIds.Count -eq 1) {

        $sourceVmId = $templateVmIds[0]

        Write-Log ""
        Write-Log "Source contains exactly one VM. Using single-VM migration mode." "INFO"

        # 1 -> 1
        if ($TargetRows.Count -eq 1) {
            $targetVmId = $targetVmIds[0]
            return (
                Update-DefinitionForVm `
                    -Definition $definition `
                    -TemplateVmResourceId $sourceVmId `
                    -TargetVmResourceId $targetVmId
            )
        }

        # 1 -> MANY
        if ($vmActions.Count -eq 0) {
            throw "Source Logic App contains one VM ID but no VM-start action could be identified."
        }

        $sourceActionCandidate = Find-ActionForVm -Candidates $vmActions -VmResourceId $sourceVmId
        if (-not $sourceActionCandidate) {
            throw "Unable to identify the VM-start action containing source VM '$sourceVmId'."
        }

        Write-Log "Source VM-start action: $($sourceActionCandidate.Path)" "INFO"

        if ($sourceActionCandidate.Path -ne $sourceActionCandidate.Name) {
            throw @"
The source VM action '$($sourceActionCandidate.Path)' is nested.

The source contains one VM and the target contains multiple VMs.

For safety, the script will NOT attempt to clone a nested action because
doing so could alter Logic App workflow structure.

Source Logic App:
$($TemplateLogicApp.name)

Source VM:
$sourceVmId

Target VM count:
$($TargetRows.Count)

Please use a source Logic App where the VM-start action is a top-level
action, or create separate source actions for the target VMs.
"@
        }

        $newDefinition = Copy-Object -Object $definition
        $sourceActionName = $sourceActionCandidate.Name
        $sourceActionProperty = $newDefinition.actions.PSObject.Properties[$sourceActionName]

        if ($null -eq $sourceActionProperty) {
            throw "Unable to locate top-level action '$sourceActionName' in cloned definition."
        }

        $sourceAction = $sourceActionProperty.Value
        $sourceActionProperty.Remove()

        for ($index = 0; $index -lt $TargetRows.Count; $index++) {
            $targetVmId = $targetVmIds[$index]

            if ($index -eq 0) {
                $newActionName = $sourceActionName
            }
            else {
                $newActionName = "{0}-vm{1}" -f $sourceActionName, ($index + 1)
            }

            $baseActionName = $newActionName
            $counter = 1
            while ($null -ne $newDefinition.actions.PSObject.Properties[$newActionName]) {
                $newActionName = "{0}-{1}" -f $baseActionName, $counter
                $counter++
            }

            $newAction = New-TargetVmAction `
                -SourceAction $sourceAction `
                -SourceVmId $sourceVmId `
                -TargetVmId $targetVmId

            $newDefinition.actions |
                Add-Member -MemberType NoteProperty -Name $newActionName -Value $newAction -Force

            Write-Log "Added VM action '$newActionName' -> '$targetVmId'." "SUCCESS"
        }

        return $newDefinition
    }

    # ------------------------------------------------------------------------
    # MULTI SOURCE VM
    # ------------------------------------------------------------------------

    Write-Log ""
    Write-Log "Source contains multiple VMs. Using multi-VM migration mode." "INFO"

    if ($templateVmIds.Count -ne $TargetRows.Count) {
        throw @"
Multi-VM migration cannot continue safely.

Source/template Logic App:
$($TemplateLogicApp.name)

Source VM count:
$($templateVmIds.Count)

Target VM row count:
$($TargetRows.Count)

For a multi-VM source Logic App, the number of target VM rows must match
the number of source VM resource IDs.

Source VM IDs:
$($templateVmIds -join "`n")

Target VMs:
$(($TargetRows | ForEach-Object { "$($_.VmName) -> $($_.VmResourceId)" }) -join "`n")
"@
    }

    if ($vmActions.Count -eq 0) {
        throw @"
Multi-VM source Logic App contains VM resource IDs but no identifiable
VM-start actions.

Logic App:
$($TemplateLogicApp.name)

VM IDs:
$($templateVmIds -join "`n")

Cannot safely construct the target workflow.
"@
    }

    $sourceActionMap = @()
    foreach ($sourceVmId in $templateVmIds) {
        $selectedAction = Find-ActionForVm -Candidates $vmActions -VmResourceId $sourceVmId
        if (-not $selectedAction) {
            throw @"
Unable to identify a VM-start action for source VM:

$sourceVmId

Logic App:
$($TemplateLogicApp.name)

The script will not guess which action should be replaced.
"@
        }

        $sourceActionMap += [PSCustomObject]@{
            SourceVmId  = $sourceVmId
            ActionName  = $selectedAction.Name
            ActionPath  = $selectedAction.Path
            Action      = $selectedAction.Action
        }
    }

    Write-Log ""
    Write-Log "Source VM/action mapping:" "INFO"
    foreach ($mapping in $sourceActionMap) {
        Write-Log "  $($mapping.SourceVmId) -> $($mapping.ActionPath)" "DEBUG"
    }

    foreach ($mapping in $sourceActionMap) {
        if ($mapping.ActionPath -ne $mapping.ActionName) {
            throw @"
A multi-VM source Logic App contains a nested VM action.

Nested VM action:
$($mapping.ActionPath)

VM:
$($mapping.SourceVmId)

For production safety, multi-VM migration requires the VM-start actions
to be top-level actions.

No Logic App was created.
"@
        }
    }

    $newDefinition = Copy-Object -Object $definition

    for ($index = 0; $index -lt $TargetRows.Count; $index++) {
        $mapping    = $sourceActionMap[$index]
        $sourceVmId = $mapping.SourceVmId
        $targetVmId = $targetVmIds[$index]

        Write-Log ""
        Write-Log "Mapping VM [$($index + 1)]" "INFO"
        Write-Log "Source VM: $sourceVmId" "DEBUG"
        Write-Log "Target VM: $targetVmId" "DEBUG"
        Write-Log "Action: $($mapping.ActionName)" "DEBUG"

        $updatedAction = Replace-VmResourceIdSafe `
            -Object (Copy-Object -Object $mapping.Action) `
            -OldVmResourceId $sourceVmId `
            -NewVmResourceId $targetVmId

        $actionProperty = $newDefinition.actions.PSObject.Properties[$mapping.ActionName]
        if ($null -eq $actionProperty) {
            throw "Unable to locate top-level action '$($mapping.ActionName)' while building target."
        }
        $actionProperty.Value = $updatedAction
    }

    $finalVmIds = @(Get-VmResourceIdsFromDefinition -Definition $newDefinition)

    Write-Log ""
    Write-Log "Final workflow contains $($finalVmIds.Count) unique VM resource ID(s)." "INFO"
    foreach ($id in $finalVmIds) {
        Write-Log "Final VM ID: $id" "DEBUG"
    }

    foreach ($expected in $targetVmIds) {
        $found = $false
        foreach ($id in $finalVmIds) {
            if ($id.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw "Final workflow validation failed. Target VM is missing: $expected"
        }
    }

    Write-Log "Final VM definition validation successful." "SUCCESS"
    return $newDefinition
}

function Test-VmReplacement {

    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $true)]
        [string[]]$OldVmResourceIds,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedVmResourceIds
    )

    Write-Log "" 
    Write-Log "Validating final VM definition..." "DEBUG"

    $oldIds = @(
        $OldVmResourceIds |
            ForEach-Object { Normalize-VmResourceId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $expectedIds = @(
        $ExpectedVmResourceIds |
            ForEach-Object { Normalize-VmResourceId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($expectedIds.Count -eq 0) {
        throw "VM definition validation failed: expected target VM list is empty."
    }

    $duplicateExpected = @(
        $ExpectedVmResourceIds |
            ForEach-Object { Normalize-VmResourceId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Group-Object { $_.ToLowerInvariant() } |
            Where-Object Count -gt 1
    )

    if ($duplicateExpected.Count -gt 0) {
        throw "VM definition validation failed: duplicate target VM resource IDs were supplied: $($duplicateExpected.Name -join ', ')"
    }

    $actualVmIds = @(
        Get-VmResourceIdsFromDefinition -Definition $Definition |
            ForEach-Object { Normalize-VmResourceId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    Write-Log "Source VM count   : $($oldIds.Count)" "DEBUG"
    Write-Log "Expected VM count : $($expectedIds.Count)" "DEBUG"
    Write-Log "Actual VM count   : $($actualVmIds.Count)" "DEBUG"

    foreach ($id in $actualVmIds) {
        Write-Log "Actual VM: $id" "DEBUG"
    }

    # Exact set validation. This is correct for both:
    #   1) Logic App rename/move where source and target VM IDs are identical
    #   2) Actual VM replacement where source and target VM IDs differ.
    $missing = @()
    foreach ($expectedId in $expectedIds) {
        if (-not (@($actualVmIds | Where-Object {
            $_.Equals($expectedId, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0)) {
            $missing += $expectedId
        }
    }

    $unexpected = @()
    foreach ($actualId in $actualVmIds) {
        if (-not (@($expectedIds | Where-Object {
            $_.Equals($actualId, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0)) {
            $unexpected += $actualId
        }
    }

    if ($missing.Count -gt 0) {
        throw @"
VM definition validation failed.

EXPECTED VM RESOURCE ID(S) ARE MISSING:

$($missing -join "`n")
"@
    }

    if ($unexpected.Count -gt 0) {
        throw @"
VM definition validation failed.

UNEXPECTED VM RESOURCE ID(S) ARE PRESENT:

$($unexpected -join "`n")
"@
    }

    $sameVmSet = $true
    if ($oldIds.Count -ne $expectedIds.Count) {
        $sameVmSet = $false
    } else {
        foreach ($oldId in $oldIds) {
            if (-not (@($expectedIds | Where-Object {
                $_.Equals($oldId, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)) {
                $sameVmSet = $false
                break
            }
        }
    }

    if ($sameVmSet) {
        Write-Log "Source and target VM sets are identical. Old VM IDs are intentionally retained." "SUCCESS"
    } else {
        # For true VM replacement, source IDs that are not expected must not survive.
        foreach ($oldId in $oldIds) {
            $isExpected = @($expectedIds | Where-Object {
                $_.Equals($oldId, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0

            if (-not $isExpected) {
                $stillPresent = @($actualVmIds | Where-Object {
                    $_.Equals($oldId, [System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0

                if ($stillPresent) {
                    throw "VM replacement validation failed. Old VM resource ID is still present and is not part of the expected target set: $oldId"
                }
            }
        }
        Write-Log "VM replacement validation successful. Source and target VM sets differ as expected." "SUCCESS"
    }

    Write-Log "Exact target VM set validation successful." "SUCCESS"
    return $true
}

# ============================================================================
# CREATE LOGIC APP
# ============================================================================

function New-LogicApp {

    param(

        [Parameter(Mandatory = $true)]
        [string]$LogicAppName,

        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $false)]
        [object]$Parameters
    )

    $encodedName =
        [System.Uri]::EscapeDataString(
            $LogicAppName
        )

    $resourcePath =
        "/subscriptions/$AutomationSubscriptionId" +
        "/resourceGroups/$AutomationResourceGroup" +
        "/providers/Microsoft.Logic/workflows/$encodedName"

    $uri =
        New-AzureUri `
            -ResourcePath $resourcePath `
            -ApiVersion $LogicApiVersion

    $properties =
        [ordered]@{

            state =
                "Disabled"

            definition =
                $Definition
        }

    if ($null -ne $Parameters) {

        $properties.parameters =
            $Parameters
    }

    $body =
        [ordered]@{

            location =
                $AutomationLocation

            properties =
                $properties
        }

    Write-Log ""
    Write-Log `
        "Creating NEW Logic App: $LogicAppName"

    Write-Log `
        "NEW Logic App location: $AutomationLocation" `
        "INFO"

    return (
        Invoke-AzurePut `
            -Uri $uri `
            -Body $body
    )
}

# ============================================================================
# SET LOGIC APP STATE
# ============================================================================

function Set-LogicAppState {

    param(

        [Parameter(Mandatory = $true)]
        [string]$LogicAppName,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "Enabled",
            "Disabled"
        )]
        [string]$State
    )

    $existing =
        Get-LogicApp `
            -LogicAppName $LogicAppName

    if (-not $existing) {

        throw `
            "Logic App '$LogicAppName' does not exist."
    }

    $definition =
        Get-LogicAppDefinition `
            -LogicApp $existing

    $parameters =
        Get-LogicAppParameters `
            -LogicApp $existing

    $encodedName =
        [System.Uri]::EscapeDataString(
            $LogicAppName
        )

    $resourcePath =
        "/subscriptions/$AutomationSubscriptionId" +
        "/resourceGroups/$AutomationResourceGroup" +
        "/providers/Microsoft.Logic/workflows/$encodedName"

    $uri =
        New-AzureUri `
            -ResourcePath $resourcePath `
            -ApiVersion $LogicApiVersion

    $properties =
        [ordered]@{

            state =
                $State

            definition =
                $definition
        }

    if ($null -ne $parameters) {

        $properties.parameters =
            $parameters
    }

    $body =
        [ordered]@{

            location =
                $existing.location

            properties =
                $properties
        }

    Write-Log `
        "Setting Logic App '$LogicAppName' state to '$State'..."

    Invoke-AzurePut `
        -Uri $uri `
        -Body $body |
        Out-Null

    # ------------------------------------------------------------------------
    # Verify.
    # ------------------------------------------------------------------------

    $verify =
        Get-LogicApp `
            -LogicAppName $LogicAppName

    $actualState =
        Get-LogicAppState `
            -LogicApp $verify

    if (
        $actualState -ine $State
    ) {

        throw `
            "Failed to set Logic App '$LogicAppName' to '$State'. Actual state: $actualState"
    }

    Write-Log `
        "Logic App '$LogicAppName' is now $actualState." `
        "SUCCESS"
}

# ============================================================================
# CSV COLUMN VALIDATION
# ============================================================================

function Test-InventoryColumns {

    param(

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    if ($Rows.Count -eq 0) {

        throw "Inventory CSV contains no rows."
    }

    $requiredColumns = @(
        "ExistingLogicApp",
        "ExistingLogicAppId",
        "ExistingState",
        "VmName",
        "VmResourceId",
        "VmSubscriptionId",
        "VmResourceGroup",
        "ProposedLogicApp",
        "Role",
        "StartHHMM",
        "TimeZone",
        "Status"
    )

    $actualColumns =
        @(
            $Rows[0].PSObject.Properties.Name
        )

    foreach ($column in $requiredColumns) {

        if (
            $actualColumns -notcontains $column
        ) {

            throw `
                "Required CSV column '$column' is missing."
        }
    }

    Write-Log `
        "CSV column validation successful." `
        "SUCCESS"
}

# ============================================================================
# ROW VALIDATION
# ============================================================================

function Test-InventoryRow {

    param(

        [Parameter(Mandatory = $true)]
        [object]$Row
    )

    $errors = @()

    if (
        [string]::IsNullOrWhiteSpace(
            $Row.ExistingLogicApp
        )
    ) {

        $errors +=
            "ExistingLogicApp is empty"
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $Row.ProposedLogicApp
        )
    ) {

        $errors +=
            "ProposedLogicApp is empty"
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $Row.VmResourceId
        )
    ) {

        $errors +=
            "VmResourceId is empty"
    }
    elseif (
        -not (
            Test-IsVmResourceId `
                -Value ([string]$Row.VmResourceId)
        )
    ) {

        $errors +=
            "VmResourceId is not a valid Microsoft.Compute virtual machine resource ID"
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $Row.VmName
        )
    ) {

        $errors +=
            "VmName is empty"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Row.ExistingLogicAppId)) {
        $errors += "ExistingLogicAppId is empty"
    } elseif ([string]$Row.ExistingLogicAppId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Logic/workflows/[^/]+$') {
        $errors += "ExistingLogicAppId is not a valid Microsoft.Logic workflow resource ID"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Row.VmSubscriptionId)) {
        $errors += "VmSubscriptionId is empty"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Row.VmResourceGroup)) {
        $errors += "VmResourceGroup is empty"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Row.VmResourceId) -and
        (Test-IsVmResourceId -Value ([string]$Row.VmResourceId))) {
        $parts = ([string]$Row.VmResourceId).Trim('/') -split '/'
        if ($parts.Count -ge 8) {
            $ridSubscription = $parts[1]
            $ridResourceGroup = $parts[3]
            $ridVmName = $parts[7]

            if ($Row.VmSubscriptionId -and $ridSubscription -ine [string]$Row.VmSubscriptionId) {
                $errors += "VmSubscriptionId does not match VmResourceId"
            }
            if ($Row.VmResourceGroup -and $ridResourceGroup -ine [string]$Row.VmResourceGroup) {
                $errors += "VmResourceGroup does not match VmResourceId"
            }
            if ($Row.VmName -and $ridVmName -ine [string]$Row.VmName) {
                $errors += "VmName does not match VmResourceId"
            }
        }
    }

    if (
        $Row.Status -ne "Ready"
    ) {

        $errors +=
            "Status is '$($Row.Status)'"
    }

    if (
        $Row.Role -notin @(
            "db",
            "appweb"
        )
    ) {

        $errors +=
            "Role '$($Row.Role)' is not db/appweb"
    }

    return @($errors)
}

# ============================================================================
# TEST SCOPE
# ============================================================================

function Select-TestRows {

    param(

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $selected =
        @(
            $Rows
        )

    if (
        -not [string]::IsNullOrWhiteSpace(
            $TestResourceGroup
        )
    ) {

        Write-Log ""
        Write-Log `
            "TEST RESOURCE GROUP: $TestResourceGroup" `
            "WARN"

        $selected =
            @(
                $selected |
                    Where-Object {
                        $_.VmResourceGroup -ieq $TestResourceGroup
                    }
            )
    }

    if (
        $TestVmCount -gt 0
    ) {

        Write-Log `
            "TEST VM COUNT: $TestVmCount" `
            "WARN"

        $selected =
            @(
                $selected |
                    Select-Object `
                        -First $TestVmCount
            )
    }

    return @($selected)
}

# ============================================================================
# TARGET COLLISION VALIDATION
# ============================================================================

function Test-TargetCollisions {

    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    Write-Log ""
    Write-Log "Checking ProposedLogicApp targets..."

    $groups = @($Rows | Group-Object ProposedLogicApp)

    foreach ($group in $groups) {
        if ([string]::IsNullOrWhiteSpace($group.Name)) {
            throw "A row has an empty ProposedLogicApp."
        }

        Write-Log "Target: $($group.Name) | Rows: $($group.Count)" "DEBUG"

        $times = @($group.Group | Select-Object -ExpandProperty StartHHMM -Unique)
        if ($times.Count -gt 1) {
            throw "Target '$($group.Name)' has multiple schedules: $($times -join ', ')"
        }

        $timeZones = @($group.Group | Select-Object -ExpandProperty TimeZone -Unique)
        if ($timeZones.Count -gt 1) {
            throw "Target '$($group.Name)' has multiple time zones."
        }

        $duplicateVmGroups = @(
            $group.Group |
                ForEach-Object { Normalize-VmResourceId -ResourceId ([string]$_.VmResourceId) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Group-Object { $_.ToLowerInvariant() } |
                Where-Object Count -gt 1
        )

        if ($duplicateVmGroups.Count -gt 0) {
            throw "Target '$($group.Name)' contains duplicate target VM resource ID(s): $($duplicateVmGroups.Name -join ', ')"
        }

        $sourceApps = @(
            $group.Group |
                Select-Object -ExpandProperty ExistingLogicApp -Unique |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($sourceApps.Count -gt 1) {
            throw @"
Target '$($group.Name)' maps multiple ExistingLogicApps:

$($sourceApps -join "`n")

This version of the script does not merge multiple Logic App definitions into
one target. Use one ExistingLogicApp per ProposedLogicApp, or implement an
explicit definition-merge strategy before proceeding.
"@
        }
    }

    Write-Log "Target validation successful." "SUCCESS"
}

# ============================================================================
# VALIDATE MODE
# ============================================================================

function Invoke-Validate {

    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "VALIDATION MODE"
    Write-Log "============================================================"

    Test-TargetCollisions -Rows $Rows

    $groups = @($Rows | Group-Object ProposedLogicApp)
    $validationResults = @()
    $failed = $false

    foreach ($group in $groups) {
        $targetName = [string]$group.Name
        $targetRows = @($group.Group)

        Write-Log "" 
        Write-Log "Pre-flight target: $targetName" "INFO"

        try {
            if (Test-LogicAppExists -LogicAppName $targetName) {
                Write-Log "TARGET ALREADY EXISTS: $targetName - it will NOT be overwritten." "WARN"
            }

            $sourceRow = $targetRows[0]
            $source = Get-LogicApp -LogicAppName ([string]$sourceRow.ExistingLogicApp)
            if (-not $source) {
                throw "Existing Logic App '$($sourceRow.ExistingLogicApp)' could not be retrieved."
            }

            $actualSourceId = [string]$source.id
            $expectedSourceId = [string]$sourceRow.ExistingLogicAppId
            if ($actualSourceId -ine $expectedSourceId) {
                throw "ExistingLogicAppId mismatch for '$($sourceRow.ExistingLogicApp)'. CSV='$expectedSourceId' Azure='$actualSourceId'."
            }

            $definition = Get-LogicAppDefinition -LogicApp $source
            $newDefinition = New-TargetDefinition -TemplateLogicApp $source -TargetRows $targetRows

            $sourceVmIds = @(Get-VmResourceIdsFromDefinition -Definition $definition)
            $targetVmIds = @($targetRows | ForEach-Object { Normalize-VmResourceId -ResourceId ([string]$_.VmResourceId) })

            Test-VmReplacement `
                -Definition $newDefinition `
                -OldVmResourceIds $sourceVmIds `
                -ExpectedVmResourceIds $targetVmIds | Out-Null

            $validationResults += [PSCustomObject]@{
                ProposedLogicApp = $targetName
                ExistingLogicApp = $source.name
                VmCount = $targetRows.Count
                Result = if (Test-LogicAppExists -LogicAppName $targetName) { "READY_TARGET_EXISTS" } else { "READY" }
                Error = ""
            }

            Write-Log "Pre-flight validation successful: $targetName" "SUCCESS"
        }
        catch {
            $failed = $true
            Write-Log "Pre-flight validation FAILED: $targetName" "ERROR"
            Write-Log (Get-ExceptionDetails -ErrorRecord $_) "ERROR"

            $validationResults += [PSCustomObject]@{
                ProposedLogicApp = $targetName
                ExistingLogicApp = ($targetRows | Select-Object -ExpandProperty ExistingLogicApp -Unique) -join ";"
                VmCount = $targetRows.Count
                Result = "FAILED"
                Error = $_.Exception.Message
            }
        }
    }

    $validationResults | Export-Csv -Path $ResultsCsv -NoTypeInformation -Encoding UTF8
    Write-Log "Validation results: $ResultsCsv" "SUCCESS"

    if ($failed) {
        throw "Validation failed for one or more target Logic Apps. See $ResultsCsv"
    }
}

# ============================================================================
# TARGET MIGRATION
# ============================================================================

function Invoke-TargetMigration {

    param(

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $targetName =
        [string]$Rows[0].ProposedLogicApp

    $oldLogicApps =
        @(
            $Rows |
                Select-Object `
                    -ExpandProperty ExistingLogicApp `
                    -Unique
        )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "TARGET: $targetName"
    Write-Log "============================================================"

    Write-Log `
        "VM count: $($Rows.Count)"

    Write-Log `
        "VMs: $(
            (
                $Rows |
                    Select-Object `
                        -ExpandProperty VmName
            ) -join ', '
        )"

    Write-Log `
        "Source Logic Apps: $($oldLogicApps -join ', ')"

    # ------------------------------------------------------------------------
    # TARGET MUST NOT EXIST
    # ------------------------------------------------------------------------

    if (
        Test-LogicAppExists `
            -LogicAppName $targetName
    ) {

        Write-Log `
            "Target '$targetName' already exists. SKIPPING. Existing target will NOT be overwritten." `
            "WARN"

        return [PSCustomObject]@{

            ProposedLogicApp =
                $targetName

            ExistingLogicApps =
                ($oldLogicApps -join ";")

            VmCount =
                $Rows.Count

            VMs =
                (
                    $Rows |
                        Select-Object `
                            -ExpandProperty VmName
                ) -join ";"

            Result =
                "SKIPPED_TARGET_EXISTS"

            Backup =
                ""

            Error =
                ""
        }
    }

    # ------------------------------------------------------------------------
    # TEMPLATE
    # ------------------------------------------------------------------------

    $templateLogicApp =
        Get-TemplateForTarget `
            -Rows $Rows

    if (-not $templateLogicApp) {

        throw `
            "Unable to retrieve template Logic App."
    }

    Write-Log `
        "Template Logic App: $($templateLogicApp.name)"

    Write-Log `
        "Template state: $(Get-LogicAppState -LogicApp $templateLogicApp)"

    Write-Log `
        "Template location: $($templateLogicApp.location)" `
        "INFO"

    # ------------------------------------------------------------------------
    # SOURCE VALIDATION + BACKUP
    # ------------------------------------------------------------------------

    $backupFiles = @()

    foreach ($oldName in $oldLogicApps) {

        $oldApp =
            Get-LogicApp `
                -LogicAppName $oldName

        if (-not $oldApp) {
            throw "Existing Logic App '$oldName' could not be retrieved."
        }

        $matchingRows = @($Rows | Where-Object { $_.ExistingLogicApp -ieq $oldName })
        foreach ($row in $matchingRows) {
            if ([string]$oldApp.id -ine [string]$row.ExistingLogicAppId) {
                throw "ExistingLogicAppId mismatch for '$oldName'. CSV='$($row.ExistingLogicAppId)' Azure='$($oldApp.id)'."
            }
        }

        if (-not $WhatIfPreference) {
            $backup = Backup-LogicApp -LogicApp $oldApp -Folder $BackupFolder
            $backupFiles += $backup
        } else {
            Write-Log "WHATIF: Backup skipped for '$oldName'." "WARN"
        }
    }

    # ------------------------------------------------------------------------
    # SOURCE VM IDS
    # ------------------------------------------------------------------------

    $sourceDefinition =
        Get-LogicAppDefinition `
            -LogicApp $templateLogicApp

    $sourceVmIds =
        @(
            Get-VmResourceIdsFromDefinition `
                -Definition $sourceDefinition
        )

    if ($sourceVmIds.Count -eq 0) {

        throw `
            "Template Logic App '$($templateLogicApp.name)' contains no Microsoft.Compute VM resource IDs."
    }

    Write-Log ""
    Write-Log `
        "Source VM count: $($sourceVmIds.Count)" `
        "INFO"

    # ------------------------------------------------------------------------
    # TARGET VM IDS
    # ------------------------------------------------------------------------

    $expectedTargetVmIds =
        @(
            $Rows |
                ForEach-Object {

                    Normalize-VmResourceId `
                        -ResourceId ([string]$_.VmResourceId)
                }
        )

    # Reject duplicate target VM IDs before building the definition.
    $targetVmDuplicateGroups = @(
        $expectedTargetVmIds |
            Group-Object { $_.ToLowerInvariant() } |
            Where-Object Count -gt 1
    )

    if ($targetVmDuplicateGroups.Count -gt 0) {
        throw "Target '$targetName' contains duplicate VM resource IDs: $($targetVmDuplicateGroups.Name -join ', ')"
    }

    # ------------------------------------------------------------------------
    # BUILD DEFINITION
    # ------------------------------------------------------------------------

    Write-Log `
        "Building new workflow definition..."

    $newDefinition =
        New-TargetDefinition `
            -TemplateLogicApp $templateLogicApp `
            -TargetRows @($Rows)

    # ------------------------------------------------------------------------
    # PRE-CREATE VALIDATION
    # ------------------------------------------------------------------------

    Write-Log ""
    Write-Log `
        "Running pre-create VM replacement validation..."

    Test-VmReplacement `
        -Definition $newDefinition `
        -OldVmResourceIds $sourceVmIds `
        -ExpectedVmResourceIds $expectedTargetVmIds |
        Out-Null

    Write-Log `
        "Pre-create VM replacement validation successful." `
        "SUCCESS"

    # ------------------------------------------------------------------------
    # WHATIF
    # ------------------------------------------------------------------------

    if ($WhatIfPreference) {

        Write-Log ""
        Write-Log `
            "WHATIF: Would create '$targetName' in '$AutomationLocation'." `
            "WARN"

        Write-Log `
            "WHATIF: Would enable '$targetName'." `
            "WARN"

        if ($DisableOld) {

            foreach ($oldName in $oldLogicApps) {

                if (
                    $oldName -ieq $targetName
                ) {

                    continue
                }

                Write-Log `
                    "WHATIF: Would disable '$oldName'." `
                    "WARN"
            }
        }
        else {

            Write-Log `
                "Old Logic Apps will NOT be disabled because -DisableOld was not specified." `
                "WARN"
        }

        return [PSCustomObject]@{

            ProposedLogicApp =
                $targetName

            ExistingLogicApps =
                ($oldLogicApps -join ";")

            VmCount =
                $Rows.Count

            VMs =
                (
                    $Rows |
                        Select-Object `
                            -ExpandProperty VmName
                ) -join ";"

            Result =
                "WhatIf"

            Backup =
                ($backupFiles -join ";")

            Error =
                ""
        }
    }

    # ------------------------------------------------------------------------
    # CREATE
    # ------------------------------------------------------------------------

    try {

        Write-Log ""
        Write-Log `
            "Creating NEW Logic App '$targetName' in West Europe..." `
            "INFO"

        $newApp =
            New-LogicApp `
                -LogicAppName $targetName `
                -Definition $newDefinition `
                -Parameters (
                    Get-LogicAppParameters `
                        -LogicApp $templateLogicApp
                )

        if (-not $newApp) {

            throw `
                "Create returned no Logic App object."
        }

        Write-Log `
            "NEW Logic App created: $targetName" `
            "SUCCESS"

        # --------------------------------------------------------------------
        # VERIFY
        # --------------------------------------------------------------------

        $verify =
            Get-LogicApp `
                -LogicAppName $targetName

        if (-not $verify) {

            throw `
                "New Logic App '$targetName' could not be retrieved after creation."
        }

        # --------------------------------------------------------------------
        # VERIFY LOCATION
        # --------------------------------------------------------------------

        if (
            [string]::IsNullOrWhiteSpace(
                [string]$verify.location
            )
        ) {

            throw `
                "New Logic App '$targetName' returned no location."
        }

        if (
            $verify.location -ine $AutomationLocation
        ) {

            throw `
                "New Logic App '$targetName' was created in unexpected location '$($verify.location)'. Expected '$AutomationLocation'."
        }

        Write-Log `
            "Verified Logic App location: $($verify.location)" `
            "SUCCESS"

        # --------------------------------------------------------------------
        # VERIFY DEFINITION
        # --------------------------------------------------------------------

        $verifyDefinition =
            Get-LogicAppDefinition `
                -LogicApp $verify

        # --------------------------------------------------------------------
        # VERIFY VM IDS
        # --------------------------------------------------------------------

        $newVmIds =
            @(
                Get-VmResourceIdsFromDefinition `
                    -Definition $verifyDefinition
            )

        Write-Log `
            "New Logic App contains $($newVmIds.Count) unique VM resource ID(s)." `
            "INFO"

        foreach ($id in $newVmIds) {

            Write-Log `
                "Verified VM ID: $id" `
                "DEBUG"
        }

        # --------------------------------------------------------------------
        # OLD IDS MUST BE GONE + NEW IDS MUST EXIST
        # --------------------------------------------------------------------

        Test-VmReplacement `
            -Definition $verifyDefinition `
            -OldVmResourceIds $sourceVmIds `
            -ExpectedVmResourceIds $expectedTargetVmIds |
            Out-Null

        Write-Log `
            "Post-create VM replacement validation successful." `
            "SUCCESS"

        # --------------------------------------------------------------------
        # ENABLE NEW
        # --------------------------------------------------------------------

        Set-LogicAppState `
            -LogicAppName $targetName `
            -State Enabled

        Write-Log `
            "NEW Logic App '$targetName' is ENABLED." `
            "SUCCESS"

        # --------------------------------------------------------------------
        # DISABLE OLD
        # --------------------------------------------------------------------

        if ($DisableOld) {

            Write-Log ""
            Write-Log "Disabling OLD Logic Apps..." "INFO"

            $disabledOldApps = @()

            foreach ($oldName in $oldLogicApps) {

                if (
                    $oldName -ieq $targetName
                ) {

                    Write-Log `
                        "Old and new names are identical. Skipping disable." `
                        "WARN"

                    continue
                }

                Write-Log `
                    "Disabling OLD Logic App: $oldName"

                Set-LogicAppState `
                    -LogicAppName $oldName `
                    -State Disabled

                $disabledOldApps += $oldName

                Write-Log `
                    "OLD Logic App disabled: $oldName" `
                    "SUCCESS"
            }
        }
        else {

            Write-Log `
                "Old Logic Apps were NOT disabled because -DisableOld was not specified." `
                "WARN"
        }

        Write-Log ""
        Write-Log `
            "Migration completed successfully: $targetName" `
            "SUCCESS"

        return [PSCustomObject]@{

            ProposedLogicApp =
                $targetName

            ExistingLogicApps =
                ($oldLogicApps -join ";")

            VmCount =
                $Rows.Count

            VMs =
                (
                    $Rows |
                        Select-Object `
                            -ExpandProperty VmName
                ) -join ";"

            Result =
                "Success"

            Backup =
                ($backupFiles -join ";")

            Error =
                ""
        }
    }
    catch {

        Write-Log `
            "Migration failed for '$targetName'." `
            "ERROR"

        # If old apps were partially disabled, restore them before returning
        # a failed result. The new target is also disabled if it was enabled.
        try {
            if ($null -ne $disabledOldApps) {
                foreach ($rollbackName in @($disabledOldApps)) {
                    try {
                        Set-LogicAppState -LogicAppName $rollbackName -State Enabled
                        Write-Log "Rollback: re-enabled old Logic App '$rollbackName'." "WARN"
                    } catch {
                        Write-Log "Rollback FAILED for old Logic App '$rollbackName': $($_.Exception.Message)" "ERROR"
                    }
                }
            }

            if ($newApp) {
                try {
                    $newCurrent = Get-LogicApp -LogicAppName $targetName
                    if ((Get-LogicAppState -LogicApp $newCurrent) -ieq "Enabled") {
                        Set-LogicAppState -LogicAppName $targetName -State Disabled
                        Write-Log "Rollback: disabled new Logic App '$targetName'." "WARN"
                    }
                } catch {
                    Write-Log "Rollback FAILED for new Logic App '$targetName': $($_.Exception.Message)" "ERROR"
                }
            }
        } catch {
            Write-Log "Rollback processing encountered an unexpected error: $($_.Exception.Message)" "ERROR"
        }

        Write-Log `
            (Get-ExceptionDetails -ErrorRecord $_) `
            "ERROR"

        Write-Log `
            "IMPORTANT: Existing Logic App(s) were NOT intentionally disabled after failure." `
            "WARN"

        return [PSCustomObject]@{

            ProposedLogicApp =
                $targetName

            ExistingLogicApps =
                ($oldLogicApps -join ";")

            VmCount =
                $Rows.Count

            VMs =
                (
                    $Rows |
                        Select-Object `
                            -ExpandProperty VmName
                ) -join ";"

            Result =
                "FAILED"

            Backup =
                ($backupFiles -join ";")

            Error =
                $_.Exception.Message
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

try {

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "BAB VM START LOGIC APP RENAME / CREATE"
    Write-Log "============================================================"

    Write-Log `
        "Mode: $Mode"

    Write-Log `
        "Inventory CSV: $InventoryCsv"

    Write-Log `
        "Backup folder: $BackupFolder"

    Write-Log `
        "Results CSV: $ResultsCsv"

    Write-Log `
        "Automation subscription: $AutomationSubscriptionId"

    Write-Log `
        "Automation RG: $AutomationResourceGroup"

    Write-Log `
        "NEW Logic App location: $AutomationLocation"

    Write-Log `
        "Logic API version: $LogicApiVersion"

    Write-Log `
        "Disable old Logic Apps: $DisableOld"

    if ($WhatIfPreference) {

        Write-Log `
            "WHATIF MODE ENABLED - NO AZURE CHANGES WILL BE MADE." `
            "WARN"
    }

    # ------------------------------------------------------------------------
    # Azure
    # ------------------------------------------------------------------------

    Initialize-Azure

    # ------------------------------------------------------------------------
    # OUTPUT DIRECTORIES
    # ------------------------------------------------------------------------

    $resultsParent = Split-Path -Parent $ResultsCsv
    if (-not [string]::IsNullOrWhiteSpace($resultsParent)) {
        New-Item -ItemType Directory -Path $resultsParent -Force | Out-Null
    }

    # ------------------------------------------------------------------------
    # CSV
    # ------------------------------------------------------------------------

    if (
        -not (Test-Path $InventoryCsv)
    ) {

        throw `
            "Inventory CSV not found: $InventoryCsv"
    }

    Write-Log `
        "Reading inventory CSV..."

    $allRows =
        @(
            Import-Csv `
                -Path $InventoryCsv
        )

    Write-Log `
        "CSV rows loaded: $($allRows.Count)" `
        "SUCCESS"

    Test-InventoryColumns `
        -Rows $allRows

    # ------------------------------------------------------------------------
    # READY
    # ------------------------------------------------------------------------

    $readyRows =
        @(
            $allRows |
                Where-Object {
                    $_.Status -eq "Ready"
                }
        )

    Write-Log `
        "Ready rows: $($readyRows.Count)"

    if (
        $readyRows.Count -eq 0
    ) {

        throw `
            "No CSV rows have Status=Ready."
    }

    # ------------------------------------------------------------------------
    # TEST FILTER
    # ------------------------------------------------------------------------

    $rows =
        Select-TestRows `
            -Rows $readyRows

    if (
        $rows.Count -eq 0
    ) {

        throw `
            "No rows remain after test filters."
    }

    Write-Log ""
    Write-Log `
        "Rows selected for operation: $($rows.Count)" `
        "SUCCESS"

    # ------------------------------------------------------------------------
    # ROW VALIDATION
    # ------------------------------------------------------------------------

    foreach ($row in $rows) {

        $errors =
            @(
                Test-InventoryRow `
                    -Row $row
            )

        if ($errors.Count -gt 0) {

            throw `
                "CSV row validation failed for '$($row.ProposedLogicApp)': $($errors -join '; ')"
        }
    }

    Test-TargetCollisions `
        -Rows $rows

    # ------------------------------------------------------------------------
    # VALIDATE
    # ------------------------------------------------------------------------

    if (
        $Mode -eq "Validate"
    ) {

        Invoke-Validate `
            -Rows $rows

        Write-Log ""
        Write-Log `
            "Validation completed." `
            "SUCCESS"

        exit 0
    }

    # ------------------------------------------------------------------------
    # RENAME / CREATE
    # ------------------------------------------------------------------------

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "RENAME / CREATE MODE"
    Write-Log "============================================================"

    $targetGroups =
        @(
            $rows |
                Group-Object `
                    ProposedLogicApp
        )

    Write-Log `
        "Target Logic Apps to process: $($targetGroups.Count)"

    $results = @()

    foreach ($group in $targetGroups) {

        try {

            $result =
                Invoke-TargetMigration `
                    -Rows @($group.Group)

            if ($null -ne $result) {

                $results +=
                    $result
            }
        }
        catch {

            Write-Log `
                "Unexpected target processing error for '$($group.Name)'." `
                "ERROR"

            Write-Log `
                (Get-ExceptionDetails -ErrorRecord $_) `
                "ERROR"

            $results +=
                [PSCustomObject]@{

                    ProposedLogicApp =
                        $group.Name

                    ExistingLogicApps =
                        (
                            $group.Group |
                                Select-Object `
                                    -ExpandProperty ExistingLogicApp `
                                    -Unique
                        ) -join ";"

                    VmCount =
                        $group.Count

                    VMs =
                        (
                            $group.Group |
                                Select-Object `
                                    -ExpandProperty VmName
                        ) -join ";"

                    Result =
                        "FAILED"

                    Backup =
                        ""

                    Error =
                        $_.Exception.Message
                }
        }
    }

    # ------------------------------------------------------------------------
    # RESULTS
    # ------------------------------------------------------------------------

    $results |
        Export-Csv `
            -Path $ResultsCsv `
            -NoTypeInformation `
            -Encoding UTF8

    # ------------------------------------------------------------------------
    # SUMMARY
    # ------------------------------------------------------------------------

    $successCount =
        @(
            $results |
                Where-Object {
                    $_.Result -eq "Success"
                }
        ).Count

    $failedCount =
        @(
            $results |
                Where-Object {
                    $_.Result -eq "FAILED"
                }
        ).Count

    $skippedCount =
        @(
            $results |
                Where-Object {
                    $_.Result -eq "SKIPPED_TARGET_EXISTS"
                }
        ).Count

    $whatIfCount =
        @(
            $results |
                Where-Object {
                    $_.Result -eq "WhatIf"
                }
        ).Count

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "FINAL SUMMARY"
    Write-Log "============================================================"

    Write-Log `
        "Targets processed : $($results.Count)"

    Write-Log `
        "Successful         : $successCount" `
        "SUCCESS"

    Write-Log `
        "Failed             : $failedCount" `
        $(if ($failedCount -gt 0) { "ERROR" } else { "INFO" })

    Write-Log `
        "Skipped            : $skippedCount"

    Write-Log `
        "WhatIf             : $whatIfCount"

    Write-Log `
        "Results CSV        : $ResultsCsv"

    Write-Log ""
    Write-Log `
        "Script completed."
}
catch {

    Write-Log ""
    Write-Log `
        "FATAL ERROR: $($_.Exception.Message)" `
        "ERROR"

    Write-Log `
        (Get-ExceptionDetails -ErrorRecord $_) `
        "ERROR"

    throw

    
}