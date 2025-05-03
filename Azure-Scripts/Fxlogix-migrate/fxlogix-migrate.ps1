# Set source and destination Azure Storage Account details
$sourceStorageAccountName = "sourceStorageAccount"  # Replace with your source storage account name
$destinationStorageAccountName = "destinationStorageAccount"  # Replace with your destination storage account name
$containerName = "fslogixprofiles"  # Replace with the container name where profiles are stored

# Set your storage account access keys
$sourceStorageKey = "sourceStorageAccountKey"  # Replace with your source storage account key
$destinationStorageKey = "destinationStorageAccountKey"  # Replace with your destination storage account key

# Set Azure Storage contexts for both source and destination
$sourceContext = New-AzStorageContext -StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageKey
$destinationContext = New-AzStorageContext -StorageAccountName $destinationStorageAccountName -StorageAccountKey $destinationStorageKey

# Set the domain name for your on-prem AD
$domain = "NewDomain"  # Replace with your on-prem AD domain name

# Log file setup
$logFilePath = "C:\fslogix_migration_log.txt"
$startTime = Get-Date
Add-Content -Path $logFilePath -Value "`nMigration started at: $startTime"

# Get all users from the new domain (on-prem AD) whose usernames end with "*-E"
$users = Get-ADUser -Filter {SamAccountName -like "*-E"} -Property SamAccountName

foreach ($user in $users) {
    $username = $user.SamAccountName
    try {
        # Get the new domain SID for the user
        $newSID = (New-Object System.Security.Principal.NTAccount("$domain\$username")).Translate([System.Security.Principal.SecurityIdentifier]).Value
        
        # Define the old blob file path in the source Azure Storage Account (from Entra domain)
        $oldBlobPath = "EntraDomain/$username*.vhdx"
        
        # Log progress
        Add-Content -Path $logFilePath -Value "Processing user: $username"
        
        # If the profile file exists in the source container (Entra domain)
        $oldBlob = Get-AzStorageBlob -Container $containerName -Blob $oldBlobPath -Context $sourceContext -ErrorAction SilentlyContinue
        
        if ($oldBlob) {
            # Define the new blob path in the destination Azure Storage Account (On-prem domain)
            $newBlobName = "$username" + "_$newSID.vhdx"
            $newBlobPath = "OnPremDomain/$newBlobName"
            
            # Start copying the old blob (profile file) to the new destination storage account
            Start-AzStorageBlobCopy -SrcBlob $oldBlob.Name -SrcContainer $containerName -DestBlob $newBlobName -DestContainer $containerName -SrcContext $sourceContext -DestContext $destinationContext
            
            # Wait for the copy operation to complete
            $copyStatus = Get-AzStorageBlobCopyState -Container $containerName -Blob $newBlobName -Context $destinationContext
            while ($copyStatus.Status -eq "Pending") {
                Start-Sleep -Seconds 5
                $copyStatus = Get-AzStorageBlobCopyState -Container $containerName -Blob $newBlobName -Context $destinationContext
            }
            
            if ($copyStatus.Status -eq "Success") {
                # Log success
                $message = "Successfully migrated profile for $username to $newBlobName."
                Add-Content -Path $logFilePath -Value $message
                Write-Host $message
            } else {
                # Log failure
                $message = "Blob copy failed for $username."
                Add-Content -Path $logFilePath -Value $message
                Write-Host $message
            }
        } else {
            # Log missing profile file
            $message = "Profile file for $username not found in the source storage container."
            Add-Content -Path $logFilePath -Value $message
            Write-Host $message
        }
    } catch {
        # Log error
        $errorMessage = "Error processing user $username: $_"
        Add-Content -Path $logFilePath -Value $errorMessage
        Write-Host $errorMessage
    }
}

# End migration and log the end time
$endTime = Get-Date
$duration = $endTime - $startTime
$completionMessage = "`nMigration completed at: $endTime. Duration: $($duration.Hours) hours, $($duration.Minutes) minutes, $($duration.Seconds) seconds."
Add-Content -Path $logFilePath -Value $completionMessage
Write-Host $completionMessage

# OPTIONAL: Generate and provide a SAS token for the new profiles in the destination account
# If you want to grant access to the new domain user, generate a SAS token (example for read access):
function Generate-SasToken {
    param (
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName
    )
    
    # Set context to the destination storage account
    $context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $destinationStorageKey
    
    # Generate a SAS token for the specified blob
    $sasToken = New-AzStorageBlobSASToken -Container $containerName -Blob $blobName -Context $context -Permission r -ExpiryTime (Get-Date).AddDays(7)
    
    return $sasToken
}

# Example usage of SAS token generation (for the new blob):
# $sasToken = Generate-SasToken -storageAccountName $destinationStorageAccountName -containerName "OnPremDomain" -blobName "$newBlobName"
# Write-Host "Generated SAS token: $sasToken"