terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.0"
    }
  }
  
  # Explicit local backend configuration
  # Path is configured dynamically via -backend-config in the pipeline
  backend "local" {}
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
  description = "Comma-separated list of DB VM names (leave empty or enter 'none' if no DB VMs)"
  type        = string
  default     = ""
}

variable "db_shutdown_time" {
  description = "Shutdown time for DB VMs in 24h format (HHmm)"
  type        = string
  default     = "2200"
}

variable "app_vm_names" {
  description = "Comma-separated list of App VM names (leave empty or enter 'none' if no App VMs)"
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

# ===== Locals: Parse VM names with null handling =====
locals {
  # Normalize input: treat "none", "null", "n/a", "-" as empty
  normalized_db_vms = lower(trimspace(var.db_vm_names))
  normalized_app_vms = lower(trimspace(var.app_vm_names))
  
  # Check if value should be treated as null/empty
  is_db_vms_empty = (
    local.normalized_db_vms == "" || 
    local.normalized_db_vms == "none" || 
    local.normalized_db_vms == "null" || 
    local.normalized_db_vms == "n/a" || 
    local.normalized_db_vms == "-"
  )
  
  is_app_vms_empty = (
    local.normalized_app_vms == "" || 
    local.normalized_app_vms == "none" || 
    local.normalized_app_vms == "null" || 
    local.normalized_app_vms == "n/a" || 
    local.normalized_app_vms == "-"
  )
  
  # Parse DB VM names from comma-separated string (only if not empty)
  db_vm_list = !local.is_db_vms_empty ? [
    for name in split(",", var.db_vm_names) : trimspace(name)
    if trimspace(name) != "" && lower(trimspace(name)) != "none"
  ] : []
  
  # Parse App VM names from comma-separated string (only if not empty)
  app_vm_list = !local.is_app_vms_empty ? [
    for name in split(",", var.app_vm_names) : trimspace(name)
    if trimspace(name) != "" && lower(trimspace(name)) != "none"
  ] : []
  
  # Combine all VMs that need configuration
  all_vm_names = concat(local.db_vm_list, local.app_vm_list)
  
  # Validation flags
  has_db_vms = length(local.db_vm_list) > 0
  has_app_vms = length(local.app_vm_list) > 0
  has_any_vms = length(local.all_vm_names) > 0
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

# ===== Validation: Ensure at least one VM type is specified =====
resource "null_resource" "validate_vms" {
  lifecycle {
    precondition {
      condition     = local.has_any_vms
      error_message = "At least one VM type (DB or App) must be specified. Both cannot be empty, 'none', or null."
    }
  }
}

# --------------------------
# Outputs
# --------------------------
output "db_vms_configured" {
  description = "DB VMs configured for auto-shutdown"
  value = local.has_db_vms ? {
    vms           = [for vm in data.azurerm_virtual_machine.db_vms : vm.name]
    shutdown_time = var.db_shutdown_time
    count         = length(data.azurerm_virtual_machine.db_vms)
  } : {
    vms           = []
    shutdown_time = "N/A"
    count         = 0
  }
}

output "app_vms_configured" {
  description = "App VMs configured for auto-shutdown"
  value = local.has_app_vms ? {
    vms           = [for vm in data.azurerm_virtual_machine.app_vms : vm.name]
    shutdown_time = var.app_shutdown_time
    count         = length(data.azurerm_virtual_machine.app_vms)
  } : {
    vms           = []
    shutdown_time = "N/A"
    count         = 0
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

output "configuration_summary" {
  description = "Summary of configuration"
  value = {
    resource_group = var.resource_group_name
    has_db_vms     = local.has_db_vms
    has_app_vms    = local.has_app_vms
    total_vms      = length(local.all_vm_names)
    db_vms_list    = local.has_db_vms ? local.db_vm_list : ["None"]
    app_vms_list   = local.has_app_vms ? local.app_vm_list : ["None"]
  }
}