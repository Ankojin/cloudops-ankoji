# ============================================================
# DCR UPDATE - EXISTING DCR
# ============================================================

$ErrorActionPreference = "Stop"

$ruleName        = "msvmi-bab-sit-vm-monitoring-dcr"
$resourceGroup   = "bab-sit-wrkspace-swec-rg-01"
$subscriptionId  = "e48414cd-f96d-4414-ae9e-da7fec844f77"

$streamName      = "Microsoft-InsightsMetrics"
$destinationName = "VMInsightsPerf-Logs-Dest"

# Use the API version shown in Azure Portal / supported DCR API
$apiVersion = "2023-03-11"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " EXISTING DCR UPDATE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# 1. Set subscription
# ============================================================

Write-Host "[1/6] Setting Azure subscription..." -ForegroundColor Cyan

az account set --subscription $subscriptionId

if ($LASTEXITCODE -ne 0) {
    throw "Failed to select subscription: $subscriptionId"
}

Write-Host "[OK] Subscription selected." -ForegroundColor Green

# ============================================================
# 2. Build ARM URL
# ============================================================

$resourcePath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/dataCollectionRules/$ruleName"

$armUrl = "https://management.azure.com$resourcePath" + "?api-version=$apiVersion"

Write-Host ""
Write-Host "[2/6] ARM URL:" -ForegroundColor Cyan
Write-Host $armUrl -ForegroundColor Gray

# IMPORTANT:
# Verify that api-version is actually present
if ($armUrl -notmatch "\?api-version=") {
    throw "ARM URL does not contain api-version."
}

Write-Host "[OK] api-version detected: $apiVersion" -ForegroundColor Green

# ============================================================
# 3. GET existing DCR
# ============================================================

Write-Host ""
Write-Host "[3/6] Reading existing DCR..." -ForegroundColor Cyan

$dcrJson = az rest `
    --method GET `
    --url "$armUrl" `
    --only-show-errors

if ($LASTEXITCODE -ne 0) {
    throw "Failed to read DCR."
}

if ([string]::IsNullOrWhiteSpace($dcrJson)) {
    throw "Azure returned an empty DCR response."
}

$dcr = $dcrJson | ConvertFrom-Json

Write-Host "[OK] Existing DCR found." -ForegroundColor Green
Write-Host "    Name     : $($dcr.name)" -ForegroundColor Gray
Write-Host "    Location : $($dcr.location)" -ForegroundColor Gray
Write-Host ""

# ============================================================
# 4. Backup existing DCR
# ============================================================

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$backupFile = ".\${ruleName}_backup_$timestamp.json"

$dcrJson |
    Out-File -FilePath $backupFile -Encoding UTF8

Write-Host "[4/6] Backup created:" -ForegroundColor Cyan
Write-Host "      $backupFile" -ForegroundColor Gray

# ============================================================
# 5. Modify dataFlows
# ============================================================

Write-Host ""
Write-Host "[5/6] Checking existing dataFlows..." -ForegroundColor Cyan

if ($null -eq $dcr.properties.dataFlows) {

    $dcr.properties |
        Add-Member `
            -MemberType NoteProperty `
            -Name "dataFlows" `
            -Value @()
}

$dataFlows = @($dcr.properties.dataFlows)

# Find existing Microsoft-InsightsMetrics flow
$existingFlow = $dataFlows |
    Where-Object {
        @($_.streams) -contains $streamName
    } |
    Select-Object -First 1

if ($existingFlow) {

    Write-Host "[FOUND] Existing Microsoft-InsightsMetrics flow." -ForegroundColor Green

    $existingDestinations = @($existingFlow.destinations)

    if ($existingDestinations -contains $destinationName) {

        Write-Host "[OK] Destination already exists:" -ForegroundColor Green
        Write-Host "     $destinationName" -ForegroundColor Gray

    }
    else {

        Write-Host "[UPDATE] Adding destination:" -ForegroundColor Yellow
        Write-Host "         $destinationName" -ForegroundColor White

        $existingFlow.destinations = @(
            $existingDestinations + $destinationName
        )
    }

}
else {

    Write-Host "[INFO] Microsoft-InsightsMetrics flow does not exist." -ForegroundColor Yellow
    Write-Host "[INFO] Creating required dataFlow..." -ForegroundColor Yellow

    $newFlow = [PSCustomObject]@{
        streams = @(
            $streamName
        )

        destinations = @(
            $destinationName
        )
    }

    $dcr.properties.dataFlows = @(
        $dataFlows + $newFlow
    )

    Write-Host "[OK] New dataFlow prepared." -ForegroundColor Green
}

# ============================================================
# Show target configuration
# ============================================================

Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host " TARGET DATA FLOW" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

$targetFlow = @($dcr.properties.dataFlows) |
    Where-Object {
        @($_.streams) -contains $streamName
    } |
    Select-Object -First 1

$targetFlow |
    ConvertTo-Json -Depth 20

Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

# ============================================================
# Build COMPLETE PUT payload
# ============================================================

# Do NOT send the complete GET response.
# Only send properties required by the DCR PUT API.

$putPayload = [ordered]@{
    location = $dcr.location
    properties = $dcr.properties
}

if ($dcr.kind) {
    $putPayload.kind = $dcr.kind
}

if ($dcr.identity) {
    $putPayload.identity = $dcr.identity
}

if ($dcr.tags) {
    $putPayload.tags = $dcr.tags
}

$putBody = $putPayload |
    ConvertTo-Json -Depth 100

$payloadFile = ".\${ruleName}_update_payload.json"

$putBody |
    Out-File -FilePath $payloadFile -Encoding UTF8

Write-Host ""
Write-Host "Update payload saved:" -ForegroundColor Gray
Write-Host "  $payloadFile" -ForegroundColor Gray

# ============================================================
# APPLY PUT
# ============================================================

Write-Host ""
Write-Host "Applying update to EXISTING DCR..." -ForegroundColor Cyan

$updateResult = az rest `
    --method PUT `
    --url "$armUrl" `
    --headers "Content-Type=application/json" `
    --body "@$payloadFile" `
    --only-show-errors

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host "[FAILED] DCR update failed." -ForegroundColor Red

    if ($updateResult) {
        Write-Host $updateResult -ForegroundColor Red
    }

    throw "DCR update failed."
}

Write-Host "[SUCCESS] Existing DCR updated." -ForegroundColor Green

# ============================================================
# 6. VERIFY
# ============================================================

Write-Host ""
Write-Host "[6/6] Verifying DCR..." -ForegroundColor Cyan

$verifyJson = az rest `
    --method GET `
    --url "$armUrl" `
    --only-show-errors

if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify DCR after update."
}

$verifyDcr = $verifyJson | ConvertFrom-Json

$verifiedFlow = @($verifyDcr.properties.dataFlows) |
    Where-Object {
        @($_.streams) -contains $streamName -and
        @($_.destinations) -contains $destinationName
    } |
    Select-Object -First 1

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " VERIFICATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if ($verifiedFlow) {

    Write-Host ""
    Write-Host "[SUCCESS] Required dataFlow is present." -ForegroundColor Green
    Write-Host ""

    $verifiedFlow |
        ConvertTo-Json -Depth 20

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " DCR UPDATE SUCCESSFUL" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green

}
else {

    Write-Host "[FAILED] Required dataFlow was not found." -ForegroundColor Red

    Write-Host ""
    Write-Host "Current dataFlows:" -ForegroundColor Yellow

    $verifyDcr.properties.dataFlows |
        ConvertTo-Json -Depth 20

    throw "Verification failed."
}