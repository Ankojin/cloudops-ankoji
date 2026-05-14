<#
.SYNOPSIS
    Configure static DNS and disable cloud-init network management on Linux VMs in Azure.

.DESCRIPTION
    Runs a set of network configuration commands on one or many Azure Linux VMs via
    Azure VM Run Command (no extension required):

      1. Writes /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
         to prevent cloud-init from overwriting network settings on reboot.
      2. Sets static DNS servers on the specified NetworkManager connection.
      3. Sets DNS search domains on the connection.
      4. Disables automatic DNS from DHCP (ipv4.ignore-auto-dns yes).
      5. Reapplies the connection (nmcli device reapply eth0) – no reboot required.

    Supports two operation scopes (-Mode):
      Single – one VM, specified by parameters
      Bulk   – many VMs, driven by a CSV file

.PARAMETER Mode
    Operation scope: Single or Bulk.

.PARAMETER SubscriptionId
    Azure Subscription ID. Optional; uses current context if omitted.

.PARAMETER ResourceGroupName
    Resource Group containing the VM (required for Single mode).

.PARAMETER VMName
    Name of the Linux VM (required for Single mode).

.PARAMETER ConnectionName
    NetworkManager connection name on the VM. Default: "System eth0".

.PARAMETER DNSServers
    Space-separated DNS server IP addresses.
    Default: "10.189.250.4 10.190.1.9 10.189.250.5"

.PARAMETER DNSSearch
    Space-separated DNS search domains.
    Default: "albtests.com reddog.microsoft.com"

.PARAMETER CSVPath
    Path to the CSV file (required for Bulk mode).
    Required columns : SubscriptionId, ResourceGroupName, VMName
    Optional columns : ConnectionName

.PARAMETER LogPath
    Log directory. Default: C:\Azure-VM-Logs

.EXAMPLE
    # Single VM – defaults
    .\Set-LinuxNetworkDNS.ps1 -Mode Single `
        -ResourceGroupName "RG-Linux-VMs" -VMName "linux-vm-01"

.EXAMPLE
    # Single VM – custom connection name
    .\Set-LinuxNetworkDNS.ps1 -Mode Single `
        -ResourceGroupName "RG-Linux-VMs" -VMName "linux-vm-01" `
        -ConnectionName "Wired connection 1"

.EXAMPLE
    # Bulk from CSV
    .\Set-LinuxNetworkDNS.ps1 -Mode Bulk -CSVPath "C:\Temp\vms.csv"

.EXAMPLE
    # WhatIf preview
    .\Set-LinuxNetworkDNS.ps1 -Mode Single `
        -ResourceGroupName "RG-Linux-VMs" -VMName "linux-vm-01" -WhatIf

.NOTES
    Author  : BAB CloudOps Team
    Version : 1.0
    Date    : 2026-05-05
    Requires: Az.Compute module

    CSV format (Bulk mode):
      SubscriptionId,ResourceGroupName,VMName[,ConnectionName]

    Run Command executes as root inside the VM – sudo is not needed in the
    script body and is intentionally omitted.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Single', 'Bulk')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$ConnectionName = 'System eth0',

    [Parameter(Mandatory = $false)]
    [string]$DNSServers = '10.189.250.4 10.190.1.9 10.189.250.5',

    [Parameter(Mandatory = $false)]
    [string]$DNSSearch = 'albtests.com reddog.microsoft.com',

    [Parameter(Mandatory = $false)]
    [string]$CSVPath,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = 'C:\Azure-VM-Logs'
)

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    if (-not $WhatIfPreference) {
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }
        $logFile = Join-Path $LogPath "LinuxVM-NetworkDNS-$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $logFile -Value $logMessage
    }
}

function Test-AzureConnection {
    Write-Log 'Checking Azure connection and required modules...'
    try {
        if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
            Write-Log 'Az.Compute module not found. Installing...' 'WARNING'
            Install-Module -Name Az.Compute -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module Az.Compute -ErrorAction Stop

        $context = Get-AzContext -ErrorAction Stop
        if (-not $context) {
            Write-Log 'Not connected to Azure. Run Connect-AzAccount first.' 'ERROR'
            return $false
        }
        Write-Log "Connected as : $($context.Account.Id)" 'SUCCESS'
        Write-Log "Subscription : $($context.Subscription.Name) ($($context.Subscription.Id))"
        return $true
    }
    catch {
        Write-Log "Azure connection check failed: $_" 'ERROR'
        return $false
    }
}

