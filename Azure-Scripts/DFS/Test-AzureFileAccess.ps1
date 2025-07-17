# Define variables
$DfsPath = "\\DASTGFSDFSWV1.albtests.com\babcorestrgacctfs01\albusrfs01"
$StorageAccountFQDN = "babcorestrgacctfs01.file.core.windows.net"
$FileShare = "albusrfs01"
$AzureShareUNC = "\\$StorageAccountFQDN\$FileShare"

Write-Host "=== DFS Path Test ==="
if (Test-Path $DfsPath) {
    Write-Host "✅ DFS path reachable: $DfsPath"
} else {
    Write-Host "❌ Cannot access DFS path: $DfsPath"
}

Write-Host "`n=== Direct Azure File Share Access Test ==="
if (Test-Path $AzureShareUNC) {
    Write-Host "✅ Azure File Share directly accessible: $AzureShareUNC"
} else {
    Write-Host "❌ Cannot access Azure File Share: $AzureShareUNC"
}

Write-Host "`n=== Port 445 Test to Azure File Storage ==="
$portTest = Test-NetConnection -ComputerName $StorageAccountFQDN -Port 445
if ($portTest.TcpTestSucceeded) {
    Write-Host "✅ Port 445 reachable to $StorageAccountFQDN"
} else {
    Write-Host "❌ Port 445 blocked to $StorageAccountFQDN"
}

Write-Host "`n=== Kerberos Ticket Check ==="
$klistOutput = klist
if ($klistOutput | Select-String -Pattern "cifs/$StorageAccountFQDN") {
    Write-Host "✅ Kerberos ticket for Azure File Share present"
} else {
    Write-Host "⚠️ No Kerberos ticket for Azure File Share found"
    Write-Host "   → Ensure you're using domain-joined client with AADDS"
}

Write-Host "`n=== Final Notes ==="
Write-Host " - DFS path: $DfsPath"
Write-Host " - Azure UNC path: $AzureShareUNC"
Write-Host " - Ensure user has:"
Write-Host "   • RBAC: 'Storage File Data SMB Share Reader/Contributor'"
Write-Host "   • NTFS Permissions on the share"
Write-Host "   • Synced to Microsoft Entra Domain Services"