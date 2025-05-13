#Connect-AzAccount
#Select-AzSubscription -Subscription "<<<Your Subscription ID >>>"

# Variable definition
$ResourceGroupName = "enz-core-nw-swec-rg-01"

# Run the deployment
New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile ".\azfw-template.json" -TemplateParameterFile ".\parameters.json"