function Import-NetworkConfigCSV {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            Write-Log "CSV file not found: $Path" 'ERROR'
            return $null
        }
        $data = Import-Csv -Path $Path -ErrorAction Stop
        if ($data.Count -eq 0) {
            Write-Log 'CSV file is empty.' 'ERROR'
            return $null
        }
        $required = @('SubscriptionId', 'ResourceGroupName', 'VMName')
        $cols     = $data[0].PSObject.Properties.Name
        foreach ($col in $required) {
            if ($col -notin $cols) {
                Write-Log "Missing required CSV column: $col (required: $($required -join ', '))" 'ERROR'
                return $null
            }
        }
        Write-Log "CSV loaded: $($data.Count) entries." 'SUCCESS'
        return $data
    }
    catch {
        Write-Log "CSV import failed: $_" 'ERROR'
        return $null
    }
}

# Build and run the network configuration bash script on a single VM
function Set-VMNetworkDNS {
    param(
        [string]$SubId,
        [string]$RGName,
        [string]$VmName,
        [string]$ConnName,
        [string]$Dns,
        [string]$DnsSearch
    )

    Write-Log '================================================'
    Write-Log "VM            : $VmName"
    Write-Log "Resource Group: $RGName"
    Write-Log "Connection    : $ConnName"
    Write-Log "DNS Servers   : $Dns"
    Write-Log "DNS Search    : $DnsSearch"

    # Switch subscription context
    if ($SubId) {
        Write-Log "Setting subscription context: $SubId"
        try { Set-AzContext -SubscriptionId $SubId -ErrorAction Stop | Out-Null }
        catch {
            Write-Log "Failed to set subscription context: $_" 'ERROR'
            Write-Log '================================================'
            return $false
        }
    }

    # Verify VM exists and is Linux
    $vm = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $RGName -Name $VmName -ErrorAction Stop
    }
    catch {
        Write-Log "VM '$VmName' not found in '$RGName': $_" 'ERROR'
        Write-Log '================================================'
        return $false
    }

    if ($vm.StorageProfile.OSDisk.OSType -ne 'Linux') {
        Write-Log "VM '$VmName' is not a Linux VM (OS: $($vm.StorageProfile.OSDisk.OSType))." 'ERROR'
        Write-Log '================================================'
        return $false
    }

    $powerState = (Get-AzVM -ResourceGroupName $RGName -Name $VmName -Status).Statuses |
        Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1
    Write-Log "Power state   : $($powerState.DisplayStatus)"
    if ($powerState.Code -ne 'PowerState/running') {
        Write-Log 'VM is not running. Run Command requires a running VM.' 'WARNING'
    }

    if (-not $PSCmdlet.ShouldProcess($VmName, "Configure network DNS on '$VmName'")) {
        Write-Log "[WhatIf] Would configure DNS settings on '$VmName'." 'INFO'
        Write-Log '================================================'
        return $true
    }

    # Bash script – runs as root via Run Command, no sudo needed.
    # Values are embedded directly via PowerShell double-quoted here-string.
    # Azure Run Command exports -Parameter values as shell variables which
    # breaks space-separated DNS lists; direct embedding avoids that entirely.
    $bashScript = @"
#!/bin/bash
set -e

CONN_NAME='$ConnName'
DNS_SERVERS='$Dns'
DNS_SEARCH='$DnsSearch'

echo "=== Step 1: Disable cloud-init network management ==="
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' | tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "=== Step 2: Set DNS servers ==="
nmcli con mod "`$CONN_NAME" ipv4.dns "`$DNS_SERVERS"

echo "=== Step 3: Set DNS search domains ==="
nmcli con mod "`$CONN_NAME" ipv4.dns-search "`$DNS_SEARCH"

