
# Path to the text file containing server names (one per line)
$ServerListFile = "C:\Temp\Servers.txt"

# Read servers from file
$Servers = Get-Content -Path $ServerListFile

# Define log file path
$LogFile = "C:\Temp\SCCM_Removal_Log.txt"
$Summary = @()

# Script block to remove SCCM client components
$ScriptBlock = {
    param($LogFile)

    $ComputerName = $env:COMPUTERNAME
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Status = ""

    # Function to log messages
    function Write-Log {
        param($Message)
        Add-Content -Path $LogFile -Value "$Timestamp [$ComputerName] $Message"
    }

    Write-Host "Starting SCCM Client removal on $ComputerName" -ForegroundColor Cyan
    Write-Log "Starting SCCM Client removal"

    try {
        # Check if SCCM client exists
        if (Test-Path "$($Env:WinDir)\CCM") {
            Write-Log "SCCM Client detected. Proceeding with removal."
            
            # Remove SCCM folders
            Remove-Item -Path "$($Env:WinDir)\CCM" -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item -Path "$($Env:WinDir)\CCMCache" -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item -Path "$($Env:WinDir)\CCMSetup" -Force -Recurse -ErrorAction SilentlyContinue

            # Remove SCCM config file
            Remove-Item -Path "$($Env:WinDir)\smscfg.ini" -Force -ErrorAction SilentlyContinue

            # Remove SCCM certificates
            Remove-Item -Path 'HKLM:\Software\Microsoft\SystemCertificates\SMS\Certificates\*' -Force -ErrorAction SilentlyContinue

            # Remove SCCM registry keys
            $RegPaths = @(
                'HKLM:\SOFTWARE\Microsoft\CCM',
                'HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCM',
                'HKLM:\SOFTWARE\Microsoft\SMS',
                'HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS',
                'HKLM:\Software\Microsoft\CCMSetup',
                'HKLM:\Software\Wow6432Node\Microsoft\CCMSetup',
                'HKLM:\SYSTEM\CurrentControlSet\Services\CcmExec',
                'HKLM:\SYSTEM\CurrentControlSet\Services\ccmsetup'
            )
            foreach ($Path in $RegPaths) {
                Remove-Item -Path $Path -Force -Recurse -ErrorAction SilentlyContinue
            }

            # Remove WMI namespaces
            $Namespaces = @(
                @{Query="Select * From __Namespace Where Name='CCM'"; Namespace="root"},
                @{Query="Select * From __Namespace Where Name='CCMVDI'"; Namespace="root"},
                @{Query="Select * From __Namespace Where Name='SmsDm'"; Namespace="root"},
                @{Query="Select * From __Namespace Where Name='sms'"; Namespace="root\cimv2"}
            )
            foreach ($ns in $Namespaces) {
                Get-CimInstance -Query $ns.Query -Namespace $ns.Namespace | Remove-CimInstance -ErrorAction SilentlyContinue
            }

            Write-Host "SCCM Client removal completed on $ComputerName" -ForegroundColor Green
            Write-Log "SCCM Client removal completed successfully."
            $Status = "Success"
        }
        else {
            Write-Host "No SCCM Client found on $ComputerName" -ForegroundColor Yellow
            Write-Log "No SCCM Client found. Skipping removal."
            $Status = "Skipped"
        }
    }
    catch {
        Write-Host "Error removing SCCM Client on $ComputerName: $_" -ForegroundColor Red
        Write-Log "Error during removal: $_"
        $Status = "Failed"
    }

    # Return status for summary
    return [PSCustomObject]@{
        Server = $ComputerName
        Status = $Status
    }
}

# Execute on all servers and collect results
$Summary = Invoke-Command -ComputerName $Servers -ScriptBlock $ScriptBlock -ArgumentList $LogFile

# Display summary table
Write-Host "`n===== SCCM Removal Summary =====" -ForegroundColor Cyan
$Summary | Format-Table -AutoSize

# Export summary to CSV
$Summary | Export-Csv -Path "C:\Temp\SCCM_Removal_Summary.csv" -NoTypeInformation

Write-Host "`nProcess completed. Check log file at $LogFile and summary at C:\Temp\SCCM_Removal_Summary.csv" -ForegroundColor Cyan