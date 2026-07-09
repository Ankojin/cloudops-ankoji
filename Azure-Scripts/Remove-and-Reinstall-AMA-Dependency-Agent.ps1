# ==========================================
# Azure Monitor Agent / Dependency Agent Repair Script
# - Excludes specific Resource Groups
# - Skips Stopped/Deallocated VMs
# - Skips unsupported Linux OS versions
# - Skips VMs with healthy extensions
# - Repairs only Failed or Missing extensions
# ==========================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77",
    [string[]]$ExcludedRGs  = @("aro-infra-lybja3b0-bab-sit-aro-01"),
    [string]$LogPath         = "$PSScriptRoot\AMA-Repair-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

#Connect-AzAccount
Set-AzContext -SubscriptionId $SubscriptionId

# Start transcript for audit trail
Start-Transcript -Path $LogPath -Append
Write-Host "Log: $LogPath" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Helper: poll until an extension reaches a terminal provisioning state
# Returns $true (Succeeded) or $false (Failed / Timeout)
# -----------------------------------------------------------------------
function Wait-ExtensionProvisioning
{
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$ExtensionName,
        [int]$TimeoutSeconds    = 300,
        [int]$PollIntervalSecs  = 15
    )

    $elapsed = 0
    Write-Host "  Verifying $ExtensionName provisioning state (timeout: ${TimeoutSeconds}s)..." -ForegroundColor DarkGray

    do
    {
        Start-Sleep -Seconds $PollIntervalSecs
        $elapsed += $PollIntervalSecs

        $ext   = Get-AzVMExtension -ResourceGroupName $ResourceGroupName `
                     -VMName $VMName -Name $ExtensionName -ErrorAction SilentlyContinue
        $state = if ($ext) { $ext.ProvisioningState } else { 'NotFound' }

        Write-Host "  [$elapsed/${TimeoutSeconds}s] $ExtensionName : $state" -ForegroundColor DarkGray

        if ($state -eq 'Succeeded') { Write-Host "  $ExtensionName : Succeeded." -ForegroundColor Green;  return $true  }
        if ($state -eq 'Failed')    { Write-Host "  $ExtensionName : Failed."    -ForegroundColor Red;    return $false }

    } while ($elapsed -lt $TimeoutSeconds)

    Write-Host "  $ExtensionName : timed out after ${TimeoutSeconds}s (last state: $state)." -ForegroundColor Red
    return $false
}

# -----------------------------------------------------------------------
# Helper: wait for a Transitioning extension to leave Transitioning state.
# ARM refuses remove/update while an extension is mid-operation.
# Returns the settled ProvisioningState string (or 'Transitioning' on timeout).
# -----------------------------------------------------------------------
function Wait-ExtensionSettled
{
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$ExtensionName,
        [int]$TimeoutSeconds   = 600,   # shim.sh ops can take a while
        [int]$PollIntervalSecs = 30
    )

    $elapsed = 0
    Write-Host "  $ExtensionName is Transitioning — waiting to settle (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow

    do
    {
        Start-Sleep -Seconds $PollIntervalSecs
        $elapsed += $PollIntervalSecs

        $ext   = Get-AzVMExtension -ResourceGroupName $ResourceGroupName `
                     -VMName $VMName -Name $ExtensionName -ErrorAction SilentlyContinue
        $state = if ($ext) { $ext.ProvisioningState } else { 'NotFound' }

        Write-Host "  [$elapsed/${TimeoutSeconds}s] $ExtensionName : $state" -ForegroundColor DarkGray

        if ($state -ne 'Transitioning')
        {
            Write-Host "  $ExtensionName settled to: $state" -ForegroundColor Cyan
            return $state
        }

    } while ($elapsed -lt $TimeoutSeconds)

    Write-Host "  $ExtensionName still Transitioning after ${TimeoutSeconds}s — will attempt forced removal." -ForegroundColor Red
    return 'Transitioning'
}

# Minimum supported major OS version per Publisher/Offer for AMA + Dependency Agent
# Versions below these are not supported by either agent
$MinSupportedLinuxVersion = @{
    "RedHat/RHEL"            = 7
    "OpenLogic/CentOS"       = 7
    "Oracle/Oracle-Linux"    = 7
    "Oracle/OracleLinux"     = 7
    "SUSE/SLES"              = 12
    "SUSE/SLES-SAP"          = 12
    "Canonical/UbuntuServer" = 16
    "credativ/Debian"        = 9
}

