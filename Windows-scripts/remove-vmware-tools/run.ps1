<#
.SYNOPSIS
  Run remove-vmware-tools.ps1 on multiple hosts using PsExec, with masked password input.
.DESCRIPTION
  Uses cmdkey to add a transient credential for each target host, runs PsExec without -p (so password is not on PsExec command line),
  then deletes the cmdkey entry and zeroes plaintext password variables.
#>

# --- CONFIGURATION ---
$cleanupScriptPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Windows-scripts\remove-vmware-tools\remove-vmware-tools.ps1"
$computersFile      = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Windows-scripts\remove-vmware-tools\computers.txt"
$logFile            = "C:\Temp\vmware_cleanup.log"   # ensure folder exists
# Note: psexec.exe must be in PATH (or specify full path like 'C:\Tools\PsExec\psexec.exe')

# --- PROMPT FOR CREDENTIALS (masked) ---
$remoteUser = Read-Host -Prompt "Enter remote username (format: user or domain\user)"
$securePass = Read-Host -Prompt "Enter password for $remoteUser" -AsSecureString

# Convert SecureString to plaintext for local, short-lived use
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
try {
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
} finally {
    # Always free the BSTR
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) | Out-Null
}
# Clear $securePass variable to avoid lingering references
$securePass = $null

# --- READ COMPUTERS ---
$computers = Get-Content -Path $computersFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# Ensure log folder exists
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

function Log {
    param($text)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts`t$text" | Tee-Object -FilePath $logFile -Append
}

Log "Starting PsExec multi-host VMware Tools cleanup. Hosts: $($computers.Count)"

foreach ($computer in $computers) {
    $computer = $computer.Trim()
    if ($computer -eq '') { continue }

    Log "==== Processing $computer ===="

    try {
        # 1) Add transient credential for the target host to Windows Credential Manager
        # Use the target as the "target" argument for cmdkey (use full hostname or IP)
        $cmdkeyAdd = "cmdkey /add:`"$computer`" /user:`"$remoteUser`" /pass:`"$plainPass`""
        Log "Adding credential for $computer (cmdkey)"
        # Run cmdkey without writing the command to the log (only log high-level action)
        & cmd.exe /c $cmdkeyAdd 2>&1 | Out-Null

        # 2) Run PsExec WITHOUT -u -p so it will use cached credentials (if accepted)
        # Using -accepteula automatically accepts EULA first-time (optional)
        $psexecArgs = "\\$computer -accepteula -h powershell.exe -ExecutionPolicy Bypass -File `"$cleanupScriptPath`""
        Log "Running PsExec on $computer"
        $psexec = Start-Process -FilePath "psexec.exe" -ArgumentList $psexecArgs -NoNewWindow -Wait -PassThru -ErrorAction Stop

        # Capture exit code
        if ($psexec.ExitCode -eq 0) {
            Log "Completed cleanup on $computer (ExitCode 0)."
        } else {
            Log "Completed cleanup on $computer (ExitCode $($psexec.ExitCode))."
        }
    } catch {
        Log "ERROR while processing $computer : $_"
    } finally {
        # 3) Delete the transient credential
        try {
            Log "Removing transient credential for $computer"
            & cmd.exe /c "cmdkey /delete:`"$computer`"" 2>&1 | Out-Null
        } catch {
            Log "Warning: failed to delete credential for $computer : $_"
        }

        # Reduce risk: give $plainPass a short lifetime; overwrite it immediately
        $plainPass = ('X' * 40)
        $plainPass = $null
        Start-Sleep -Milliseconds 250
    }
}

Log "All hosts processed. Script finished."