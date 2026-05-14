<#
.SYNOPSIS
    Generalize a sysprepped VM and create Shared Image Gallery version

.DESCRIPTION
    This script takes a VM that has been sysprepped (but not generalized) and:
    1. Verifies VM is in stopped/deallocated state
    2. Marks the VM as generalized in Azure (Set-AzVM -Generalized)
    3. Creates a Shared Image Gallery version from the generalized VM
    
    Use this AFTER running Clone-And-Sysprep-AVD.ps1 and verifying the VM is ready.

.PARAMETER VMName
    Name of the sysprepped VM to generalize

.PARAMETER ResourceGroupName
    Resource group containing the VM

.PARAMETER SubscriptionId
    Azure subscription ID

.PARAMETER GalleryName
    Shared Image Gallery name

.PARAMETER ImageDefinitionName
    Image definition name in the gallery

.PARAMETER Location
    Azure region (default: westeurope)

.PARAMETER ReplicaRegions
    Additional regions for image replication (default: swedencentral)

.EXAMPLE
    .\Generalize-And-CreateImage-AVD.ps1 `
        -VMName "BABAVDSHDTA-1-Prepared" `
        -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
        -GalleryName "bab_avd_shared_win10_gallery" `
        -ImageDefinitionName "bab-w10-avd-img"

.NOTES
    Author: BAB CloudOps Team
    Date: April 2026
    
    CRITICAL: VM must be stopped and sysprepped before running this script.
    This operation is IRREVERSIBLE - VM cannot be started after generalization.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$GalleryName = "bab_avd_shared_win10_gallery",

    [Parameter(Mandatory = $false)]
    [string]$ImageDefinitionName = "bab-w10-avd-img",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory = $false)]
    [string[]]$ReplicaRegions = @("swedencentral")
)

#region Helper Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage -ForegroundColor Cyan }
    }
    
    $logFile = ".\logs\AVD-Generalize-$(Get-Date -Format 'yyyyMMdd').log"
    $logMessage | Out-File -FilePath $logFile -Append -Encoding utf8
}

#endregion

#region Main Script

try {
    # Initialize logging
    $logDir = ".\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Start-Transcript -Path "$logDir\AVD-Generalize-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    Write-Log "=== Starting VM Generalization and Image Creation ===" -Level Success
    Write-Log "VM: $VMName"
    Write-Log "Gallery: $GalleryName"
    Write-Log "Image Definition: $ImageDefinitionName"
    
    # Set Azure context
    Write-Log "Setting Azure subscription context..."
    $null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue
    $context = Get-AzContext
    Write-Log "Connected to subscription: $($context.Subscription.Name)" -Level Success
    
    # Get VM
    Write-Log "Retrieving VM information..."
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
    Write-Log "VM found: $($vm.Id)" -Level Success
    
    # Check VM power state
    Write-Log "Checking VM power state..."
    $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
    
    Write-Log "Current power state: $powerState" -Level Info
    
    if ($powerState -eq "PowerState/running") {
        Write-Log "ERROR: VM is still running. Cannot generalize a running VM." -Level Error
        Write-Log "Please ensure sysprep has completed and VM has shut down." -Level Error
        throw "VM must be stopped before generalization"
    }
    
    # Deallocate if only stopped
    if ($powerState -eq "PowerState/stopped") {
        Write-Log "VM is stopped but not deallocated. Deallocating..." -Level Warning
        
        if ($PSCmdlet.ShouldProcess($VMName, "Deallocate VM")) {
            Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
            Start-Sleep -Seconds 30
            
            # Verify deallocated
            $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
            $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code
            
            if ($powerState -ne "PowerState/deallocated") {
                throw "Failed to deallocate VM. Current state: $powerState"
            }
            
            Write-Log "VM deallocated successfully" -Level Success
        }
    }
    
    #region Step 1: Generalize VM
    
    Write-Log "=== Step 1: Generalizing VM in Azure ===" -Level Success
    Write-Log "⚠️  WARNING: This operation is IRREVERSIBLE!" -Level Warning
    Write-Log "⚠️  VM cannot be started after generalization" -Level Warning
    
    if ($PSCmdlet.ShouldProcess($VMName, "Mark VM as generalized (IRREVERSIBLE)")) {
        
        Write-Log "Marking VM as generalized..."
        Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized -ErrorAction Stop
        
        # Verify generalization
        Start-Sleep -Seconds 10
        $vmInfo = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        
        if ($vmInfo.OSProfile) {
            Write-Log "WARNING: VM still has OSProfile - waiting and retrying..." -Level Warning
            Start-Sleep -Seconds 30
            Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized -ErrorAction Stop
            Start-Sleep -Seconds 10
            
            $vmInfo = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
            if ($vmInfo.OSProfile) {
                Write-Log "VM still shows OSProfile but generalization command succeeded" -Level Warning
                Write-Log "Proceeding with image creation..." -Level Info
            }
        }
        
        Write-Log "VM generalized successfully" -Level Success
    }
    
    #endregion
    
    #region Step 2: Create Shared Image Gallery Version
    
    Write-Log "=== Step 2: Creating Shared Image Gallery Version ===" -Level Success
    
    if ($PSCmdlet.ShouldProcess($GalleryName, "Create image version")) {
        
        # Ensure gallery exists
        $gallery = Get-AzGallery -ResourceGroupName $ResourceGroupName `
            -Name $GalleryName `
            -ErrorAction SilentlyContinue
        
        if (-not $gallery) {
            Write-Log "Creating Shared Image Gallery: $GalleryName"
            $gallery = New-AzGallery `
                -ResourceGroupName $ResourceGroupName `
                -GalleryName $GalleryName `
                -Location $Location `
                -Description "BAB AVD Shared Image Gallery" `
                -ErrorAction Stop
            Write-Log "Gallery created" -Level Success
        }
        
        # Ensure image definition exists
        $imageDef = Get-AzGalleryImageDefinition `
            -ResourceGroupName $ResourceGroupName `
            -GalleryName $GalleryName `
            -Name $ImageDefinitionName `
            -ErrorAction SilentlyContinue
        
        if (-not $imageDef) {
            Write-Log "Creating Image Definition: $ImageDefinitionName"
            $imageDef = New-AzGalleryImageDefinition `
                -ResourceGroupName $ResourceGroupName `
                -GalleryName $GalleryName `
                -Name $ImageDefinitionName `
                -Location $Location `
                -OsState Generalized `
                -OsType Windows `
                -Publisher "babcloud" `
                -Offer "windows-10-avd" `
                -Sku "20h2-avd" `
                -HyperVGeneration V1 `
                -ErrorAction Stop
            Write-Log "Image definition created" -Level Success
        }
        
        # Create image version with timestamp
        $imageVersion = "{0}.{1}.{2}" -f (Get-Date -Format "yyyy"), (Get-Date -Format "MMdd"), (Get-Date -Format "HHmm")
        Write-Log "Creating image version: $imageVersion" -Level Info
        
        $vmId = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName).Id
        
        # Build target regions
        $targetRegions = @(@{Name = $Location; ReplicaCount = 1})
        foreach ($region in $ReplicaRegions) {
            $targetRegions += @{Name = $region; ReplicaCount = 1}
        }
        
        Write-Log "Target regions: $($targetRegions.Name -join ', ')" -Level Info
        Write-Log "Creating image version (this may take 10-30 minutes)..." -Level Info
        
        $imageVersionParams = @{
            ResourceGroupName              = $ResourceGroupName
            GalleryName                    = $GalleryName
            GalleryImageDefinitionName     = $ImageDefinitionName
            Name                           = $imageVersion
            Location                       = $Location
            SourceImageVMId               = $vmId
            TargetRegion                   = $targetRegions
            ErrorAction                    = 'Stop'
        }
        
        $imgVersion = New-AzGalleryImageVersion @imageVersionParams
        
        Write-Log "Image version created successfully!" -Level Success
        Write-Log "Image ID: $($imgVersion.Id)" -Level Info
        Write-Log "Version: $imageVersion" -Level Success
    }
    
    #endregion
    
    Write-Log "=== Image Creation Complete ===" -Level Success
    Write-Log "✅ VM generalized: $VMName" -Level Success
    Write-Log "✅ Image version created: $imageVersion" -Level Success
    Write-Log "✅ Gallery: $GalleryName" -Level Success
    Write-Host ""
    Write-Log "You can now:" -Level Info
    Write-Log "1. Deploy new AVD session hosts from this image" -Level Info
    Write-Log "2. Use Configure-AVD-SessionHost.ps1 for post-deployment setup" -Level Info
    Write-Log "3. Delete the source VM '$VMName' (no longer needed)" -Level Info
    
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error
    throw
}
finally {
    Stop-Transcript
}

#endregion