# Distros where Dependency Agent does NOT support newer major versions.
# AMA supports these; DA does not.
# NOTE: detection below uses family-based matching (not this table directly)
# because RedHat alone has 50+ marketplace offers (rhel-byos, RHEL-SAP-HA, rhel-raw …)
# and exact-key lookups miss them all.
$DaMaxLinuxMajor = @{
    "RedHat/RHEL"            = 8   # reference only — see family check below
    "OpenLogic/CentOS"       = 8
    "Oracle/Oracle-Linux"    = 8
    "Oracle/OracleLinux"     = 8
}

# Get VM list (no -Status here — subscription-wide instance-view expansion is unreliable)
$vms = Get-AzVM | Where-Object {
    $_.ResourceGroupName -notin $ExcludedRGs
}

foreach ($vm in $vms)
{
    $rg       = $vm.ResourceGroupName
    $vmName   = $vm.Name
    $osType   = $vm.StorageProfile.OsDisk.OsType
    $location = $vm.Location

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "Processing VM: $vmName" -ForegroundColor Cyan
    Write-Host "Resource Group: $rg" -ForegroundColor Cyan

    # Always fetch per-VM instance view for a reliable power state
    $vmDetail   = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction SilentlyContinue
    $powerState = ($vmDetail.Statuses |
        Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

    Write-Host "Power State: $powerState" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    # Skip any VM that is not explicitly running
    if ($powerState -ne "VM running")
    {
        Write-Host "Skipping VM — power state is '$powerState' (must be 'VM running')." -ForegroundColor Yellow
        continue
    }

    # Skip VMs whose guest agent is not Ready — extension operations will fail anyway
    $agentStatus = ($vmDetail.VMAgent.Statuses |
        Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus
    if ($agentStatus -ne "Ready")
    {
        $agentDisplay = if ($agentStatus) { $agentStatus } else { "Unknown / Not Reported" }
        Write-Host "Skipping VM — VM Agent is not Ready (status: '$agentDisplay'). Extension operations require a healthy guest agent." -ForegroundColor Yellow
        continue
    }

    # Initialise per-iteration so Windows VMs never inherit a stale Linux $imgRef
    $imgRef = $null

    # Skip unsupported Linux OS versions
    if ($osType -ne "Windows")
    {
        $imgRef = $vm.StorageProfile.ImageReference
        if ($imgRef -and $imgRef.Publisher -and $imgRef.Offer)
        {
            $imgKey = "$($imgRef.Publisher)/$($imgRef.Offer)"
            if ($MinSupportedLinuxVersion.ContainsKey($imgKey))
            {
                $skuMajor = [int]($imgRef.Sku -replace '^(\d+).*', '$1')
                $minVer   = $MinSupportedLinuxVersion[$imgKey]
                if ($skuMajor -lt $minVer)
                {
                    Write-Host "Skipping $vmName — unsupported OS: $($imgRef.Publisher) $($imgRef.Offer) Sku=$($imgRef.Sku) (min supported major version: $minVer)." -ForegroundColor Yellow
                    continue
                }
            }
        }
    }

    try
    {
        $extensions = Get-AzVMExtension `
            -ResourceGroupName $rg `
            -VMName $vmName `
            -ErrorAction Stop
    }
    catch
    {
        Write-Host "Failed to retrieve extensions for $vmName. Skipping." -ForegroundColor Red
        continue
    }

    # Determine extension names based on OS
    if ($osType -eq "Windows")
    {
        $AMAName = "AzureMonitorWindowsAgent"
        $DAName  = "DependencyAgentWindows"
    }
    else
    {
        $AMAName = "AzureMonitorLinuxAgent"
        $DAName  = "DependencyAgentLinux"
    }

    # Determine whether Dependency Agent is supported on this OS version.
    # DA does NOT support RHEL/CentOS/Oracle/Rocky/AlmaLinux family on major version >= 9.
    #
    # Detection is case-insensitive and matches on publisher/offer substrings so that
    # all marketplace offer variants (rhel-byos, RHEL-SAP-HA, rhel-raw, rhel-arm64 …)
    # are caught — not just the single canonical "RedHat/RHEL" key.
    $daOsSupported = $true
    if ($osType -ne "Windows" -and $imgRef -and $imgRef.Sku)
    {
        $skuMajor = [int]($imgRef.Sku -replace '^(\d+).*', '$1')
        $pub      = if ($imgRef.Publisher) { $imgRef.Publisher.ToLower() } else { '' }
        $offer    = if ($imgRef.Offer)     { $imgRef.Offer.ToLower()     } else { '' }

        # RHEL family: RedHat publisher, or RHEL/CentOS/Rocky/Alma anywhere in publisher or offer
        $isRhelFamily = ($pub   -like '*redhat*')    -or
                        ($offer -like '*rhel*')       -or
                        ($pub   -like '*centos*')     -or
                        ($offer -like '*centos*')     -or
                        ($pub   -like '*oracle*'      -and ($offer -like '*linux*' -or $offer -like '*ol*' -or $offer -eq '')) -or
                        ($pub   -like '*almalinux*')  -or
                        ($pub   -like '*rockylinux*') -or
                        ($offer -like '*rockylinux*') -or
                        ($offer -like '*almalinux*')

        if ($isRhelFamily -and $skuMajor -ge 9)
        {
            $daOsSupported = $false
            Write-Host "DA not supported on $($imgRef.Publisher)/$($imgRef.Offer) Sku=$($imgRef.Sku) (RHEL/CentOS/Oracle family, major version $skuMajor >= 9) — will remove if present, skip reinstall." -ForegroundColor DarkYellow
        }
        elseif ($imgRef.Publisher -and $imgRef.Offer)
        {
            # Fallback: exact-key lookup for any other distros listed in $DaMaxLinuxMajor
            $imgKey = "$($imgRef.Publisher)/$($imgRef.Offer)"
            if ($DaMaxLinuxMajor.ContainsKey($imgKey) -and $skuMajor -gt $DaMaxLinuxMajor[$imgKey])
            {
                $daOsSupported = $false
                Write-Host "DA not supported on $($imgRef.Publisher)/$($imgRef.Offer) Sku=$($imgRef.Sku) (DA max supported major: $($DaMaxLinuxMajor[$imgKey])) — will remove if present, skip reinstall." -ForegroundColor DarkYellow
            }
        }
    }

    $RepairRequired = $false

    # --- AMA health check (always required) ---
    $amaExt = $extensions | Where-Object { $_.Name -eq $AMAName }
    if (-not $amaExt)
    {
        Write-Host "$AMAName is not installed." -ForegroundColor Yellow
        $RepairRequired = $true
    }
    elseif ($amaExt.ProvisioningState -ne "Succeeded")
    {
        Write-Host "$AMAName state: $($amaExt.ProvisioningState)" -ForegroundColor Yellow
        $RepairRequired = $true
    }
    else
    {
        Write-Host "$AMAName : Succeeded" -ForegroundColor Green
    }

    # --- DA health check (only required when OS supports DA) ---
    $daExt0 = $extensions | Where-Object { $_.Name -eq $DAName }
    if ($daOsSupported)
    {
        if (-not $daExt0)
        {
            Write-Host "$DAName is not installed." -ForegroundColor Yellow
            $RepairRequired = $true
        }
        elseif ($daExt0.ProvisioningState -ne "Succeeded")
        {
            Write-Host "$DAName state: $($daExt0.ProvisioningState)" -ForegroundColor Yellow
            $RepairRequired = $true
        }
        else
        {
            Write-Host "$DAName : Succeeded" -ForegroundColor Green
        }
    }
    else
    {
        # DA is not expected on this OS — but if it is present (e.g. stuck Transitioning)
        # we must remove it; do NOT flag "not installed" as an error
        if ($daExt0)
        {
            Write-Host "$DAName found on unsupported OS (state: $($daExt0.ProvisioningState)) — flagged for removal." -ForegroundColor Yellow
            $RepairRequired = $true
        }
        else
        {
            Write-Host "$DAName not installed (expected — OS not supported for DA)." -ForegroundColor Green
        }
    }

    if (-not $RepairRequired)
    {
        Write-Host "All monitoring extensions are healthy. Skipping VM." -ForegroundColor Green
        continue
    }

    # Remove Failed / Stuck Extensions
    # Build the removal candidate list:
    #   - AMA if not Succeeded
    #   - DA  if not Succeeded  (supported OS)  OR  if present at ALL (unsupported OS)
    $removedExtensions = @()
    $removalCandidates = @($AMAName)   # AMA is always checked
    $daExtForRemoval   = $extensions | Where-Object { $_.Name -eq $DAName }
    if ($daExtForRemoval)
    {
        # Always include DA in candidates — removal logic below decides based on state + OS support
        $removalCandidates += $DAName
    }

    # --- Settle any Transitioning extensions before attempting removal ---
    # ARM rejects remove/update requests while an extension is mid-operation.
    # Wait up to 10 min for it to leave Transitioning, then proceed regardless.
    foreach ($extName in $removalCandidates)
    {
        $ext = $extensions | Where-Object { $_.Name -eq $extName }
        if ($ext -and $ext.ProvisioningState -eq 'Transitioning')
        {
            $settledState = Wait-ExtensionSettled -ResourceGroupName $rg -VMName $vmName -ExtensionName $extName
            # Refresh the local snapshot so the removal loop sees the settled state
            $refreshed = Get-AzVMExtension -ResourceGroupName $rg -VMName $vmName `
                             -Name $extName -ErrorAction SilentlyContinue
            $extensions = @($extensions | Where-Object { $_.Name -ne $extName })
            if ($refreshed) { $extensions += $refreshed }
        }
    }

    $amaRemovalAttempted = $false
    foreach ($extName in $removalCandidates)
    {
        $ext = $extensions | Where-Object { $_.Name -eq $extName }

        # For DA on unsupported OS: remove regardless of provisioning state
        # For everything else: only remove if not Succeeded
        $shouldRemove = ($ext -and $ext.ProvisioningState -ne "Succeeded") -or
                        ($extName -eq $DAName -and -not $daOsSupported -and $ext)

        if ($shouldRemove)
        {
            if ($extName -eq $AMAName) { $amaRemovalAttempted = $true }
            # Retry removal up to 3 times — extension may still be briefly locked after Transitioning
            $removeAttempt = 0
            $removeSuccess = $false
            while ($removeAttempt -lt 3 -and -not $removeSuccess)
            {
                $removeAttempt++
                if ($removeAttempt -gt 1) { Start-Sleep -Seconds 30 }
                try
                {
                    Write-Host "Removing $extName (attempt $removeAttempt)..." -ForegroundColor Yellow

                    Remove-AzVMExtension `
                        -ResourceGroupName $rg `
                        -VMName $vmName `
                        -Name $extName `
                        -Force `
                        -ErrorAction Stop

                    Write-Host "$extName removed successfully." -ForegroundColor Green
                    $removedExtensions += $extName
                    $removeSuccess = $true
                }
                catch
                {
                    Write-Host "Remove attempt $removeAttempt failed for $extName : $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            if (-not $removeSuccess)
            {
                Write-Host "Could not remove $extName after 3 attempts — skipping reinstall for this extension." -ForegroundColor Red
            }
        }
    }

    # Poll until removed extensions are gone before reinstalling (max 5 minutes)
    if ($removedExtensions.Count -gt 0)
    {
        $timeoutSec  = 300
        $elapsed     = 0
        $pollInterval = 15
        $stillPresent = $removedExtensions

        Write-Host "Polling for removal completion (timeout: ${timeoutSec}s)..." -ForegroundColor Yellow

        do
        {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            $stillPresent = $removedExtensions | Where-Object {
                $null -ne (Get-AzVMExtension `
                    -ResourceGroupName $rg `
                    -VMName $vmName `
                    -Name $_ `
                    -ErrorAction SilentlyContinue)
            }

            if (-not $stillPresent) { break }

            Write-Host "  Still waiting for removal... ($elapsed/${timeoutSec}s)" -ForegroundColor Yellow

        } while ($elapsed -lt $timeoutSec)

        if ($stillPresent)
        {
            Write-Host "Timeout: $($stillPresent -join ', ') still present after ${timeoutSec}s — installs may fail." -ForegroundColor Red
        }
    }

    # Install Azure Monitor Agent if missing or not healthy
    # Guard: if AMA was targeted for removal but removal failed, skip install —
    # attempting a version-change install against a stuck handler will always fail.
    # $amaRemovalAttempted is only true when AMA was actually unhealthy and removal was attempted.
    # Prevents a false-positive when AMA is Succeeded and was never touched.
    $amaRemovalFailed = $amaRemovalAttempted -and
                        ($removedExtensions -notcontains $AMAName)
    if ($amaRemovalFailed)
    {
        Write-Host "$AMAName removal did not complete \u2014 skipping install to avoid version-conflict loop." -ForegroundColor Red
    }
    else
    {
    try
    {
        $amaExt = Get-AzVMExtension `
            -ResourceGroupName $rg `
            -VMName $vmName `
            -Name $AMAName `
            -ErrorAction SilentlyContinue

        if (-not $amaExt -or $amaExt.ProvisioningState -ne "Succeeded")
        {
            Write-Host "Installing $AMAName..." -ForegroundColor Yellow

            $amaLatest = (Get-AzVMExtensionImage `
                -Location $location `
                -PublisherName "Microsoft.Azure.Monitor" `
                -Type $AMAName `
                | Sort-Object { [System.Version]$_.Version } -Descending `
                | Select-Object -First 1).Version
            $amaVersion = ($amaLatest -split '\.')[0..1] -join '.'
            Write-Host "  Using $AMAName version $amaVersion" -ForegroundColor Cyan

            Set-AzVMExtension `
                -ResourceGroupName $rg `
                -VMName $vmName `
                -Name $AMAName `
                -Publisher "Microsoft.Azure.Monitor" `
                -ExtensionType $AMAName `
                -TypeHandlerVersion $amaVersion `
                -EnableAutomaticUpgrade $true `
                -Location $location `
                -ErrorAction Stop

            $amaOk = Wait-ExtensionProvisioning -ResourceGroupName $rg -VMName $vmName -ExtensionName $AMAName
            if (-not $amaOk)
            {
                Write-Host "$AMAName did not reach Succeeded state after install — review extension logs on the VM." -ForegroundColor Red
            }
        }
    }
    catch
    {
        # Match on ErrorCode text OR on the descriptive message — both can appear in $_.Exception.Message
        if ($_.Exception.Message -match "OperationNotAllowed|409|autoUpgradeMinorVersion|handlerVersion|Cannot update")
        {
            # Handler version / autoUpgradeMinorVersion conflict — rerun using the EXISTING handler's settings.
            # Strategy (in priority order):
            #   1. Parse version + autoUpgrade directly from the conflict error message
            #      (the message always contains e.g. "typeHandler version '1.30'" and "autoUpgradeMinorVersion 'False'")
            #   2. Supplement with Get-AzVMExtension if the parsed values are missing
            #   3. Omit a param entirely rather than send an empty/invalid value
            Write-Host "Handler conflict on $AMAName — resolving existing handler settings for rerun..." -ForegroundColor Yellow

            $conflictMsg = $_.Exception.Message

            # --- Parse from the error message ---
            $parsedVersion     = $null
            $parsedAutoUpgrade = $null

            if ($conflictMsg -match "typeHandler version '([\d\.]+)'")
            {
                $v = ($Matches[1] -split '\.')[0..1] -join '.'
                if ($v -match '^\d+\.\d+$') { $parsedVersion = $v }
            }
            if ($conflictMsg -match "autoUpgradeMinorVersion '(\w+)'")
            {
                try { $parsedAutoUpgrade = [System.Convert]::ToBoolean($Matches[1]) } catch {}
            }

            Write-Host "  Parsed from error  — TypeHandlerVersion: $parsedVersion  AutoUpgradeMinorVersion: $parsedAutoUpgrade" -ForegroundColor DarkGray

            try
            {
                # --- Supplement with live extension data (for diagnostic logging only) ---
                $existingAma = Get-AzVMExtension `
                    -ResourceGroupName $rg `
                    -VMName $vmName `
                    -Name $AMAName `
                    -ErrorAction SilentlyContinue

                $resolvedVersion     = $parsedVersion
                $resolvedAutoUpgrade = $parsedAutoUpgrade

                if (-not $resolvedVersion -and $existingAma -and $existingAma.TypeHandlerVersion)
                {
                    $v = ($existingAma.TypeHandlerVersion -split '\.')[0..1] -join '.'
                    if ($v -match '^\d+\.\d+$') { $resolvedVersion = $v }
                }
                if ($null -eq $resolvedAutoUpgrade -and $existingAma -and
                    ($null -ne $existingAma.AutoUpgradeMinorVersion))
                {
                    $resolvedAutoUpgrade = $existingAma.AutoUpgradeMinorVersion
                }

                Write-Host "  Resolved for rerun — TypeHandlerVersion: $resolvedVersion  AutoUpgradeMinorVersion: $resolvedAutoUpgrade" -ForegroundColor Cyan

                # Pure ForceRerun — intentionally NO TypeHandlerVersion or auto-upgrade params.
                # When the handler is shared with other extensions and those fields are locked,
                # including ANY version/upgrade property alongside ForceRerun causes ARM to treat
                # the call as an update operation and return a 409 OperationNotAllowed.
                # Sending only ForceRerun tells ARM to re-execute with the existing locked settings.
                $rerunParams = @{
                    ResourceGroupName = $rg
                    VMName            = $vmName
                    Name              = $AMAName
                    Publisher         = "Microsoft.Azure.Monitor"
                    ExtensionType     = $AMAName
                    Location          = $location
                    ForceRerun        = [System.Guid]::NewGuid().ToString()
                    ErrorAction       = "Stop"
                }

                Set-AzVMExtension @rerunParams

                $amaOk = Wait-ExtensionProvisioning -ResourceGroupName $rg -VMName $vmName -ExtensionName $AMAName
                if ($amaOk)
                {
                    Write-Host "$AMAName rerun completed: Succeeded." -ForegroundColor Green
                }
                else
                {
                    Write-Host "$AMAName rerun did not reach Succeeded state — review extension logs on the VM." -ForegroundColor Red
                }
            }
            catch
            {
                if ($_.Exception.Message -match "OperationNotAllowed|409|conflict")
                {
                    # The handler is locked by a shared extension and cannot be updated or re-run
                    # via ForceRerun. The extension must be removed and reinstalled cleanly.
                    # This typically requires manual intervention or re-running the script after
                    # the conflicting extension is resolved at the platform level.
                    Write-Host "  $AMAName handler is locked by a shared extension conflict (409). ForceRerun is not possible." -ForegroundColor Red
                    Write-Host "  Action required: Remove and reinstall $AMAName manually, or re-run this script after the conflicting handler is resolved." -ForegroundColor Red
                    Write-Host "  Conflict detail: $($_.Exception.Message -replace '\s+',' ')" -ForegroundColor DarkGray
                }
                else
                {
                    Write-Host "Failed to rerun $AMAName : $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        else
        {
            Write-Host "Failed to install $AMAName : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    } # end else (amaRemovalFailed guard)

    # Install Dependency Agent if missing or not healthy
    # Skip entirely if OS is not supported for DA ($daOsSupported computed earlier)
    if (-not $daOsSupported)
    {
        Write-Host "Skipping $DAName reinstall — OS not supported for DA." -ForegroundColor DarkYellow
    }
    else
    {
        try
        {
            $daExt = Get-AzVMExtension `
                -ResourceGroupName $rg `
                -VMName $vmName `
                -Name $DAName `
                -ErrorAction SilentlyContinue

            if (-not $daExt -or $daExt.ProvisioningState -ne "Succeeded")
            {
                Write-Host "Installing $DAName..." -ForegroundColor Yellow

                Set-AzVMExtension `
                    -ResourceGroupName $rg `
                    -VMName $vmName `
                    -Name $DAName `
                    -Publisher "Microsoft.Azure.Monitoring.DependencyAgent" `
                    -ExtensionType $DAName `
                    -TypeHandlerVersion "9.10" `
                    -EnableAutomaticUpgrade $true `
                    -Location $location `
                    -ErrorAction Stop

                $daOk = Wait-ExtensionProvisioning -ResourceGroupName $rg -VMName $vmName -ExtensionName $DAName
                if (-not $daOk)
                {
                    Write-Host "$DAName did not reach Succeeded state after install — review extension logs on the VM." -ForegroundColor Red
                }
            }
            else
            {
                Write-Host "$DAName : Succeeded (no reinstall needed)." -ForegroundColor Green
            }
        }
        catch
        {
            # Exit code 51 = unsupported distribution (e.g. RHEL 9.x detected at runtime
            # even though image metadata didn't trigger the $daOsSupported pre-check).
            # This is a permanent, non-retryable condition — remove the newly-failed extension
            # to prevent an infinite remove→reinstall→fail loop on every subsequent script run.
            if ($_.Exception.Message -match 'exit code.*51|Unsupported distribution|0x00000033|VMExtensionHandlerNonTransientError')
            {
                Write-Host "$DAName install failed — unsupported Linux distribution detected at runtime (exit code 51). DA does not support this OS version." -ForegroundColor DarkYellow
                Write-Host "Removing failed $DAName extension to prevent retry loop on next run..." -ForegroundColor DarkYellow
                try
                {
                    Remove-AzVMExtension `
                        -ResourceGroupName $rg `
                        -VMName $vmName `
                        -Name $DAName `
                        -Force `
                        -ErrorAction Stop
                    Write-Host "$DAName failed extension removed successfully. VM will not be retried for DA on future runs (OS is unsupported)." -ForegroundColor Green
                }
                catch
                {
                    Write-Host "Could not remove failed $DAName extension: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            else
            {
                Write-Host "Failed to install $DAName : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Write-Host "$vmName completed." -ForegroundColor Green
}

Stop-Transcript
