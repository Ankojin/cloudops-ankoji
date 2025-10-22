Pipeline Review
Parameters:

User selects BAB_DEV or BAB_SIT for the source VMs.
Logic App prefix, resource groups, and VM names are parameterized.
Azure CLI Login:

Logs into the selected subscription (BAB_DEV, BAB_SIT, or BAB_CORE).
Sets resolvedSubscriptionId for use in deployment.
Set VM Subscription ID:

Sets vmSubscriptionId to the selected source subscription (BAB_DEV or BAB_SIT).
Deploy Logic Apps:

DB Logic App:
Deploys to bab-core-auto-weeu-rg-01 in the subscription selected in the login step.
Builds VM resource IDs using the selected source subscription and resource group.
Uses logicAppPrefix for naming.
App/Web Logic App:
Same as above, but for App/Web VMs.
PowerShell Script:

Uses VMSubscriptionId to build the VM resource IDs.
Uses SubscriptionId for deployment context.
Sample Test Input
Suppose the user selects:

subscriptionName: BAB_DEV
logicAppPrefix: ststv2_MyApp_PRD
DB_ResourceGroup: my-db-rg
DB_VMNames: dbvm01,dbvm02
APPWEB_ResourceGroup: my-appweb-rg
APPWEB_VMNames: appvm01,appvm02
Sample Test Output
PowerShell will build these resource IDs:

For DB:

/subscriptions/<BAB_DEV_SUBSCRIPTION_ID>/resourceGroups/my-db-rg/providers/Microsoft.Compute/virtualMachines/dbvm01/subscriptions/<BAB_DEV_SUBSCRIPTION_ID>/resourceGroups/my-db-rg/providers/Microsoft.Compute/virtualMachines/dbvm02


For App/Web:

/subscriptions/<BAB_DEV_SUBSCRIPTION_ID>/resourceGroups/my-appweb-rg/providers/Microsoft.Compute/virtualMachines/appvm01/subscriptions/<BAB_DEV_SUBSCRIPTION_ID>/resourceGroups/my-appweb-rg/providers/Microsoft.Compute/virtualMachines/appvm02
These will be injected into the Logic App definition JSON under VMLists.

Logic Apps Created:

ststv2_MyApp_PRD_vms_Scheduled_db
ststv2_MyApp_PRD_vms_Scheduled_appweb
Both deployed to:

Resource Group: bab-core-auto-weeu-rg-01
Subscription: as selected in the login step (typically BAB_CORE for deployment, but resource IDs use the source subscription).