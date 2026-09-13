<#
.SYNOPSIS
    Standalone test script for Windows – collects TCP connections + listening ports.
    Run this directly on a Windows VM (or jump box) to verify output format
    before using the full Azure Run Command collector.

.EXAMPLE
    .\Test-Collect-Windows.ps1
    .\Test-Collect-Windows.ps1 -IncludeListen
    .\Test-Collect-Windows.ps1 -OutputFile C:\Temp\win-test.csv
#>

[CmdletBinding()]
param(
    [string]$OutputFile = ".\Windows-Connections-Test.csv",
    [switch]$IncludeListen = $true
)

$ErrorActionPreference = "SilentlyContinue"
$results = @()

function Get-ProcInfo($id) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p) {
        return @{
            Name    = $p.ProcessName
            Path    = $p.Path
            Company = try { $p.Company } catch { "" }
        }
    }
    return @{ Name = "Unknown"; Path = ""; Company = "" }
}

# Well-known ports (same as main script)
$PortMap = @{
    22="SSH"; 80="HTTP"; 443="HTTPS"; 445="SMB / CIFS"
    1433="Microsoft SQL Server"; 1434="SQL Server Browser"
    1521="Oracle"; 3306="MySQL / MariaDB"; 3389="RDP"
    5432="PostgreSQL"; 5672="RabbitMQ / AMQP"; 5985="WinRM HTTP"
    5986="WinRM HTTPS"; 6379="Redis"; 8080="HTTP-Alt / App Server"
    8443="HTTPS-Alt"; 9200="Elasticsearch"; 27017="MongoDB"
    11211="Memcached"
}

Write-Host "Collecting established connections on $env:COMPUTERNAME ..." -ForegroundColor Cyan

$conns = Get-NetTCPConnection -State Established |
    Where-Object {
        $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::)$' -and
        $_.LocalAddress  -notmatch '^(127\.|::1)$'
    }

foreach ($c in $conns) {
    $info = Get-ProcInfo $c.OwningProcess
    $wellKnown = if ($PortMap.ContainsKey([int]$c.RemotePort)) { $PortMap[[int]$c.RemotePort] } else { $null }
    $detected  = if ($info.Name -and $info.Name -ne "Unknown") { $info.Name } else { $wellKnown }

    $results += [PSCustomObject]@{
        ComputerName   = $env:COMPUTERNAME
        OSType         = "Windows"
        RecordType     = "Connection"
        Direction      = "Outbound"
        LocalAddress   = $c.LocalAddress
        LocalPort      = $c.LocalPort
        RemoteAddress  = $c.RemoteAddress
        RemotePort     = $c.RemotePort
        State          = $c.State
        ProcessId      = $c.OwningProcess
        ProcessName    = $info.Name
        ProcessPath    = $info.Path
        ProcessCompany = $info.Company
        DetectedApp    = $detected
        WellKnownApp   = $wellKnown
        CollectedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

if ($IncludeListen) {
    Write-Host "Collecting listening ports ..." -ForegroundColor Cyan
    $listeners = Get-NetTCPConnection -State Listen |
        Where-Object { $_.LocalAddress -notmatch '^(127\.|::1)$' }

    foreach ($l in $listeners) {
        $info = Get-ProcInfo $l.OwningProcess
        $wellKnown = if ($PortMap.ContainsKey([int]$l.LocalPort)) { $PortMap[[int]$l.LocalPort] } else { $null }
        $detected  = if ($info.Name -and $info.Name -ne "Unknown") { $info.Name } else { $wellKnown }

        $results += [PSCustomObject]@{
            ComputerName   = $env:COMPUTERNAME
            OSType         = "Windows"
            RecordType     = "Listen"
            Direction      = "Listen"
            LocalAddress   = $l.LocalAddress
            LocalPort      = $l.LocalPort
            RemoteAddress  = ""
            RemotePort     = ""
            State          = "Listen"
            ProcessId      = $l.OwningProcess
            ProcessName    = $info.Name
            ProcessPath    = $info.Path
            ProcessCompany = $info.Company
            DetectedApp    = $detected
            WellKnownApp   = $wellKnown
            CollectedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Windows test collection complete" -ForegroundColor Green
Write-Host "Total records : $($results.Count)"
Write-Host "Connections   : $(($results | Where-Object RecordType -eq 'Connection').Count)"
Write-Host "Listening     : $(($results | Where-Object RecordType -eq 'Listen').Count)"
Write-Host "Output file   : $((Resolve-Path $OutputFile).Path)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Sample (first 8 rows):" -ForegroundColor Yellow
$results | Select-Object -First 8 ComputerName, RecordType, LocalPort, RemoteAddress, RemotePort, ProcessName, WellKnownApp |
    Format-Table -AutoSize
