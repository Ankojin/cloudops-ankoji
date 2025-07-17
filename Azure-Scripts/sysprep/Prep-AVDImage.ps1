# -----------------------
# STEP 1: PREPARE THE VM
# -----------------------

Write-Host "🔧 Disabling Windows Update..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled
New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null

# -----------------------
# DOMAIN UNJOIN
# -----------------------
Write-Host "🔄 Checking domain membership..."
$ComputerInfo = Get-WmiObject -Class Win32_ComputerSystem
if ($ComputerInfo.PartOfDomain) {
    Write-Host "Attempting to unjoin domain silently..."
    try {
        Add-Computer -WorkGroupName "WORKGROUP" -Force -PassThru
        Write-Host "✅ Unjoined successfully. Restarting VM..."
        Restart-Computer -Force
        return
    } catch {
        Write-Warning "❌ Failed to unjoin domain silently. Manual action may be required."
        exit 1
    }
} else {
    Write-Host "✅ VM already in a workgroup."
}

# -----------------------
# CLEANUP TEMP + LOGS
# -----------------------
Write-Host "🧹 Cleaning up temporary files and logs..."
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
wevtutil el | ForEach-Object { wevtutil cl $_ } 2>$null
RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 255

# -----------------------
# UNINSTALL AVD AGENTS
# -----------------------
Write-Host "📦 Uninstalling Azure Virtual Desktop Agent components..."
$avdPackages = @(
    "Remote Desktop Agent Boot Loader",
    "Remote Desktop Services Infrastructure Agent"
)

foreach ($pkg in $avdPackages) {
    $product = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*$pkg*" }
    if ($product) {
        Write-Host "🗑 Uninstalling: $($product.Name)"
        $product.Uninstall() | Out-Null
    } else {
        Write-Host "ℹ️ Not found: $pkg"
    }
}

# -----------------------
# ENABLE CD/DVD-ROM
# -----------------------
Write-Host "💿 Enabling CD/DVD-ROM..."
reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\cdrom /v start /t REG_DWORD /d 1 /f

# -----------------------
# CLEAR SYSPREP HISTORY
# -----------------------
Write-Host "🧽 Clearing Sysprep history..."
Remove-Item "C:\Windows\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n✅ VM prep complete. Restarted if domain was unjoined."