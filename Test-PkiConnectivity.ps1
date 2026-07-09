# Test-PkiConnectivity.ps1
# Read-only diagnostic for the cloudops-agent: checks both network paths Submit-CsrToPki.ps1 uses --
# HTTPS to the certsrv web enrollment site, and RPC/DCOM to the CA database (CertificateAuthority.View,
# used by the existing-certificate check) -- and runs a real sample query against the CA.
# Safe to run any time: it only reads, never submits a request or modifies anything.
[CmdletBinding()]
param(
    [string]$CaConfig = "DAPKIAPISCWV1.albtests.com\Albtests CA Issuer",
    [string]$PkiUrl   = "https://albtests-pki.albtests.com/certsrv",

    # Optional: test the exact lookup Submit-CsrToPki.ps1 performs, for a specific hostname
    [string]$CommonName,

    # How many recently issued certs to pull back as proof the query mechanism works end to end
    [int]$SampleRows = 5,

    # Submit-CsrToPki.ps1 sets no explicit timeout on its HTTPS calls (so it uses .NET's ~100s default).
    # 15s can be too tight for a real IIS response under load, causing a false FAIL here.
    [int]$HttpTimeoutSec = 30
)

function Write-Result {
    param([string]$Check, [bool]$Pass, [string]$Detail = "")
    $status = if ($Pass) { "PASS" } else { "FAIL" }
    $color = if ($Pass) { "Green" } else { "Red" }
    Write-Host ("[{0}] {1}" -f $status, $Check) -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" }
}

Write-Host "Running as : $(whoami)"
Write-Host "CA config  : $CaConfig"
Write-Host "PKI URL    : $PkiUrl"
Write-Host ""

# --- 1. RPC endpoint mapper reachability (port 135) ---
$caServer = ($CaConfig -split '\\')[0]
try {
    $tnc = Test-NetConnection -ComputerName $caServer -Port 135 -WarningAction SilentlyContinue
    Write-Result "RPC endpoint mapper reachable ($($caServer):135)" $tnc.TcpTestSucceeded
} catch {
    Write-Result "RPC endpoint mapper reachable ($($caServer):135)" $false $_.Exception.Message
}

# --- 2a. Raw TCP reachability to the PKI host on 443 (isolates network from HTTP/NTLM-layer issues) ---
$pkiHost = ([Uri]$PkiUrl).Host
try {
    $tncHttps = Test-NetConnection -ComputerName $pkiHost -Port 443 -WarningAction SilentlyContinue
    Write-Result "TCP reachable ($($pkiHost):443)" $tncHttps.TcpTestSucceeded
} catch {
    Write-Result "TCP reachable ($($pkiHost):443)" $false $_.Exception.Message
}

# --- 2b. HTTPS web enrollment reachability (full HTTP + auth negotiation) ---
# Tests the bare root (default.asp -- often does extra CA-info lookups) *and* certrqxt.asp, the
# actual static form page one hop before certfnsh.asp in the real submission flow. This is a plain
# GET with no query string, so it only renders the static form -- it does not submit anything.
function Test-HttpsPage {
    param([string]$Uri, [string]$Label)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -UseDefaultCredentials -TimeoutSec $HttpTimeoutSec
        $sw.Stop()
        Write-Result "$Label ($Uri)" ($resp.StatusCode -eq 200) "HTTP $($resp.StatusCode) in $([math]::Round($sw.Elapsed.TotalSeconds, 2)) sec"
        return $true
    } catch {
        Write-Result "$Label ($Uri)" $false $_.Exception.Message

        # TCP already proved reachable, so a hang here points at the HTTP layer, not the network.
        # A per-user proxy is a common cause: it's resolved by HttpClient/WinHTTP but invisible to a
        # raw TCP test. Show what proxy (if any) this session would route through, and retry once
        # bypassing it entirely to test the theory directly.
        try {
            $resolvedProxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy([Uri]$Uri)
            if ($resolvedProxy.AbsoluteUri -ne ([Uri]$Uri).AbsoluteUri) {
                Write-Host "       This session resolves a proxy for this host: $($resolvedProxy.AbsoluteUri)" -ForegroundColor Yellow
            } else {
                Write-Host "       This session resolves no proxy for this host (direct connection)." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "       Could not determine system proxy configuration: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        try {
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            $resp2 = Invoke-WebRequest -Uri $Uri -UseBasicParsing -UseDefaultCredentials -TimeoutSec $HttpTimeoutSec -NoProxy
            $sw2.Stop()
            Write-Host "       Retry with -NoProxy SUCCEEDED (HTTP $($resp2.StatusCode) in $([math]::Round($sw2.Elapsed.TotalSeconds, 2)) sec)." -ForegroundColor Cyan
            Write-Host "       -> A configured proxy is very likely the cause, not the PKI server or RPC path." -ForegroundColor Cyan
            Write-Host "          Add a proxy bypass for *.albtests.com, or run with -NoProxy." -ForegroundColor Cyan
        } catch {
            Write-Host "       Retry with -NoProxy also failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "       -> Not a proxy issue. Likely a stalled NTLM/Kerberos handshake specific to this" -ForegroundColor Yellow
            Write-Host "          logon session, or an IIS-side problem. Check IIS logs on albtests-pki for" -ForegroundColor Yellow
            Write-Host "          this timestamp, and compare against the account cloudops-agent's pipeline" -ForegroundColor Yellow
            Write-Host "          jobs actually run as (which succeeded against this same URL before)." -ForegroundColor Yellow
        }
        return $false
    }
}

