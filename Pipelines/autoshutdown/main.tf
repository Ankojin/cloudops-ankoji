terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.0"
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id = var.subscription_id
}

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

data "azurerm_resources" "vms_in_rg" {
  resource_group_name = var.resource_group_name
  type                = "Microsoft.Compute/virtualMachines"
}

locals {
  vm_names = [for vm in data.azurerm_resources.vms_in_rg.resources : vm.name]
}

data "azurerm_virtual_machine" "vm" {
  for_each            = toset(local.vm_names)
  name                = each.value
  resource_group_name = var.resource_group_name
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "shutdown" {
  for_each               = data.azurerm_virtual_machine.vm
  virtual_machine_id     = each.value.id
  location               = each.value.location
  enabled                = true
  daily_recurrence_time  = var.shutdown_time
  timezone               = var.time_zone

  notification_settings {
    enabled = false
  }
}