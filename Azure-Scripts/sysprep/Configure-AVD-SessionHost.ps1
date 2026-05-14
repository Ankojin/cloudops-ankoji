<#
.SYNOPSIS
    Post-deployment configuration for AVD session hosts created from golden image.

.DESCRIPTION
    This script configures newly deployed VMs from the generalized image:
    1. Joins the VM to Active Directory domain
    2. Downloads and installs Azure Virtual Desktop Agent
    3. Downloads and installs Azure Virtual Desktop Agent Bootloader
    4. Registers the VM with the specified AVD host pool using registration token

.PARAMETER VMName
    Name of the VM to configure (e.g., 'BABAVDSHDTA-5')

.PARAMETER ResourceGroupName
    Resource group containing the VM

.PARAMETER DomainName
    Active Directory domain name (e.g., 'bankalbilad.com.sa')

.PARAMETER DomainJoinUserName
    Domain admin username for joining (e.g., 'admin@bankalbilad.com.sa')

.PARAMETER DomainJoinPassword
    Secure password for domain join account

.PARAMETER OUPath
    Optional OU path for computer object (e.g., 'OU=AVD,OU=Computers,DC=bankalbilad,DC=com,DC=sa')

.PARAMETER HostPoolName
    AVD Host Pool name to join

.PARAMETER HostPoolResourceGroup
    Resource group containing the host pool

.PARAMETER RegistrationToken
    Host pool registration token (can be generated if not provided)

.PARAMETER SubscriptionId
    Azure subscription ID

.PARAMETER SkipDomainJoin
    Skip domain join (if already joined or not needed)

.EXAMPLE
    .\Configure-AVD-SessionHost.ps1 `
        -VMName "BABAVDSHDTA-5" `
        -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -DomainName "bankalbilad.com.sa" `
        -DomainJoinUserName "admin@bankalbilad.com.sa" `
        -DomainJoinPassword (ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force) `
        -HostPoolName "bab-avd-hostpool" `
        -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
        -SubscriptionId "your-subscription-id"

.EXAMPLE
    # With OU path and existing registration token
    .\Configure-AVD-SessionHost.ps1 `
        -VMName "BABAVDSHDTA-5" `
        -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -DomainName "bankalbilad.com.sa" `
        -DomainJoinUserName "admin@bankalbilad.com.sa" `
        -DomainJoinPassword $securePassword `
        -OUPath "OU=AVD,OU=Computers,DC=bankalbilad,DC=com,DC=sa" `
        -HostPoolName "bab-avd-hostpool" `
        -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
        -RegistrationToken "your-existing-token" `
        -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5"

.NOTES
    Author: BAB CloudOps Team
    Date: April 2026
    Requires: Az.Compute, Az.DesktopVirtualization modules
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [string]$DomainJoinUserName,

    [Parameter(Mandatory = $false)]
    [SecureString]$DomainJoinPassword,

    [Parameter(Mandatory = $false)]
    [string]$OUPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HostPoolResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$RegistrationToken,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDomainJoin
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
    
    # Append to log file
    $logFile = ".\logs\AVD-PostConfig-$(Get-Date -Format 'yyyyMMdd').log"
    $logMessage | Out-File -FilePath $logFile -Append -Encoding utf8
}

function Get-AVDAgentInstallerURLs {
    <#
    .SYNOPSIS
        Gets the latest download URLs for AVD agents
    #>
    [CmdletBinding()]
    param()
    
    # These are the official Microsoft download URLs
    # Updated as of April 2026
    return @{
        Agent = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"
        Bootloader = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH"
    }
}

#endregion

#region Main Script

