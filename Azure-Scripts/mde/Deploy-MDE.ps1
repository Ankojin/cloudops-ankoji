# Deploy-MDE-BulkFromCSV-AutoOS-SwedenCentral.ps1
# ==============================================================
# Bulk MDE Deployment from CSV using ARM
# Auto-detect OS directly from Azure (handles SIG/custom images)
# Logs success/failure + unsupported OS
# ARM deployment location = Sweden Central
# ==============================================================

$csvPath         = ".\vmList.csv"
$templatePath    = ".\Deploy-mde.json"
$logCsv          = ".\Deployment-Results.csv"
$unsupportedCsv  = ".\Unsupported-OS-Report.csv"
$deploymentLocation = "swedencentral"   # <── YOU REQUESTED THIS REGION

Write-Host "Importing VM list from $csvPath ..." -ForegroundColor Cyan
$csv = Import-Csv $csvPath

$validVMs = @()
$unsupported = @()

foreach ($row in $csv) {

    $vmName = $row.vmName.Trim()
    $rgName = $row.resourceGroup.Trim()
    $csvLocation = if ($row.location) { $row.location.Trim() } else { $null }

    Write-Host "`nChecking VM: $vmName in $rgName ..." -ForegroundColor Yellow

    # Get VM from Azure
    try {
        $vm = Get-AzVM -Name $vmName -ResourceGroupName $rgName -ErrorAction Stop
    }
    catch {
        Write-Host " - VM not found in Azure. Logging as unsupported." -ForegroundColor Red
        $unsupported += [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rgName
            Location      = $csvLocation
            DetectedOS    = "NotFound"
            Reason        = "VM not found"
        }
        continue
    }

    # Prefer VM location if Azure returns it
    $vmLocation = if ($vm.Location) { $vm.Location } else { $csvLocation }

    # ==============================================================
    #  RELIABLE OS DETECTION
    # ==============================================================

    $osType = $null
    $osVersion = $null

    # 1) Primary: OsDisk.OsType
    if ($vm.StorageProfile -and $vm.StorageProfile.OsDisk -and $vm.StorageProfile.OsDisk.OsType) {
        $osType = $vm.StorageProfile.OsDisk.OsType
    }

    # 2) Secondary: OSProfile
    if (-not $osType -and $vm.OSProfile) {
        if ($vm.OSProfile.WindowsConfiguration) { $osType = "Windows" }
        elseif ($vm.OSProfile.LinuxConfiguration) { $osType = "Linux" }
    }

    # 3) Tertiary: InstanceView (super reliable for SIG/custom)
    if (-not $osType) {
        try {
            $instanceVm = Get-AzVM -ResourceGroupName $rgName -Name $vmName -Status -ErrorAction Stop

            if ($instanceVm.OSName) {
                if ($instanceVm.OSName -match "windows") { $osType = "Windows" }
                elseif ($instanceVm.OSName -match "linux") { $osType = "Linux" }

                $osVersion = $instanceVm.OSName
            }
        }
        catch { }
    }

    # 4) Last resort: ImageReference
    $imageOffer = $null
    $imageSku = $null
    if ($vm.StorageProfile -and $vm.StorageProfile.ImageReference) {
        $imageOffer = $vm.StorageProfile.ImageReference.Offer
        $imageSku   = $vm.StorageProfile.ImageReference.Sku
    }

    if (-not $osType -and $imageOffer) {
        if ($imageOffer -imatch "Windows") { $osType = "Windows" }
        if ($imageOffer -imatch "ubuntu|centos|rhel|debian|oracle") { $osType = "Linux" }
    }

    # If STILL unknown → unsupported
    if (-not $osType) {
        Write-Host " - Unable to determine OS (OsDisk/OSProfile/InstanceView/image none available)." -ForegroundColor Red
        $unsupported += [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rgName
            Location      = $vmLocation
            DetectedOS    = "Unknown"
            Reason        = "Cannot determine OS type"
        }
        continue
    }

    # ==============================================================
    #        OS-SPECIFIC LOGIC (Linux OR Windows 2019/2022)
    # ==============================================================

    if ($osType -ieq "Linux") {
        Write-Host " - Linux detected → supported"
        $validVMs += [PSCustomObject]@{
            vmName        = $vmName
            location      = $vmLocation
            resourceGroup = $rgName
            osType        = $osType
        }
        continue
    }

    if ($osType -ieq "Windows") {

        # Determine Windows version
        $detectedVersion = $null
        if ($imageSku) { $detectedVersion = $imageSku }
        elseif ($osVersion) { $detectedVersion = $osVersion }
        elseif ($vm.StorageProfile.OsDisk.OsVersion) { $detectedVersion = $vm.StorageProfile.OsDisk.OsVersion }

        # Check if supported
        if ($detectedVersion -imatch "2019" -or $detectedVersion -imatch "2022") {
            Write-Host " - Windows $detectedVersion → supported"
            $validVMs += [PSCustomObject]@{
                vmName        = $vmName
                location      = $vmLocation
                resourceGroup = $rgName
                osType        = $osType
            }
            continue
        }

        Write-Host " - Windows $detectedVersion → unsupported (skip)" -ForegroundColor Red
        $unsupported += [PSCustomObject]@{
            VMName        = $vmName
            ResourceGroup = $rgName
            Location      = $vmLocation
            DetectedOS    = $detectedVersion
            Reason        = "Unsupported Windows version (not 2019/2022)"
        }
        continue
    }

    # Unknown fallback
    Write-Host " - Unknown OS detected. Skipping." -ForegroundColor Red
    $unsupported += [PSCustomObject]@{
        VMName        = $vmName
        ResourceGroup = $rgName
        Location      = $vmLocation
        DetectedOS    = $osType
        Reason        = "Unknown OS"
    }
}

