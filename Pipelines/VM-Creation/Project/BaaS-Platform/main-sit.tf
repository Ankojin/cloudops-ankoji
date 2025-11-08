
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  
  # Local backend - state stored on agent server
  # Path: C:\TerraformState\Project\BaaS-Platform\SIT\terraform.tfstate
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
  subscription_id = "12345678-1234-1234-1234-123456789012"
}

variable "location" {
  description = "Location for resources"
  type        = string
  default     = "swedencentral"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "SIT"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "BaaS-Platform"
}

# Common data sources
data "azurerm_virtual_network" "main_vnet" {
  name                = "vnet-baas-sit-001"
  resource_group_name = "rg-networking-sit"
}

data "azurerm_key_vault" "main_kv" {
  name                = "kv-baas-sit-001"
  resource_group_name = "rg-security-sit"
}

data "azurerm_monitor_data_collection_rule" "main_dcr" {
  name                = "dcr-baas-sit-001"
  resource_group_name = "rg-monitoring-sit"
}
