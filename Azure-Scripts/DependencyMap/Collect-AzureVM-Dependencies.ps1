<#
.SYNOPSIS
    Collects TCP connection + listening-port data from multiple Azure VMs
    (Windows + Linux) using Run Command.
    Accepts server list from CSV or TXT (IP or computer name).

.DESCRIPTION
    Input file formats supported:

    CSV example (servers.csv):
        Name,ResourceGroup
        app-web-01,rg-app
        10.10.2.25,rg-data
        cache-redis-01,

    TXT example (servers.txt) – one entry per line:
        app-web-01
        10.10.2.25
        cache-redis-01

    The script resolves names/IPs to running Azure VMs, then collects:
      - Established connections (inter-server traffic)
      - Listening ports (applications exposing services)
    Output is enriched with process name and well-known application mapping.

.NOTES
    Requires: Az.Accounts, Az.Compute
    PowerShell 7+ recommended for parallel execution
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    # ----- Input options (choose one) -----
    [Parameter(Mandatory = $false)]
    [string]$ServerListFile,                # Path to .csv or .txt

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceGroupNames,          # Alternative: scan whole RGs

    [Parameter(Mandatory = $false)]
    [string[]]$VMNames,                     # Alternative: explicit list

    # ----- Output / runtime -----
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\DependencyOutput",

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 5,

    [Parameter(Mandatory = $false)]
    [switch]$SkipListen
)

$ErrorActionPreference = "Stop"

# -------------------------------------------------
# Structured logging (never logs secret/credential values)
# -------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warning','Error','Success','Debug')]
        [string]$Level = 'Info'
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    switch ($Level) {
        'Info'    { Write-Host "[$ts] [INFO]    $Message" -ForegroundColor Cyan }
        'Warning' { Write-Warning "[$ts] $Message" }
        'Error'   { Write-Host "[$ts] [ERROR]   $Message" -ForegroundColor Red }
        'Success' { Write-Host "[$ts] [SUCCESS] $Message" -ForegroundColor Green }
        'Debug'   { Write-Verbose "[$ts] $Message" }
    }
}

# -------------------------------------------------
# Modules
# -------------------------------------------------
if (-not (Get-Module -ListAvailable Az.Compute)) {
    Write-Error "Az.Compute required. Run: Install-Module Az -Scope CurrentUser"
}
Import-Module Az.Accounts, Az.Compute -ErrorAction Stop

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$combinedCsv = Join-Path $OutputPath "AllConnections-$timestamp.csv"
$listenCsv   = Join-Path $OutputPath "ListeningPorts-$timestamp.csv"
$summaryCsv  = Join-Path $OutputPath "Summary-by-Connection-$timestamp.csv"

Write-Host "Output folder : $OutputPath" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------
# Well-known port map
# -------------------------------------------------
$script:PortMap = @{
    22="SSH"; 80="HTTP"; 443="HTTPS"; 445="SMB / CIFS"
    1433="Microsoft SQL Server"; 1434="SQL Server Browser"
    1521="Oracle"; 3306="MySQL / MariaDB"; 3389="RDP"
    5432="PostgreSQL"; 5672="RabbitMQ / AMQP"; 5985="WinRM HTTP"
    5986="WinRM HTTPS"; 6379="Redis"; 8080="HTTP-Alt / App Server"
    8443="HTTPS-Alt"; 9200="Elasticsearch"; 27017="MongoDB"
    11211="Memcached"; 2049="NFS"; 2375="Docker API"; 2376="Docker API (TLS)"
}

# -------------------------------------------------
# Guest scripts (Windows + Linux)
# -------------------------------------------------
$windowsScript = @'
$ErrorActionPreference = "SilentlyContinue"
$results = @()
function Get-Proc($id) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p) { return @{N=$p.ProcessName; P=$p.Path; C=$(try{$p.Company}catch{""})} }
    return @{N="Unknown";P="";C=""}
}
# Always gather this host's own listening ports first, regardless of
# SKIP_LISTEN, so established connections can be classified Inbound vs
# Outbound correctly. Without this every row was mislabeled "Outbound",
# even connections where this VM is the server being connected TO.
$listenPorts = [System.Collections.Generic.HashSet[int]]::new()
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    [void]$listenPorts.Add([int]$_.LocalPort)
}

