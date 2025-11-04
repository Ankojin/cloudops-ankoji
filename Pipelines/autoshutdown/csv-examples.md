# Examples of how null/empty values are handled in the CSV processing

# ✅ VALID SCENARIOS:

# 1. Resource group with both DB and App VMs
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-full,DB-VM1,2200,APP-VM1,2000

# 2. Resource group with only DB VMs (App VMs empty)
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-db-only,DB-VM1,2200,,

# 3. Resource group with only App VMs (DB VMs empty)
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-app-only,,,APP-VM1,2000

# 4. Multiple VMs in one field
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-multiple,"DB-VM1,DB-VM2",2200,"APP-VM1,APP-VM2",2000

# 5. Missing shutdown times (will use defaults: DB=2000, App=2000)
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-defaults,DB-VM1,,APP-VM1,

# ❌ INVALID SCENARIOS (will be skipped):

# 6. Resource group with no VMs at all
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-empty,,,, 

# 7. Resource group with only spaces/commas (treated as empty)
Subscription,ResourceGroupName,DBVMs,DBShutdownTime,AppVMs,AppShutdownTime
BAB_SIT,rg-spaces,"   ",",,,"," , , ",