$rootOk = Test-HttpsPage -Uri $PkiUrl -Label "HTTPS certsrv root reachable"
$formOk = Test-HttpsPage -Uri "$PkiUrl/certrqxt.asp" -Label "HTTPS certrqxt.asp reachable (actual submission-flow page)"

if (-not $rootOk -and $formOk) {
    Write-Host "       -> The root landing page (default.asp) is the slow/broken one specifically." -ForegroundColor Yellow
    Write-Host "          certrqxt.asp (the real page in the submission flow) works fine, which matches" -ForegroundColor Yellow
    Write-Host "          your earlier successful pipeline run. This likely does NOT affect Submit-CsrToPki.ps1." -ForegroundColor Yellow
}

Write-Host ""

# --- 3. CA database RPC/DCOM connection (CertificateAuthority.View) ---
$caView = $null
try {
    $caView = New-Object -ComObject CertificateAuthority.View
    $caView.OpenConnection($CaConfig)
    Write-Result "CA database RPC/DCOM connection (OpenConnection)" $true
} catch {
    Write-Result "CA database RPC/DCOM connection (OpenConnection)" $false $_.Exception.Message
    Write-Host ""
    Write-Host "Stopping here - the remaining checks need a working connection." -ForegroundColor Yellow
    Write-Host "This is exactly the failure mode Submit-CsrToPki.ps1 handles by logging a warning" -ForegroundColor Yellow
    Write-Host "and proceeding with generation as if no existing certificate was found." -ForegroundColor Yellow
    return
}

# --- 4. Sample query: most recent issued certificates (Disposition = 20) ---
$CVR_SEEK_EQ = 1
try {
    $idxRequestId   = $caView.GetColumnIndex($false, "RequestID")
    $idxCommonName  = $caView.GetColumnIndex($false, "CommonName")
    $idxNotAfter    = $caView.GetColumnIndex($false, "NotAfter")
    $idxTemplate    = $caView.GetColumnIndex($false, "CertificateTemplate")
    $idxDisposition = $caView.GetColumnIndex($false, "Disposition")

    $caView.SetResultColumnCount(4)
    $caView.SetResultColumn($idxRequestId)
    $caView.SetResultColumn($idxCommonName)
    $caView.SetResultColumn($idxNotAfter)
    $caView.SetResultColumn($idxTemplate)
    $caView.SetRestriction($idxDisposition, $CVR_SEEK_EQ, 0, 20)

    $rowObj = $caView.OpenView()
    $rows = @()
    while ($rowObj.Next() -ne -1 -and $rows.Count -lt $SampleRows) {
        $colObj = $rowObj.EnumCertViewColumn()
        $entry = @{}
        while ($colObj.Next() -ne -1) { $entry[$colObj.GetName()] = $colObj.GetValue(0) }
        $rows += [PSCustomObject]@{
            RequestId  = $entry["RequestID"]
            CommonName = $entry["CommonName"]
            NotAfter   = $entry["NotAfter"]
            Template   = $entry["CertificateTemplate"]
        }
    }
    $rows = $rows | Sort-Object NotAfter -Descending

    Write-Result "Sample query (Disposition=20, issued certs)" $true "$($rows.Count) row(s) returned"
    if ($rows.Count -gt 0) { $rows | Format-Table -AutoSize | Out-String | Write-Host }
} catch {
    Write-Result "Sample query (Disposition=20, issued certs)" $false $_.Exception.Message
}

# --- 5. Optional: exact lookup for a specific Common Name (mirrors Submit-CsrToPki.ps1's check) ---
if ($CommonName) {
    try {
        $caView.SetRestriction($idxCommonName, $CVR_SEEK_EQ, 0, $CommonName)
        $rowObj = $caView.OpenView()
        $matches = @()
        while ($rowObj.Next() -ne -1) {
            $colObj = $rowObj.EnumCertViewColumn()
            $entry = @{}
            while ($colObj.Next() -ne -1) { $entry[$colObj.GetName()] = $colObj.GetValue(0) }
            $matches += [PSCustomObject]@{
                RequestId  = $entry["RequestID"]
                CommonName = $entry["CommonName"]
                NotAfter   = $entry["NotAfter"]
            }
        }
        Write-Result "Lookup for CommonName='$CommonName'" $true "$($matches.Count) match(es)"
        if ($matches.Count -gt 0) { $matches | Format-Table -AutoSize | Out-String | Write-Host }
    } catch {
        Write-Result "Lookup for CommonName='$CommonName'" $false $_.Exception.Message
    }
}

Write-Host "`nDone."
