# Define log file path
$logFilePath = "C:\WindowsAzure\postconf.txt"

# Start logging output to the specified file
Start-Transcript -Path $logFilePath -Append

# Function to log success and failure
function Log-Result ($taskDescription, $success) {
    if ($success) {
        Write-Output "$taskDescription - SUCCESS"
    } else {
        Write-Output "$taskDescription - FAILURE: $($Error[0])"
        $Error.Clear()
    }
}

# Check if the script is running with Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    # If not, re-launch PowerShell as Administrator
    Start-Process powershell -ArgumentList "-File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Set PowerShell to unrestricted mode (use with caution)
try {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force
    Log-Result "Set Execution Policy to Unrestricted" $true
} catch {
    Log-Result "Set Execution Policy to Unrestricted" $false
}

# Disable firewall for all profiles
try {
    Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
    Log-Result "Disable Firewall for All Profiles" $true
} catch {
    Log-Result "Disable Firewall for All Profiles" $false
}

# Set timezone
try {
    Set-TimeZone -Id "Arab Standard Time"
    Log-Result "Set Time Zone to Arab Standard Time" $true
} catch {
    Log-Result "Set Time Zone to Arab Standard Time" $false
}

########### Initialize (RAW) disks and create a new partition and format it ###########
# Define starting drive letter, skipping D and E
$driveLetter = [char]('D'[0])
# Initialize a counter for DataDisk volume names
$diskCounter = 1

# Get all uninitialized (RAW) disks
$disks = Get-Disk | Where-Object PartitionStyle -Eq 'RAW'

# Check if D: or E: drive letters are already in use
$existingDrives = Get-Volume | Select-Object -ExpandProperty DriveLetter
if ($existingDrives -contains 'D' -or $existingDrives -contains 'E') {
    Write-Output "Drive letters D: and/or E: are already in use. Skipping D: and E: and starting with F:."
    $driveLetter = [char]([int][char]'E' + 1) # Start with F: if D: and/or E: is in use
}

# Process each uninitialized disk
foreach ($disk in $disks) {
    # Generate a custom volume name with the drive letter and a sequential counter
    $volumeName = "DataDisk" + "{0:D2}" -f $diskCounter

    # Initialize the disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        Write-Output "Initialize Disk $($disk.Number)"
    } catch {
        Write-Output "Failed to Initialize Disk $($disk.Number)"
        continue
    }

    # Create a new partition and format it
    try {
        # Assign the current drive letter to the new partition
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $volumeName -Confirm:$false
        Write-Output "Partition and Format Disk $($disk.Number) with Volume Name '$volumeName' and Drive Letter '$driveLetter'"
    } catch {
        Write-Output "Failed to Partition and Format Disk $($disk.Number)"
        continue
    }

    # Increment the disk counter
    $diskCounter++

    # Move to the next drive letter by converting to ASCII, incrementing, and converting back to character
    $driveLetter = [char]([int][char]$driveLetter + 1)
}

Write-Output "All uninitialized disks have been processed."

#### Join to Domain with Key Vault Integration ####

# Define domain variables
$domain_name = "albtests.com"
$domain_user = "albtests\adjoin"

# Get Key Vault configuration from environment variables (set by pipeline)
$keyVaultName = $env:KEYVAULT_NAME
$keyVaultRG = $env:KEYVAULT_RG

Write-Output "Using Key Vault: $keyVaultName in Resource Group: $keyVaultRG"

# Initialize domain password variable
$domain_password = $null

# Try to retrieve password from Key Vault
try {
    Write-Output "Attempting to retrieve domain password from Key Vault..."
    
    # Install Az.KeyVault module if not present
    if (!(Get-Module -ListAvailable -Name Az.KeyVault)) {
        Write-Output "Installing Az.KeyVault module..."
        Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope CurrentUser
        Log-Result "Install Az.KeyVault Module" $true
    }
    
    # Install Az.Accounts module if not present
    if (!(Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Output "Installing Az.Accounts module..."
        Install-Module -Name Az.Accounts -Force -AllowClobber -Scope CurrentUser
        Log-Result "Install Az.Accounts Module" $true
    }
    
    # Connect using Managed Identity
    Write-Output "Connecting to Azure using Managed Identity..."
    Connect-AzAccount -Identity
    Log-Result "Connect to Azure with Managed Identity" $true
    
    # Retrieve password from Key Vault
    $keyVaultSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "adjoin-password"
    $domain_password = $keyVaultSecret.SecretValue
    Write-Output "Successfully retrieved domain password from Key Vault"
    Log-Result "Retrieve domain password from Key Vault" $true
    
} catch {
    Write-Output "Failed to retrieve password from Key Vault: $($_.Exception.Message)"
    Log-Result "Retrieve password from Key Vault" $false
    
    # Fallback to hardcoded password (for testing/emergency use)
    Write-Output "Using fallback hardcoded password"
    $domain_password = ConvertTo-SecureString "AdJo1n@!qaz@wsx" -AsPlainText -Force
    Log-Result "Using fallback password" $true
}

# Verify we have a password
if ($null -eq $domain_password) {
    Write-Output "ERROR: No domain password available. Cannot proceed with domain join."
    Log-Result "Domain password validation" $false
} else {
    Write-Output "Domain password successfully obtained"
    Log-Result "Domain password validation" $true
    
    # Create credential object
    $credential = New-Object System.Management.Automation.PSCredential($domain_user, $domain_password)
    
    # Join computer to domain with retry logic
    $maxRetries = 3
    $retryCount = 0
    $domainJoined = $false
    
    do {
        try {
            Write-Output "Attempting to join domain $domain_name (Attempt $($retryCount + 1)/$maxRetries)"
            Add-Computer -DomainName $domain_name -Credential $credential -Force -Restart
            $domainJoined = $true
            Log-Result "Join Computer to Domain $domain_name" $true
            break
        } catch {
            $retryCount++
            Write-Output "Domain join attempt $retryCount failed: $($_.Exception.Message)"
            Log-Result "Domain join attempt $retryCount" $false
            if ($retryCount -lt $maxRetries) {
                Write-Output "Retrying in 30 seconds..."
                Start-Sleep -Seconds 30
            }
        }
    } while ($retryCount -lt $maxRetries -and !$domainJoined)
    
    if (!$domainJoined) {
        Write-Output "Failed to join domain after $maxRetries attempts. Manual intervention may be required."
        Log-Result "Final domain join status" $false
    }
}

# Stop logging
Stop-Transcript