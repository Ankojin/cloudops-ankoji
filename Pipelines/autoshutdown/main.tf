terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.0"
    }
  }
  
  # Note: Backend configuration is set dynamically in the pipeline using -backend-config
  # This allows unique state files per subscription and resource group
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret
}

# ===== Variables =====
variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "client_id" {
  description = "Service Principal Client ID"
  type        = string
}

variable "client_secret" {
  description = "Service Principal Client Secret"
  type        = string
  sensitive   = true
}

variable "resource_group_name" {
  description = "Resource Group containing VMs"
  type        = string
}

variable "db_vm_names" {
  description = "Comma-separated list of DB VM names (leave empty if no DB VMs)"
  type        = string
  default     = ""
}

variable "db_shutdown_time" {
  description = "Shutdown time for DB VMs in 24h format (HHmm)"
  type        = string
  default     = "2200"
}

variable "app_vm_names" {
  description = "Comma-separated list of App VM names (leave empty if no App VMs)"
  type        = string
  default     = ""
}

variable "app_shutdown_time" {
  description = "Shutdown time for App VMs in 24h format (HHmm)"
  type        = string
  default     = "2000"
}

variable "time_zone" {
  description = "Time zone for shutdown schedule"
  type        = string
  default     = "Arab Standard Time"
}

# ===== Locals: Parse VM names =====
locals {
  # Parse DB VM names from comma-separated string
  db_vm_list = var.db_vm_names != "" ? [
    for name in split(",", var.db_vm_names) : trimspace(name)
  ] : []
  
  # Parse App VM names from comma-separated string
  app_vm_list = var.app_vm_names != "" ? [
    for name in split(",", var.app_vm_names) : trimspace(name)
  ] : []
  
  # Combine all VMs that need configuration
  all_vm_names = concat(local.db_vm_list, local.app_vm_list)
}

# ===== Data: Fetch only specified VMs =====
data "azurerm_virtual_machine" "db_vms" {
  for_each            = toset(local.db_vm_list)
  name                = each.value
  resource_group_name = var.resource_group_name
}

data "azurerm_virtual_machine" "app_vms" {
  for_each            = toset(local.app_vm_list)
  name                = each.value
  resource_group_name = var.resource_group_name
}

# ===== Resource: Auto-shutdown for DB VMs =====
resource "azurerm_dev_test_global_vm_shutdown_schedule" "db_shutdown" {
  for_each              = data.azurerm_virtual_machine.db_vms
  virtual_machine_id    = each.value.id
  location              = each.value.location
  enabled               = true
  daily_recurrence_time = var.db_shutdown_time
  timezone              = var.time_zone

  notification_settings {
    enabled = false
  }
}

# ===== Resource: Auto-shutdown for App VMs =====
resource "azurerm_dev_test_global_vm_shutdown_schedule" "app_shutdown" {
  for_each              = data.azurerm_virtual_machine.app_vms
  virtual_machine_id    = each.value.id
  location              = each.value.location
  enabled               = true
  daily_recurrence_time = var.app_shutdown_time
  timezone              = var.time_zone

  notification_settings {
    enabled = false
  }
}

# --------------------------
# Outputs
# --------------------------
output "db_vms_configured" {
  description = "DB VMs configured for auto-shutdown"
  value = {
    vms           = [for vm in data.azurerm_virtual_machine.db_vms : vm.name]
    shutdown_time = var.db_shutdown_time
    count         = length(data.azurerm_virtual_machine.db_vms)
  }
}

output "app_vms_configured" {
  description = "App VMs configured for auto-shutdown"
  value = {
    vms           = [for vm in data.azurerm_virtual_machine.app_vms : vm.name]
    shutdown_time = var.app_shutdown_time
    count         = length(data.azurerm_virtual_machine.app_vms)
  }
}

output "total_vms_configured" {
  description = "Total number of VMs configured"
  value       = length(data.azurerm_virtual_machine.db_vms) + length(data.azurerm_virtual_machine.app_vms)
}

output "state_file_location" {
  description = "Terraform state file location"
  value       = "Configured dynamically per resource group"
}