echo "=== Step 4: Ignore auto-DNS from DHCP ==="
nmcli con mod "`$CONN_NAME" ipv4.ignore-auto-dns yes

echo "=== Step 5: Reapply connection settings ==="
nmcli device reapply eth0

echo "=== Step 6: Verification ==="
nmcli con show "`$CONN_NAME" | grep -E 'ipv4.dns|ipv4.ignore' || true
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf

echo "Network DNS configuration completed successfully."
"@

    try {
        Write-Log 'Executing network configuration via Run Command...'
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $RGName `
            -VMName            $VmName `
            -CommandId         'RunShellScript' `
            -ScriptString      $bashScript `
            -ErrorAction Stop

        # Value[0] = stdout, Value[1] = stderr (Run Command convention)
        $output = if ($result.Value.Count -gt 0) { $result.Value[0].Message } else { $null }
        $errOut = if ($result.Value.Count -gt 1) { $result.Value[1].Message } else { $null }

        if ($result.Status -eq 'Succeeded') {
            Write-Log "Run Command succeeded." 'SUCCESS'
            if ($output -and $output.Trim()) { Write-Log "Output:`n$output" 'INFO' }
            if ($errOut  -and $errOut.Trim())  { Write-Log "StdErr:`n$errOut" 'WARNING' }
            Write-Log '================================================'
            return $true
        }

        Write-Log "Run Command returned status: $($result.Status)" 'ERROR'
        if ($output -and $output.Trim()) { Write-Log "Output:`n$output" 'INFO' }
        if ($errOut -and $errOut.Trim())  { Write-Log "StdErr:`n$errOut" 'ERROR' }
        Write-Log '================================================'
        return $false
    }
    catch {
        Write-Log "Run Command failed: $_" 'ERROR'
        Write-Log '================================================'
        return $false
    }
}

#endregion

#region Main

Write-Log '=============================================='
Write-Log 'Linux VM Network DNS Configuration'
Write-Log "Mode         : $Mode"
Write-Log "DNS Servers  : $DNSServers"
Write-Log "DNS Search   : $DNSSearch"
Write-Log '=============================================='

if (-not (Test-AzureConnection)) { exit 1 }

switch ($Mode) {

    'Single' {
        if (-not $ResourceGroupName -or -not $VMName) {
            Write-Log 'Single mode requires -ResourceGroupName and -VMName.' 'ERROR'
            exit 1
        }

        $ok = Set-VMNetworkDNS `
            -SubId     $SubscriptionId `
            -RGName    $ResourceGroupName `
            -VmName    $VMName `
            -ConnName  $ConnectionName `
            -Dns       $DNSServers `
            -DnsSearch $DNSSearch

        exit $(if ($ok) { 0 } else { 1 })
    }

    'Bulk' {
        if (-not $CSVPath) {
            Write-Log 'Bulk mode requires -CSVPath.' 'ERROR'
            exit 1
        }

        $vmList = Import-NetworkConfigCSV -Path $CSVPath
        if (-not $vmList) { exit 1 }

        $total = $vmList.Count; $succeeded = 0; $failed = 0
        Write-Log "Processing $total VM(s)..."

        foreach ($entry in $vmList) {
            # Per-VM connection name override (optional CSV column)
            $entryConn = if ($entry.PSObject.Properties['ConnectionName'] -and $entry.ConnectionName) {
                $entry.ConnectionName
            } else {
                $ConnectionName
            }

            $result = Set-VMNetworkDNS `
                -SubId     $entry.SubscriptionId `
                -RGName    $entry.ResourceGroupName `
                -VmName    $entry.VMName `
                -ConnName  $entryConn `
                -Dns       $DNSServers `
                -DnsSearch $DNSSearch

            if ($result) { $succeeded++ } else { $failed++ }

            # Avoid hammering the Azure API
            Start-Sleep -Seconds 2
        }

        Write-Log '=============================================='
        Write-Log 'Bulk Network DNS Configuration Summary'
        Write-Log "Total: $total  |  Succeeded: $succeeded  |  Failed: $failed"
        Write-Log '=============================================='

        exit $(if ($failed -eq 0) { 0 } else { 1 })
    }
}

#endregion