Write-Host "`nValid VMs for ARM deployment: $($validVMs.Count)" -ForegroundColor Green
Write-Host "Unsupported VMs: $($unsupported.Count)" -ForegroundColor Yellow


# Split valid VMs by OS type
$linuxVMs = $validVMs | Where-Object { $_.vmName -and ($_.location) -and ($_.resourceGroup) -and ($_.osType -ieq 'Linux') }
$windowsVMs = $validVMs | Where-Object { $_.vmName -and ($_.location) -and ($_.resourceGroup) -and ($_.osType -ieq 'Windows') }

if ($linuxVMs.Count -eq 0 -and $windowsVMs.Count -eq 0) {
    Write-Host "No supported VMs to deploy MDE." -ForegroundColor Red
    $unsupported | Export-Csv $unsupportedCsv -NoTypeInformation -Force
    exit
}

Write-Host "`nStarting ARM bulk deployment in region $deploymentLocation ..." -ForegroundColor Cyan
$deploymentName = "DEPLOY-MDE-" + (Get-Date -Format "yyyyMMdd-HHmmss")

if ($linuxVMs.Count -gt 0) {
    $linuxGroups = $linuxVMs | Group-Object resourceGroup
    foreach ($group in $linuxGroups) {
        $rgName = $group.Name
        $linuxListForArm = @()
        foreach ($vm in $group.Group) {
            $linuxListForArm += @{
                vmName        = $vm.vmName
                location      = $vm.location
                resourceGroup = $vm.resourceGroup
            }
        }
        $deploymentLinux = New-AzResourceGroupDeployment `
            -ResourceGroupName $rgName `
            -Name "$deploymentName-Linux-$rgName" `
            -TemplateFile $templatePath `
            -vmList $linuxListForArm `
            -extensionType 'MDE.Linux' `
            -ErrorAction Continue
        Write-Host "Linux ARM Deployment finished for $rgName." -ForegroundColor Green
    }
}

if ($windowsVMs.Count -gt 0) {
    $windowsGroups = $windowsVMs | Group-Object resourceGroup
    foreach ($group in $windowsGroups) {
        $rgName = $group.Name
        $windowsListForArm = @()
        foreach ($vm in $group.Group) {
            $windowsListForArm += @{
                vmName        = $vm.vmName
                location      = $vm.location
                resourceGroup = $vm.resourceGroup
            }
        }
        $deploymentWindows = New-AzResourceGroupDeployment `
            -ResourceGroupName $rgName `
            -Name "$deploymentName-Windows-$rgName" `
            -TemplateFile $templatePath `
            -vmList $windowsListForArm `
            -extensionType 'MDE.Windows' `
            -ErrorAction Continue
        Write-Host "Windows ARM Deployment finished for $rgName." -ForegroundColor Green
    }
}

# ==============================================================
#  BUILD SUCCESS / FAILURE REPORT
# ==============================================================

$results = @()

# Flatten ARM deployment error messages
$flatErrors = @()
if ($deployment -and $deployment.Errors) {
    foreach ($e in $deployment.Errors) {
        $flatErrors += ($e.Message -join " | ")
    }
}

foreach ($vm in $validVMs) {

    $status = "Success"
    $errMsg = ""

    foreach ($f in $flatErrors) {
        if ($f -match [regex]::Escape($vm.vmName)) {
            $status = "Failed"
            $errMsg = $f
            break
        }
    }

    $results += [PSCustomObject]@{
        VMName        = $vm.vmName
        ResourceGroup = $vm.resourceGroup
        Location      = $vm.location
        Status        = $status
        ErrorMessage  = $errMsg
    }
}

# Add unsupported VMs to report
foreach ($u in $unsupported) {
    $results += [PSCustomObject]@{
        VMName        = $u.VMName
        ResourceGroup = $u.ResourceGroup
        Location      = $u.Location
        Status        = "Unsupported OS"
        ErrorMessage  = $u.Reason
    }
}

# Export reports
$results      | Export-Csv $logCsv -NoTypeInformation -Force
$unsupported  | Export-Csv $unsupportedCsv -NoTypeInformation -Force

Write-Host "`nReports saved:" -ForegroundColor Cyan
Write-Host " - $logCsv"
Write-Host " - $unsupportedCsv"
Write-Host "`nDONE." -ForegroundColor Green