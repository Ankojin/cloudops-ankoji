# Define log file path
$logFilePath = "C:\WindowsAzure\postconf.txt"

# Start logging output to the specified file
Start-Transcript -Path $logFilePath -Append

# Function to log success and failure
function Write-Result ($taskDescription, $success) {
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

# Set PowerShell to RemoteSigned mode (more secure than Unrestricted)
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force
    Write-Result "Set Execution Policy to RemoteSigned" $true
} catch {
    Write-Result "Set Execution Policy to RemoteSigned" $false
}

# Disable firewall for all profiles
try {
    Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
    Write-Result "Disable Firewall for All Profiles" $true
} catch {
    Write-Result "Disable Firewall for All Profiles" $false
}

# Set timezone
try {
    Set-TimeZone -Id "Arab Standard Time"
    Write-Result "Set Time Zone to Arab Standard Time" $true
} catch {
    Write-Result "Set Time Zone to Arab Standard Time" $false
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

    Write-Output "Processing disk $($disk.Number) - Size: $([math]::Round($disk.Size/1GB,2)) GB"

    # Initialize the disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Force
        Write-Output "Successfully initialized disk $($disk.Number)"
        Write-Result "Initialize Disk $($disk.Number)" $true
    } catch {
        Write-Output "Failed to initialize disk $($disk.Number): $($_.Exception.Message)"
        Write-Result "Initialize Disk $($disk.Number)" $false
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

#### Network Configuration ####
try {
    # Set DNS search suffix for domain
    $searchSuffix = "albtests.com"
    Set-DnsClientGlobalSetting -SuffixSearchList $searchSuffix
    Write-Output "Set DNS search suffix to: $searchSuffix"
    Write-Result "Configure DNS Search Suffix" $true
} catch {
    Write-Output "Failed to set DNS search suffix: $($_.Exception.Message)"
    Write-Result "Configure DNS Search Suffix" $false
}

#### Join to Domain with Enhanced Security ####

# Define domain variables
$domain_name = "albtests.com"
$domain_user = "albtests\adjoin"

# Get Key Vault configuration from environment variables (set by pipeline)
$keyVaultName = $env:KEYVAULT_NAME
$keyVaultRG = $env:KEYVAULT_RG

# Validate Key Vault environment variables
if (-not $keyVaultName) {
    Write-Output "ERROR: KEYVAULT_NAME environment variable not set"
    Write-Result "Key Vault Name Environment Variable Check" $false
} else {
    Write-Output "Using Key Vault: $keyVaultName in Resource Group: $keyVaultRG"
    Write-Result "Key Vault Environment Variables Loaded" $true
}

# OPTION 1: Use Azure Key Vault (Recommended for Production)
try {
    Write-Output "Attempting to retrieve domain password from Key Vault..."
    
    # Install Az.KeyVault module if not present
    if (!(Get-Module -ListAvailable -Name Az.KeyVault)) {
        Write-Output "Installing Az.KeyVault module..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope CurrentUser -Repository PSGallery
        Write-Result "Install Az.KeyVault Module" $true
    } else {
        Write-Output "Az.KeyVault module already available"
    }
    
    # Install Az.Accounts module if not present
    if (!(Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Output "Installing Az.Accounts module..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-Module -Name Az.Accounts -Force -AllowClobber -Scope CurrentUser -Repository PSGallery
        Write-Result "Install Az.Accounts Module" $true
    } else {
        Write-Output "Az.Accounts module already available"
    }
    
    # Connect using Managed Identity
    Write-Output "Connecting to Azure using Managed Identity..."
    Connect-AzAccount -Identity
    Write-Result "Connect to Azure with Managed Identity" $true
    
    # Retrieve password from Key Vault
    $keyVaultSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "adjoin-password"
    $domain_password = $keyVaultSecret.SecretValue
    Write-Output "Successfully retrieved domain password from Key Vault"
    Write-Result "Retrieved domain password from Key Vault" $true
    
} catch {
    Write-Output "Failed to retrieve password from Key Vault: $($_.Exception.Message)"
    Write-Result "Failed to retrieve password from Key Vault" $false
    
    # OPTION 2: Fallback to hardcoded password (not recommended for production)
    Write-Output "Using fallback hardcoded password for domain join"
    $domain_password = ConvertTo-SecureString "AdJo1n@!qaz@wsx" -AsPlainText -Force
    Write-Result "Using fallback hardcoded password" $true
}

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
        Write-Result "Join Computer to Domain $domain_name" $true
        break
    } catch {
        $retryCount++
        Write-Result "Domain join attempt $retryCount failed" $false
        if ($retryCount -lt $maxRetries) {
            Write-Output "Retrying in 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
} while ($retryCount -lt $maxRetries -and !$domainJoined)

if (!$domainJoined) {
    Write-Output "Failed to join domain after $maxRetries attempts. Manual intervention may be required."
    Write-Result "Final domain join status" $false
}

# Stop logging
Stop-Transcript