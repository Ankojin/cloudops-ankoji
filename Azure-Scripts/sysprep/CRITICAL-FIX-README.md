# CRITICAL: Domain Unjoin Failure Root Cause

## Problem
`Remove-Computer -Restart` does NOT work properly when called via `Invoke-AzVMRunCommand`:

1. **Script executes** via Azure VM Guest Agent
2. **Restart is scheduled** but command returns immediately
3. **Script exits** before restart happens
4. **Azure VM Agent** may not honor the pending restart
5. **Result**: VM never restarts, domain unjoin never completes

## Evidence from v3
```
Domain: albtests.com (still joined!)
Profiles: 33 (not deleted)
Sysprep Count: 7 (corrupted - cannot use)
```

## Solution
**TWO-PHASE APPROACH:**

### Phase 1: Cleanup WITHOUT Restart
Run all cleanup tasks but DO NOT restart within the script:
- Domain unjoin using registry manipulation ONLY
- User profile deletion
- Service cleanup
- NO restart commands

### Phase 2: External Restart from Azure
After cleanup script completes, restart VM from Azure PowerShell:
```powershell
Restart-AzVM -ResourceGroupName $rg -Name $vmName
```

Then wait and verify.

## New Strategy for v4

1. **Delete v3** (corrupted, sysprep limit exceeded)
2. **Clone v4** from source BABAVDSHDTA-1
3. **Run NEW prep script** (no internal restarts)
4. **Manually restart** from Azure
5. **Verify** with Verify-VMState.ps1
6. **Then sysprep**

## Files to Update
- Clone-And-Generalize-AVD.ps1 (remove -Restart from all commands)
- Add external restart logic after each cleanup phase
