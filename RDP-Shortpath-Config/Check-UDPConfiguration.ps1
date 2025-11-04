# Check-UDPConfiguration.ps1
# Script to check UDP configuration on session hosts and client devices
# Author: BAB CloudOps Team
# Date: November 3, 2025

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("SessionHost", "Client", "Both")]
    [string]$CheckType = "Both",
    
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerNames = @("localhost"),
    
    [Parameter(Mandatory=$false)]
    [switch]$WriteToFile
)

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "Info" { Write-Host $logMessage -ForegroundColor Green }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error" { Write-Host $logMessage -ForegroundColor Red }
    }
    
    if ($WriteToFile) {
        $logMessage | Out-File -FilePath "UDP-Configuration-Check.log" -Append
    }
}

function Test-SessionHostUDP {
    param([string]$ComputerName)
    
    Write-LogMessage "Checking UDP configuration on session host: $ComputerName"
    
    try {
        $scriptBlock = {
            $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue
            
            if ($regKey -and $regKey.PSObject.Properties.name -contains "SelectTransport") {
                $transportValue = $regKey.SelectTransport
                switch ($transportValue) {
                    1 { return @{Status = "TCP_Only"; Message = "RDP transport is set to TCP only - UDP is disabled" } }
                    2 { return @{Status = "UDP_TCP"; Message = "RDP transport is set to use both UDP and TCP" } }
                    default { return @{Status = "Unknown"; Message = "Unknown transport setting: $transportValue" } }
                }
            } else {
                return @{Status = "Default"; Message = "RDP transport is using default settings - UDP is enabled" }
            }
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        Write-LogMessage "Session Host UDP Status: $($result.Message)" -Level $(if ($result.Status -eq "TCP_Only") { "Warning" } else { "Info" })
        return $result
        
    } catch {
        Write-LogMessage "Error checking session host UDP configuration: $($_.Exception.Message)" -Level "Error"
        return @{Status = "Error"; Message = $_.Exception.Message }
    }
}

function Test-ClientUDP {
    param([string]$ComputerName)
    
    Write-LogMessage "Checking UDP configuration on client: $ComputerName"
    
    try {
        $scriptBlock = {
            $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client" -ErrorAction SilentlyContinue
            
            if ($regKey -and $regKey.PSObject.Properties.name -contains "fClientDisableUDP") {
                $udpValue = $regKey.fClientDisableUDP
                switch ($udpValue) {
                    1 { return @{Status = "Disabled"; Message = "UDP is disabled on client" } }
                    0 { return @{Status = "Enabled"; Message = "UDP is enabled on client" } }
                    default { return @{Status = "Unknown"; Message = "Unknown UDP setting: $udpValue" } }
                }
            } else {
                return @{Status = "Default"; Message = "Client UDP is using default settings - UDP is enabled" }
            }
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        Write-LogMessage "Client UDP Status: $($result.Message)" -Level $(if ($result.Status -eq "Disabled") { "Warning" } else { "Info" })
        return $result
        
    } catch {
        Write-LogMessage "Error checking client UDP configuration: $($_.Exception.Message)" -Level "Error"
        return @{Status = "Error"; Message = $_.Exception.Message }
    }
}

function Test-RDPShortpathListener {
    param([string]$ComputerName)
    
    Write-LogMessage "Checking RDP Shortpath listener configuration on: $ComputerName"
    
    try {
        $scriptBlock = {
            $regKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue
            
            $listenerEnabled = $false
            $listenerPort = 3390
            
            if ($regKey -and $regKey.PSObject.Properties.name -contains "fUseUdpPortRedirector") {
                $listenerEnabled = $regKey.fUseUdpPortRedirector -eq 1
            }
            
            if ($regKey -and $regKey.PSObject.Properties.name -contains "UdpPortNumber") {
                $listenerPort = $regKey.UdpPortNumber
            }
            
            return @{
                Enabled = $listenerEnabled
                Port = $listenerPort
                Message = if ($listenerEnabled) { "RDP Shortpath listener is enabled on port $listenerPort" } else { "RDP Shortpath listener is not enabled" }
            }
        }
        
        if ($ComputerName -eq "localhost") {
            $result = & $scriptBlock
        } else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock
        }
        
        Write-LogMessage "RDP Shortpath Listener: $($result.Message)" -Level $(if ($result.Enabled) { "Info" } else { "Warning" })
        return $result
        
    } catch {
        Write-LogMessage "Error checking RDP Shortpath listener: $($_.Exception.Message)" -Level "Error"
        return @{Enabled = $false; Port = 0; Message = $_.Exception.Message }
    }
}

# Main execution
Write-LogMessage "Starting UDP configuration check..." -Level "Info"
Write-LogMessage "Check Type: $CheckType" -Level "Info"
Write-LogMessage "Target Computers: $($ComputerNames -join ', ')" -Level "Info"

$results = @()

foreach ($computer in $ComputerNames) {
    Write-LogMessage "Processing computer: $computer" -Level "Info"
    
    $computerResult = @{
        ComputerName = $computer
        SessionHost = $null
        Client = $null
        Listener = $null
    }
    
    if ($CheckType -in @("SessionHost", "Both")) {
        $computerResult.SessionHost = Test-SessionHostUDP -ComputerName $computer
        $computerResult.Listener = Test-RDPShortpathListener -ComputerName $computer
    }
    
    if ($CheckType -in @("Client", "Both")) {
        $computerResult.Client = Test-ClientUDP -ComputerName $computer
    }
    
    $results += $computerResult
}

# Display summary
Write-LogMessage "`n=== CONFIGURATION SUMMARY ===" -Level "Info"
foreach ($result in $results) {
    Write-LogMessage "Computer: $($result.ComputerName)" -Level "Info"
    
    if ($result.SessionHost) {
        Write-LogMessage "  Session Host UDP: $($result.SessionHost.Status)" -Level "Info"
    }
    
    if ($result.Listener) {
        Write-LogMessage "  RDP Shortpath Listener: $(if ($result.Listener.Enabled) { 'Enabled' } else { 'Disabled' })" -Level "Info"
        if ($result.Listener.Enabled) {
            Write-LogMessage "  Listener Port: $($result.Listener.Port)" -Level "Info"
        }
    }
    
    if ($result.Client) {
        Write-LogMessage "  Client UDP: $($result.Client.Status)" -Level "Info"
    }
    
    Write-LogMessage "" -Level "Info"
}

Write-LogMessage "UDP configuration check completed." -Level "Info"

# Return results for further processing
return $results