try {
    # Initialize logging
    $logDir = ".\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Start-Transcript -Path "$logDir\AVD-PostConfig-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    Write-Log "=== Starting AVD Session Host Configuration ===" -Level Success
    Write-Log "VM: $VMName"
    Write-Log "Host Pool: $HostPoolName"
    
    # Set Azure context
    Write-Log "Setting Azure subscription context..."
    $null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue
    $context = Get-AzContext
    Write-Log "Connected to subscription: $($context.Subscription.Name)" -Level Success
    
    # Validate VM exists
    Write-Log "Validating VM exists..."
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
    Write-Log "VM found: $($vm.Id)" -Level Success
    
    #region Step 1: Domain Join
    
    if (-not $SkipDomainJoin) {
        if (-not $DomainName -or -not $DomainJoinUserName -or -not $DomainJoinPassword) {
            throw "Domain join parameters are required when SkipDomainJoin is not set"
        }
        
        Write-Log "=== Step 1: Joining VM to Domain ===" -Level Success
        Write-Log "Domain: $DomainName"
        
        if ($PSCmdlet.ShouldProcess($VMName, "Join to domain $DomainName")) {
            
            # Prepare domain join script
            $domainJoinScript = @"
`$domain = '$DomainName'
`$username = '$DomainJoinUserName'
`$passwordText = '$([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DomainJoinPassword)))'
`$password = ConvertTo-SecureString `$passwordText -AsPlainText -Force
`$credential = New-Object System.Management.Automation.PSCredential (`$username, `$password)

try {
    # Check if already domain joined
    `$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if (`$computerSystem.PartOfDomain -eq `$true) {
        Write-Host "Computer is already joined to domain: `$(`$computerSystem.Domain)"
        if (`$computerSystem.Domain -eq `$domain) {
            Write-Host "Already joined to correct domain, skipping..."
            exit 0
        }
    }
    
    Write-Host "Joining domain: `$domain"
    $(if ($OUPath) { "Add-Computer -DomainName `$domain -Credential `$credential -OUPath '$OUPath' -Force -ErrorAction Stop" } else { "Add-Computer -DomainName `$domain -Credential `$credential -Force -ErrorAction Stop" })
    Write-Host "✅ Domain join initiated successfully"
    
    # Domain join requires restart
    Write-Host "System will restart to complete domain join..."
    exit 3010
}
catch {
    Write-Error "Domain join failed: `$(`$_.Exception.Message)"
    exit 1
}
"@
            
            Write-Log "Executing domain join via Run Command..."
            $domainJoinResult = Invoke-AzVMRunCommand `
                -ResourceGroupName $ResourceGroupName `
                -VMName $VMName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $domainJoinScript `
                -ErrorAction Stop
            
            if ($domainJoinResult.Value[0].Message) {
                Write-Log "Domain join output: $($domainJoinResult.Value[0].Message)" -Level Info
            }
            
            # Check if restart is needed (exit code 3010)
            if ($domainJoinResult.Value[0].Message -match "exit 3010" -or $domainJoinResult.Value[0].Message -match "restart") {
                Write-Log "Restarting VM to complete domain join..." -Level Info
                Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -NoWait
                
                Write-Log "Waiting for VM to restart (60 seconds)..." -Level Info
                Start-Sleep -Seconds 60
                
                Write-Log "Waiting for VM to be ready..." -Level Info
                Start-Sleep -Seconds 30
            }
            
            Write-Log "Domain join completed successfully" -Level Success
        }
    }
    else {
        Write-Log "Skipping domain join (SkipDomainJoin flag set)" -Level Warning
    }
    
    #endregion
    
    #region Step 2: Get or Generate Registration Token
    
    Write-Log "=== Step 2: Obtaining Host Pool Registration Token ===" -Level Success
    
    if (-not $RegistrationToken) {
        Write-Log "No registration token provided, generating new token..."
        
        # Generate new registration token (valid for 24 hours)
        $tokenExpirationTime = (Get-Date).AddHours(24).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        
        $newToken = New-AzWvdRegistrationInfo `
            -ResourceGroupName $HostPoolResourceGroup `
            -HostPoolName $HostPoolName `
            -ExpirationTime $tokenExpirationTime `
            -ErrorAction Stop
        
        $RegistrationToken = $newToken.Token
        Write-Log "Registration token generated (expires: $tokenExpirationTime)" -Level Success
    }
    else {
        Write-Log "Using provided registration token" -Level Info
    }
    
    # Validate token
    if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
        throw "Registration token is empty or invalid"
    }
    
    Write-Log "Registration token obtained successfully" -Level Success
    
    #endregion
    
    #region Step 3: Install AVD Agents
    
    Write-Log "=== Step 3: Installing Azure Virtual Desktop Agents ===" -Level Success
    
    if ($PSCmdlet.ShouldProcess($VMName, "Install AVD Agent and Bootloader")) {
        
        # Get agent download URLs
        $agentURLs = Get-AVDAgentInstallerURLs
        Write-Log "Agent URL: $($agentURLs.Agent)" -Level Info
        Write-Log "Bootloader URL: $($agentURLs.Bootloader)" -Level Info
        
        # Prepare installation script
        $agentInstallScript = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'

# Create temp directory
`$tempDir = "C:\Temp\AVDAgents"
if (-not (Test-Path `$tempDir)) {
    New-Item -ItemType Directory -Path `$tempDir -Force | Out-Null
}

# Registration token
`$registrationToken = '$RegistrationToken'

Write-Host "=== Installing Azure Virtual Desktop Agents ==="

try {
    # Download AVD Agent
    Write-Host "Downloading AVD Agent..."
    `$agentInstaller = "`$tempDir\AVDAgent.msi"
    Invoke-WebRequest -Uri '$($agentURLs.Agent)' -OutFile `$agentInstaller -UseBasicParsing
    Write-Host "✅ Agent downloaded"
    
    # Unblock installers
    Unblock-File -Path `$agentInstaller -ErrorAction SilentlyContinue
    
    # Install AVD Agent
    Write-Host "Installing AVD Agent..."
    `$agentArgs = "/i ```"`$agentInstaller```" /quiet /qn /norestart REGISTRATIONTOKEN=```"`$registrationToken```" /l*v `$tempDir\AgentInstall.log"
    `$agentProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList `$agentArgs -Wait -PassThru -NoNewWindow
    
    if (`$agentProcess.ExitCode -eq 0 -or `$agentProcess.ExitCode -eq 3010) {
        Write-Host "✅ AVD Agent installed successfully (Exit Code: `$(`$agentProcess.ExitCode))"
    } else {
        throw "AVD Agent installation failed with exit code: `$(`$agentProcess.ExitCode)"
    }
    
    # Download AVD Bootloader
    Write-Host "Downloading AVD Agent Bootloader..."
    `$bootloaderInstaller = "`$tempDir\AVDBootloader.msi"
    Invoke-WebRequest -Uri '$($agentURLs.Bootloader)' -OutFile `$bootloaderInstaller -UseBasicParsing
    Write-Host "✅ Bootloader downloaded"
    
    Unblock-File -Path `$bootloaderInstaller -ErrorAction SilentlyContinue
    
    # Install AVD Bootloader
    Write-Host "Installing AVD Agent Bootloader..."
    `$bootloaderArgs = "/i ```"`$bootloaderInstaller```" /quiet /qn /norestart /l*v `$tempDir\BootloaderInstall.log"
    `$bootloaderProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList `$bootloaderArgs -Wait -PassThru -NoNewWindow
    
    if (`$bootloaderProcess.ExitCode -eq 0 -or `$bootloaderProcess.ExitCode -eq 3010) {
        Write-Host "✅ AVD Bootloader installed successfully (Exit Code: `$(`$bootloaderProcess.ExitCode))"
    } else {
        throw "AVD Bootloader installation failed with exit code: `$(`$bootloaderProcess.ExitCode)"
    }
    
    # Verify installations
    Write-Host "Verifying installations..."
    `$rdAgent = Get-Service -Name "RDAgentBootLoader" -ErrorAction SilentlyContinue
    if (`$rdAgent) {
        Write-Host "✅ RDAgentBootLoader service found: `$(`$rdAgent.Status)"
    } else {
        Write-Warning "RDAgentBootLoader service not found"
    }
    
    Write-Host "=== AVD Agent Installation Complete ==="
    Write-Host "Agent and Bootloader installed successfully!"
    Write-Host "VM is now registered with host pool: $HostPoolName"
    
} catch {
    Write-Error "Installation failed: `$(`$_.Exception.Message)"
    if (Test-Path "`$tempDir\AgentInstall.log") {
        Write-Host "Agent install log:"
        Get-Content "`$tempDir\AgentInstall.log" | Select-Object -Last 20
    }
    if (Test-Path "`$tempDir\BootloaderInstall.log") {
        Write-Host "Bootloader install log:"
        Get-Content "`$tempDir\BootloaderInstall.log" | Select-Object -Last 20
    }
    exit 1
}
"@
        
        Write-Log "Installing AVD agents on VM..."
        $installResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $agentInstallScript `
            -ErrorAction Stop
        
        if ($installResult.Value[0].Message) {
            Write-Log "Agent installation output:" -Level Info
            $installResult.Value[0].Message -split "`n" | ForEach-Object { Write-Log $_ -Level Info }
        }
        
        Write-Log "AVD agents installed successfully" -Level Success
    }
    
    #endregion
    
    #region Step 4: Verify Registration
    
    Write-Log "=== Step 4: Verifying Host Pool Registration ===" -Level Success
    
    Write-Log "Waiting for session host to appear in host pool (30 seconds)..." -Level Info
    Start-Sleep -Seconds 30
    
    $sessionHosts = Get-AzWvdSessionHost `
        -ResourceGroupName $HostPoolResourceGroup `
        -HostPoolName $HostPoolName `
        -ErrorAction SilentlyContinue
    
    $thisSessionHost = $sessionHosts | Where-Object { $_.Name -like "*$VMName*" }
    
    if ($thisSessionHost) {
        Write-Log "✅ Session host registered successfully!" -Level Success
        Write-Log "Session Host Name: $($thisSessionHost.Name)" -Level Info
        Write-Log "Status: $($thisSessionHost.Status)" -Level Info
        Write-Log "Last Heart Beat: $($thisSessionHost.LastHeartBeat)" -Level Info
    }
    else {
        Write-Log "Session host not found in host pool yet. This may take a few minutes." -Level Warning
        Write-Log "Check Azure Portal → AVD → Host Pools → $HostPoolName → Session Hosts" -Level Info
    }
    
    #endregion
    
    Write-Log "=== AVD Session Host Configuration Complete ===" -Level Success
    Write-Log "VM '$VMName' is now configured as an AVD session host" -Level Success
    if (-not $SkipDomainJoin) {
        Write-Log "Domain: $DomainName" -Level Success
    }
    Write-Log "Host Pool: $HostPoolName" -Level Success
    
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
