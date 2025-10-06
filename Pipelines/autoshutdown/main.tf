terraform {
  required_version = ">= 1.5.0" # Optional, ensures Terraform version compatibility

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.0"
    }
  }

  # Optional: Configure backend (if you want to persist state remotely)
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstateaccount"
  #   container_name       = "tfstate"
  #   key                  = "vm-autoshutdown.tfstate"
  # }
}

provider "azurerm" {
  features {}
  
}

# --------------------------
# Variables
# --------------------------
variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group containing VMs"
  type        = string
}

variable "shutdown_time" {
  description = "Shutdown time in 24h format (HHmm)"
  type        = string
  default     = "2000"
}

variable "time_zone" {
  description = "Time zone for shutdown schedule"
  type        = string
  default     = "Arab Standard Time"
}

# --------------------------
# Data Sources
# --------------------------
# Get all VMs in the given resource group
data "azurerm_resources" "vms_in_rg" {
  resource_group_name = var.resource_group_name
  type                = "Microsoft.Compute/virtualMachines"
}

locals {
  vm_names = try([for vm in data.azurerm_resources.vms_in_rg.resources : vm.name], [])
}

# Load each VM as a data source
data "azurerm_virtual_machine" "vm" {
  for_each            = toset(local.vm_names)
  name                = each.value
  resource_group_name = var.resource_group_name
}

# --------------------------
# Resources
# --------------------------
# Apply DevTest Labs auto-shutdown to each VM
resource "azurerm_dev_test_global_vm_shutdown_schedule" "shutdown" {
  for_each              = data.azurerm_virtual_machine.vm
  virtual_machine_id    = each.value.id
  location              = each.value.location
  enabled               = true
  daily_recurrence_time = var.shutdown_time
  timezone              = var.time_zone

  notification_settings {
    enabled = false
  }

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "AutoShutdown"
  }
}

# --------------------------
# Outputs
# --------------------------
output "configured_vms" {
  description = "VMs that have been configured for auto-shutdown"
  value       = [for vm in data.azurerm_virtual_machine.vm : vm.name]
}