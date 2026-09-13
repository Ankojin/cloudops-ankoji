# Testing the Dependency Collection Scripts

## 1. Standalone test scripts (run inside the OS)

These scripts do **not** need Azure PowerShell. Run them directly on a Windows or Linux machine to verify the collection logic and CSV format.

### Windows

```powershell
# On any Windows VM / jump box
cd C:\path\to\DependencyMap
.\Test-Collect-Windows.ps1

# Custom output path
.\Test-Collect-Windows.ps1 -OutputFile C:\Temp\win-test.csv
```

Requirements:
- PowerShell 5.1+ (Windows Server 2012 R2 / Windows 10 or later)
- Ability to run `Get-NetTCPConnection` (normally available to administrators)

### Linux

```bash
# On any Linux VM
cd /path/to/DependencyMap
chmod +x Test-Collect-Linux.sh
./Test-Collect-Linux.sh

# Custom output path
./Test-Collect-Linux.sh /tmp/linux-test.csv
```

Requirements:
- `ss` command (usually provided by `iproute2` package)
- Prefer running as root (or a user that can see process names in `ss -tnp`)

---

## 2. Full Azure multi-VM collector

After the standalone tests look good, use the main script against Azure VMs:

```powershell
# From a machine with Az modules installed
Connect-AzAccount

# Using a server list (CSV or TXT)
.\Collect-AzureVM-Dependencies.ps1 -ServerListFile .\servers-example.csv -OutputPath C:\Temp\Dep

# Or by resource group
.\Collect-AzureVM-Dependencies.ps1 -ResourceGroupNames "rg-app","rg-data" -OutputPath C:\Temp\Dep
```

---

## 3. What a successful test looks like

Both test scripts print a short summary and a sample of rows. You should see:

- **RecordType = Connection** rows with RemoteAddress / RemotePort filled
- **RecordType = Listen** rows with LocalPort filled and ProcessName (e.g. sqlservr, redis-server, w3wp, java, nginx, …)
- **WellKnownApp** populated for common ports (1433 → Microsoft SQL Server, 6379 → Redis, etc.)

Open the generated CSV in Excel (or the DependencyMap-Template.xlsx) to confirm columns line up.

---

## 4. Quick validation checklist

| Check | Windows | Linux |
|-------|---------|-------|
| Script runs without error | ✓ | ✓ |
| CSV is created | ✓ | ✓ |
| Listening ports appear | ✓ | ✓ |
| Process names are visible | ✓ (run elevated) | ✓ (prefer root) |
| WellKnownApp filled for 80/443/1433/6379… | ✓ | ✓ |
| Loopback (127.0.0.1) is filtered out | ✓ | ✓ |

---

## Files

| File | Purpose |
|------|---------|
| Test-Collect-Windows.ps1 | Standalone Windows test |
| Test-Collect-Linux.sh | Standalone Linux test |
| Collect-AzureVM-Dependencies.ps1 | Full multi-VM Azure collector |
| servers-example.csv / .txt | Sample input lists |
| DependencyMap-Template.xlsx | Excel workbook for analysis |
