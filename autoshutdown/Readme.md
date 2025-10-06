# Azure VM Auto-Shutdown Terraform Module

This Terraform configuration enables **auto-shutdown** for all Azure Virtual Machines in a specified resource group using the DevTest Labs global VM shutdown schedule.

## Features

- Automatically discovers all VMs in the target resource group
- Applies a daily auto-shutdown schedule to each VM
- Configurable shutdown time and time zone

## Usage

1. **Configure variables** in your `terraform.tfvars` or via CLI:
   - `subscription_id`: Azure Subscription ID
   - `resource_group_name`: Resource Group containing VMs
   - `shutdown_time`: Shutdown time in 24h format (default: `"2000"`)
   - `time_zone`: Time zone for shutdown schedule (default: `"Arab Standard Time"`)

2. **Initialize and apply**:

   ```sh
   terraform init
   terraform apply