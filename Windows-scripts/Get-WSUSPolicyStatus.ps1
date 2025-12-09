<#
.SYNOPSIS
    Checks WSUS-related registry keys on multiple servers.

.PARAMETER ServerList
    Text file containing server names (one per line) OR CSV with "ServerName" column.

.EXAMPLE
    .\Get-WSUSPolicyStatus.ps1 -ServerList .\servers.txt

.EXAMPLE
    .\Get-WSUSPolicyStatus.ps1 -ServerList .\servers.csv
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$ServerList
)

# Load servers from file
if ($ServerList -like "*.csv") {
    $Servers = Import-CSV $ServerList | Select-Object -ExpandProperty ServerName
}
else {
    $Servers = Get-Content $ServerList
}

$Results = foreach ($Server in $Servers) {

    Write-Host "Checking $Server..." -ForegroundColor Cyan

    try {
        $WU = Invoke-Command -ComputerName $Server -ScriptBlock {
            $path1 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            $path2 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

            $out = [ordered]@{
                WUServer      = (Get-ItemProperty -Path $path1 -Name WUServer -ErrorAction SilentlyContinue).WUServer
                WUStatusServer= (Get-ItemProperty -Path $path1 -Name WUStatusServer -ErrorAction SilentlyContinue).WUStatusServer
                DisableDualScan = (Get-ItemProperty -Path $path1 -Name DisableDualScan -ErrorAction SilentlyContinue).DisableDualScan
                UseWUServer   = (Get-ItemProperty -Path $path2 -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
                NoAutoUpdate  = (Get-ItemProperty -Path $path2 -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
            }

            return $out
        }

        [PSCustomObject]@{
            Server         = $Server
            WUServer       = $WU.WUServer
            WUStatusServer = $WU.WUStatusServer
            DisableDualScan = $WU.DisableDualScan
            UseWUServer    = $WU.UseWUServer
            NoAutoUpdate   = $WU.NoAutoUpdate
            Status         = "Success"
        }
    }
    catch {
        [PSCustomObject]@{
            Server         = $Server
            WUServer       = $null
            WUStatusServer = $null
            DisableDualScan = $null
            UseWUServer    = $null
            NoAutoUpdate   = $null
            Status         = "ERROR: $_"
        }
    }
}

# Output in table form
$Results | Format-Table -AutoSize

# Save to CSV
$Timestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
$OutputFile = "WSUS-Policy-Report-$Timestamp.csv"

$Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`nReport saved to: $OutputFile" -ForegroundColor Green