$conns = Get-NetTCPConnection -State Established | Where-Object {
    $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::)$' -and
    $_.LocalAddress  -notmatch '^(127\.|::1)$'
}
foreach ($c in $conns) {
    $i = Get-Proc $c.OwningProcess
    $direction = if ($listenPorts.Contains([int]$c.LocalPort)) { "Inbound" } else { "Outbound" }
    $results += [PSCustomObject]@{
        ComputerName=$env:COMPUTERNAME; OSType="Windows"; RecordType="Connection"; Direction=$direction
        LocalAddress=$c.LocalAddress; LocalPort=$c.LocalPort
        RemoteAddress=$c.RemoteAddress; RemotePort=$c.RemotePort; State=$c.State
        ProcessId=$c.OwningProcess; ProcessName=$i.N; ProcessPath=$i.P; ProcessCompany=$i.C
        CollectedAt=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}
if ($env:SKIP_LISTEN -ne "true") {
    $listeners = Get-NetTCPConnection -State Listen | Where-Object { $_.LocalAddress -notmatch '^(127\.|::1)$' }
    foreach ($l in $listeners) {
        $i = Get-Proc $l.OwningProcess
        $results += [PSCustomObject]@{
            ComputerName=$env:COMPUTERNAME; OSType="Windows"; RecordType="Listen"; Direction="Listen"
            LocalAddress=$l.LocalAddress; LocalPort=$l.LocalPort
            RemoteAddress=""; RemotePort=""; State="Listen"
            ProcessId=$l.OwningProcess; ProcessName=$i.N; ProcessPath=$i.P; ProcessCompany=$i.C
            CollectedAt=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
}
$results | ConvertTo-Csv -NoTypeInformation
'@

$linuxScript = @'
#!/bin/bash
H=$(hostname); T=$(date +"%Y-%m-%d %H:%M:%S")
echo "ComputerName,OSType,RecordType,Direction,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessId,ProcessName,ProcessPath,ProcessCompany,CollectedAt"
# Own listening ports first (needed to tell Inbound from Outbound below)
LP=$(ss -tln 2>/dev/null | awk 'NR>1{split($4,a,":"); print a[2]}' | sort -u | tr '\n' ' ')
ss -tnp state established 2>/dev/null | awk -v h="$H" -v t="$T" -v lports=" $LP " '
function is_listening(p) { return index(lports, " " p " ") > 0 }
NR>1 {
  split($4,l,":"); split($5,r,":")
  if (l[1] ~ /^127\.|^::1/ || r[1] ~ /^127\.|^::1/) next
  p=""; id=""
  if ($6 ~ /users:\(\("/) { match($6,/users:\(\("([^"]+)",pid=([0-9]+)/,a); p=a[1]; id=a[2] }
  dir="Outbound"; if (is_listening(l[2])) dir="Inbound"
  printf "%s,Linux,Connection,%s,%s,%s,%s,%s,Established,%s,%s,,, %s\n",h,dir,l[1],l[2],r[1],r[2],id,p,t
}'
if [ "$SKIP_LISTEN" != "true" ]; then
ss -tlnp 2>/dev/null | awk -v h="$H" -v t="$T" '
NR>1 {
  split($4,l,":")
  if (l[1] ~ /^127\.|^::1/) next
  p=""; id=""
  if ($6 ~ /users:\(\("/) { match($6,/users:\(\("([^"]+)",pid=([0-9]+)/,a); p=a[1]; id=a[2] }
  printf "%s,Linux,Listen,Listen,%s,%s,,,Listen,%s,%s,,, %s\n",h,l[1],l[2],id,p,t
}'
fi
'@

# -------------------------------------------------
# Resolve server list → Azure VM objects
# -------------------------------------------------
function Get-TargetVMs {
    $targets = @()

    if ($ServerListFile) {
        if (-not (Test-Path $ServerListFile)) {
            Write-Error "Server list file not found: $ServerListFile"
        }
        $ext = [IO.Path]::GetExtension($ServerListFile).ToLower()
        Write-Host "Reading server list from $ServerListFile" -ForegroundColor Yellow

        if ($ext -eq ".csv") {
            $rows = Import-Csv -Path $ServerListFile
            # Accept columns: Name / ComputerName / IP / Server  (+ optional ResourceGroup)
            foreach ($row in $rows) {
                $name = $row.Name
                if (-not $name) { $name = $row.ComputerName }
                if (-not $name) { $name = $row.IP }
                if (-not $name) { $name = $row.Server }
                if (-not $name) { continue }
                $rg = $row.ResourceGroup
                $targets += [PSCustomObject]@{ Lookup = $name.Trim(); PreferredRG = $rg }
            }
        }
        else {  # .txt or any other text file
            Get-Content $ServerListFile | Where-Object { $_.Trim() -ne "" -and $_ -notmatch '^\s*#' } | ForEach-Object {
                $targets += [PSCustomObject]@{ Lookup = $_.Trim(); PreferredRG = $null }
            }
        }
    }
    elseif ($VMNames) {
        foreach ($n in $VMNames) {
            $targets += [PSCustomObject]@{ Lookup = $n; PreferredRG = $null }
        }
    }

    # Discover all running VMs once (for matching)
    Write-Host "Discovering running Azure VMs..." -ForegroundColor Yellow
    $allRunning = Get-AzVM -Status | Where-Object { $_.PowerState -eq "VM running" }
    if ($ResourceGroupNames) {
        $allRunning = $allRunning | Where-Object { $ResourceGroupNames -contains $_.ResourceGroupName }
    }

    if (-not $targets -or $targets.Count -eq 0) {
        # No explicit list → use all running (optionally filtered by RG)
        Write-Host "No server list provided – using all running VMs" -ForegroundColor Yellow
        return $allRunning
    }

    # Match each lookup value to a VM (by name or by private IP)
    $resolved = @()
    $nicCache = @{}

    foreach ($t in $targets) {
        $lookup = $t.Lookup
        $matched = $null

        # 1. Exact name match
        $matched = $allRunning | Where-Object { $_.Name -eq $lookup } | Select-Object -First 1

        # 2. Name contains
        if (-not $matched) {
            $matched = $allRunning | Where-Object { $_.Name -like "*$lookup*" } | Select-Object -First 1
        }

        # 3. Private IP match
        if (-not $matched -and $lookup -match '^\d{1,3}(\.\d{1,3}){3}$') {
            foreach ($vm in $allRunning) {
                $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
                if (-not $nicCache.ContainsKey($nicId)) {
                    try {
                        $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                        $nicCache[$nicId] = $nic.IpConfigurations.PrivateIpAddress
                    } catch { $nicCache[$nicId] = $null }
                }
                if ($nicCache[$nicId] -eq $lookup) {
                    $matched = $vm
                    break
                }
            }
        }

        if ($matched) {
            Write-Host "  Resolved '$lookup' → $($matched.Name) ($($matched.ResourceGroupName))" -ForegroundColor Green
            $resolved += $matched
        }
        else {
            Write-Warning "  Could not resolve '$lookup' to a running Azure VM"
        }
    }

    # Deduplicate
    $resolved = $resolved | Sort-Object Id -Unique
    return $resolved
}

$vms = Get-TargetVMs

if (-not $vms -or $vms.Count -eq 0) {
    Write-Warning "No running VMs to process."
    return
}

Write-Host ""
Write-Host "Will collect from $($vms.Count) VM(s):" -ForegroundColor Green
$vms | Select-Object Name, ResourceGroupName, @{N='OS';E={$_.StorageProfile.OsDisk.OsType}} | Format-Table -AutoSize
Write-Host ""

# -------------------------------------------------
# Collection function
# -------------------------------------------------
function Invoke-DependencyCollection {
    param($VM)
    $rg = $VM.ResourceGroupName; $name = $VM.Name
    $os = $VM.StorageProfile.OsDisk.OsType.ToString()

    Write-Log "[$name] Collecting ($os)..." -Level Info
    try {
        if ($os -eq "Windows") {
            $params = @{}
            if ($SkipListen) { $params["SKIP_LISTEN"] = "true" }
            $result = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $name `
                -CommandId "RunPowerShellScript" -ScriptString $windowsScript `
                -Parameter $params -ErrorAction Stop
            $output = $result.Value[0].Message
        }
        else {
            $envLine = if ($SkipListen) { "export SKIP_LISTEN=true`n" } else { "" }
            $result = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $name `
                -CommandId "RunShellScript" -ScriptString ($envLine + $linuxScript) -ErrorAction Stop
            $output = $result.Value[0].Message
        }

        $safe = $name -replace '[\\/:*?"<>|]', '_'
        $output | Out-File (Join-Path $OutputPath "$safe-$timestamp.csv") -Encoding utf8

        $header = "ComputerName,OSType,RecordType,Direction,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessId,ProcessName,ProcessPath,ProcessCompany,CollectedAt"
        $lines = $output -split "`n" | Where-Object { $_ -match "," -and $_ -notmatch "^ComputerName," }
        $objs = @()
        foreach ($line in $lines) {
            if ($line.Trim()) {
                try { $objs += ($header + "`n" + $line) | ConvertFrom-Csv } catch {}
            }
        }
        Write-Host "[$name] OK – $($objs.Count) records" -ForegroundColor Green
        return $objs
    }
    catch {
        Write-Warning "[$name] Failed: $($_.Exception.Message)"
        return @()
    }
}

# -------------------------------------------------
# Execute
# -------------------------------------------------
if (-not $PSCmdlet.ShouldProcess("$($vms.Count) VM(s) in $OutputPath", "Invoke Run Command dependency collection and write CSV output")) {
    Write-Log "WhatIf: no Run Commands invoked, no files written." -Level Warning
    return
}

$allResults = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Log "Running in parallel (Throttle=$ThrottleLimit)..." -Level Info
    # NOTE: ForEach-Object -Parallel executes each iteration in an isolated
    # runspace. Functions and variables from the caller's scope (other than
    # via $using:) are NOT visible there - calling Invoke-DependencyCollection
    # directly (as the original script did) fails at runtime. The collection
    # logic is inlined here instead, with every outer dependency passed via
    # $using:.
    $vms | ForEach-Object -Parallel {
        $vm = $_
        $bag = $using:allResults
        $winScript = $using:windowsScript
        $linScript = $using:linuxScript
        $outPath = $using:OutputPath
        $ts = $using:timestamp
        $skipListen = $using:SkipListen

        $rg = $vm.ResourceGroupName; $name = $vm.Name
        $os = $vm.StorageProfile.OsDisk.OsType.ToString()
        Write-Host "[$name] Collecting ($os)..." -ForegroundColor Cyan
        try {
            if ($os -eq "Windows") {
                $params = @{}
                if ($skipListen) { $params["SKIP_LISTEN"] = "true" }
                $result = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $name `
                    -CommandId "RunPowerShellScript" -ScriptString $winScript `
                    -Parameter $params -ErrorAction Stop
                $output = $result.Value[0].Message
            }
            else {
                $envLine = if ($skipListen) { "export SKIP_LISTEN=true`n" } else { "" }
                $result = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $name `
                    -CommandId "RunShellScript" -ScriptString ($envLine + $linScript) -ErrorAction Stop
                $output = $result.Value[0].Message
            }

            $safe = $name -replace '[\\/:*?"<>|]', '_'
            $output | Out-File (Join-Path $outPath "$safe-$ts.csv") -Encoding utf8

            $header = "ComputerName,OSType,RecordType,Direction,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessId,ProcessName,ProcessPath,ProcessCompany,CollectedAt"
            $lines = $output -split "`n" | Where-Object { $_ -match "," -and $_ -notmatch "^ComputerName," }
            $count = 0
            foreach ($line in $lines) {
                if ($line.Trim()) {
                    try {
                        $obj = ($header + "`n" + $line) | ConvertFrom-Csv
                        $bag.Add($obj)
                        $count++
                    } catch {}
                }
            }
            Write-Host "[$name] OK - $count records" -ForegroundColor Green
        }
        catch {
            Write-Warning "[$name] Failed: $($_.Exception.Message)"
        }
    } -ThrottleLimit $ThrottleLimit
}
else {
    Write-Log "Running sequentially..." -Level Info
    foreach ($vm in $vms) {
        $res = Invoke-DependencyCollection -VM $vm
        foreach ($r in $res) { $allResults.Add($r) }
    }
}

if ($allResults.Count -eq 0) {
    Write-Warning "No data collected."
    return
}

# -------------------------------------------------
# Enrich + write outputs
# -------------------------------------------------
$enriched = foreach ($r in $allResults) {
    $port = if ($r.RecordType -eq "Listen") { [int]$r.LocalPort } else { [int]$r.RemotePort }
    $wellKnown = if ($script:PortMap.ContainsKey($port)) { $script:PortMap[$port] } else { $null }
    $detected = if ($r.ProcessName -and $r.ProcessName -notin @("","Unknown")) { $r.ProcessName } else { $wellKnown }

    [PSCustomObject]@{
        ComputerName   = $r.ComputerName
        OSType         = $r.OSType
        RecordType     = $r.RecordType
        Direction      = $r.Direction
        LocalAddress   = $r.LocalAddress
        LocalPort      = $r.LocalPort
        RemoteAddress  = $r.RemoteAddress
        RemotePort     = $r.RemotePort
        State          = $r.State
        ProcessId      = $r.ProcessId
        ProcessName    = $r.ProcessName
        ProcessPath    = $r.ProcessPath
        ProcessCompany = $r.ProcessCompany
        DetectedApp    = $detected
        WellKnownApp   = $wellKnown
        CollectedAt    = $r.CollectedAt
    }
}

$enriched | Export-Csv $combinedCsv -NoTypeInformation -Encoding UTF8

$listening = $enriched | Where-Object RecordType -eq "Listen"
if ($listening) { $listening | Export-Csv $listenCsv -NoTypeInformation -Encoding UTF8 }

# Pre-grouped summary by connection (Source → Destination:Port + App + Direction).
# Direction is included in the grouping key so Inbound and Outbound edges are
# reported as separate rows rather than being merged together - otherwise you
# can't tell "this VM calls the DB" from "this VM IS the DB being called".
$connections = $enriched | Where-Object { $_.RecordType -eq "Connection" -and $_.RemoteAddress -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' }
$grouped = $connections | Group-Object ComputerName, Direction, RemoteAddress, RemotePort | ForEach-Object {
    $g = $_.Group[0]
    [PSCustomObject]@{
        SourceVM        = $g.ComputerName
        SourceIP        = $g.LocalAddress
        Direction       = $g.Direction
        DestinationIP   = $g.RemoteAddress
        DestinationPort = $g.RemotePort
        WellKnownApp    = $g.WellKnownApp
        DetectedApp     = $g.DetectedApp
        ProcessName     = ($_.Group.ProcessName | Select-Object -Unique) -join ", "
        ConnectionCount = $_.Count
        SampleProcessPath = $g.ProcessPath
    }
} | Sort-Object SourceVM, Direction, DestinationIP, DestinationPort

$grouped | Export-Csv $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Collection complete" -ForegroundColor Green
Write-Host "Total records          : $($enriched.Count)"
Write-Host "Listening ports        : $($listening.Count)"
Write-Host "Unique private connections : $($grouped.Count)"
Write-Host ""
Write-Host "Files created:" -ForegroundColor Cyan
Write-Host "  $combinedCsv"
if ($listening) { Write-Host "  $listenCsv" }
Write-Host "  $summaryCsv   ← already grouped by connection (import this into Excel)"
Write-Host "========================================" -ForegroundColor Green