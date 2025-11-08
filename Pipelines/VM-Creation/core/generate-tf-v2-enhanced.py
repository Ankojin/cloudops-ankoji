#!/usr/bin/env python3
"""
Enhanced VM Creation Terraform Generator v2
Handles multiple subnets, resource groups, and standardized configurations
Supports DEV/SIT environments with flexible CSV structure
"""

import base64
import csv
import json
import os
import sys
from typing import Dict, Any, List

class TerraformVMGenerator:
    def __init__(self):
        """Initialize generator with environment variables"""
        self.environment = os.getenv('ENVIRONMENT', 'DEV')
        self.project_name = os.getenv('PROJECT_NAME', 'BaaS-Platform')
        
        # Environment-specific configuration from variable groups
        self.config = {
            'subscription_id': os.getenv('SUBSCRIPTION_ID'),
            'location': os.getenv('LOCATION', 'swedencentral'),
            'vnet_name': os.getenv('VNET_NAME'),
            'vnet_rg': os.getenv('VNET_RG'),
            'subnet_rg': os.getenv('SUBNET_RG'),
            'subnets_config': os.getenv('SUBNETS_CONFIG', '{}'),
            'keyvault_name': os.getenv('KEYVAULT_NAME'),
            'keyvault_rg': os.getenv('KEYVAULT_RG'),
            'dcr_name': os.getenv('DCR_NAME'),
            'dcr_rg': os.getenv('DCR_RG'),
            'diagnostics_storage': os.getenv('DIAGNOSTICS_STORAGE'),
            'diagnostics_storage_rg': os.getenv('DIAGNOSTICS_STORAGE_RG'),
            'script_storage_account': os.getenv('SCRIPT_STORAGE_ACCOUNT'),
            'script_storage_container': os.getenv('SCRIPT_STORAGE_CONTAINER'),
            'script_blob_name_linux': os.getenv('SCRIPT_BLOB_NAME_LINUX'),
            'script_blob_name_windows': os.getenv('SCRIPT_BLOB_NAME_WINDOWS'),
            'default_tags': os.getenv('DEFAULT_TAGS', '')
        }
        
        # Hardcoded standards (enforced consistency)
        self.storage_standards = {
            'os_disk_type': 'StandardSSD_LRS',        # Hardcoded for cost optimization
            'data_disk_type': 'StandardSSD_LRS',      # Hardcoded for consistency
            'disk_caching': 'ReadWrite',              # Hardcoded OS disk caching
            'data_disk_caching': 'None'               # Hardcoded data disk caching
        }
        
        # Auto shutdown (hardcoded)
        self.shutdown_config = {
            'enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'time': os.getenv('shutdown_time', '2000'),
            'timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }
        
        # Parse subnets configuration
        try:
            self.subnets = json.loads(self.config['subnets_config'])
        except json.JSONDecodeError:
            print("❌ Invalid subnets configuration JSON")
            self.subnets = {}
        
        # Paths - relative to pipeline working directory
        self.csv_file_path = f"./simplified-vms.csv"  # CSV in same directory as script
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.cloud_init_file = "./Deployment-Cloud-init.yaml"  # Cloud-init in same directory
        
        # Track resource groups to create
        self.resource_groups_to_create = set()
        
        # Validate required environment variables
        self.validate_config()
    
    def validate_config(self):
        """Validate required environment variables are present"""
        required_vars = ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name']
        missing_vars = [var for var in required_vars if not self.config.get(var)]
        
        if missing_vars:
            print(f"❌ Missing required environment variables: {', '.join(missing_vars)}")
            sys.exit(1)
        
        # Validate subnets configuration
        if not self.subnets:
            print("❌ No subnets configuration found")
            sys.exit(1)
            
        print(f"[OK] Configuration validated for {self.environment} environment")
        print(f"📍 Available subnets: {list(self.subnets.keys())}")
    
    def read_and_encode_cloud_init_yaml(self) -> str:
        """Read and base64 encode cloud-init file"""
        try:
            with open(self.cloud_init_file, 'r') as f:
                content = f.read()
                return base64.b64encode(content.encode()).decode()
        except FileNotFoundError:
            print(f"⚠️ Cloud-init file {self.cloud_init_file} not found.")
            return ""
    
    def parse_tags(self, tags_str: str) -> Dict[str, str]:
        """Parse tags from CSV format and merge with defaults"""
        tags = {}
        
        # Method 1: Try JSON format first (most efficient)
        json_tags = os.getenv('default_tags_json')
        if json_tags:
            try:
                tags.update(json.loads(json_tags))
                print(f"✅ Loaded {len(tags)} tags from JSON format")
            except json.JSONDecodeError as e:
                print(f"⚠️ Invalid JSON in default_tags_json: {e}")
        
        # Method 2: Try granular tag variables (fallback)
        if not tags:  # Only if JSON didn't work
            granular_tag_vars = [
                ('Company', 'tag_company'),
                ('Department', 'tag_department'),
                ('ProjectName', 'tag_project_name'),
                ('ApplicationName', 'tag_application_name'),
                ('StartDate', 'tag_start_date'),
                ('EndDate', 'tag_end_date'),
                ('Region', 'tag_region'),
                ('ApproverName', 'tag_approver_name'),
                ('RequesterName', 'tag_requester_name'),
                ('BusinessOwner', 'tag_business_owner'),
                ('TechnicalOwner', 'tag_technical_owner'),
                ('CostCenter', 'tag_cost_center'),
                ('ServiceClass', 'tag_service_class'),
                ('ManagedBy', 'tag_managed_by')
            ]
            
            granular_found = False
            for tag_name, env_var in granular_tag_vars:
                value = os.getenv(env_var)
                if value:
                    tags[tag_name] = value.strip()
                    granular_found = True
            
            if granular_found:
                print(f"✅ Loaded {len(tags)} tags from granular variables")
        
        # Method 3: Fall back to default_tags string format (legacy)
        if not tags:
            default_tags_str = self.config['default_tags']
            if default_tags_str:
                tag_lines = default_tags_str.replace(';', '\n').split('\n')
                for tag_line in tag_lines:
                    tag_line = tag_line.strip()
                    if '=' in tag_line:
                        key, value = tag_line.split('=', 1)
                        key = key.strip().strip('"\'')
                        value = value.strip().strip('"\'')
                        if key and value:
                            tags[key] = value
                
                if tags:
                    print(f"✅ Loaded {len(tags)} tags from legacy string format")
        
        # Add custom tags from CSV (these can override defaults)
        if tags_str and tags_str.strip():
            tag_pairs = tags_str.split(';')
            for pair in tag_pairs:
                pair = pair.strip()
                if '=' in pair:
                    key, value = pair.split('=', 1)
                    key = key.strip().strip('"\'')
                    value = value.strip().strip('"\'')
                    if key and value:
                        tags[key] = value
        
        # Add auto-generated tags (these override everything)
        from datetime import datetime
        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = datetime.now().strftime('%Y-%m-%d')
        tags['Environment'] = self.environment
        tags['Project'] = self.project_name
        
        return tags
    
    def get_subnet_name(self, subnet_type: str, subnet_index: int = 0) -> str:
        """Get subnet name based on type and index"""
        if subnet_type not in self.subnets:
            print(f"⚠️ Unknown subnet type: {subnet_type}, using first available")
            subnet_type = list(self.subnets.keys())[0]
        
        subnet_list = self.subnets[subnet_type]
        if subnet_index >= len(subnet_list):
            print(f"⚠️ Subnet index {subnet_index} out of range for {subnet_type}, using index 0")
            subnet_index = 0
            
        return subnet_list[subnet_index]
    
    def generate_terraform(self):
        """Generate Terraform configuration"""
        # Create output directory
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        
        cloud_init_content = self.read_and_encode_cloud_init_yaml()
        vm_outputs = []  # Track VMs for outputs
        
        with open(self.output_tf_file, "w") as tf_file:
            self._write_provider_block(tf_file)
            
            # First pass: collect resource groups to create
            self._collect_resource_groups()
            
            # Generate resource group resources
            self._generate_resource_groups(tf_file)
            
            # Process CSV file for VMs
            try:
                with open(self.csv_file_path, newline='') as csvfile:
                    reader = csv.DictReader(csvfile)
                    for row in reader:
                        vm_name = row["vm_name"].strip()
                        vm_outputs.append(vm_name)
                        self._generate_vm_resources(tf_file, row, cloud_init_content)
            except FileNotFoundError:
                print(f"❌ CSV file not found: {self.csv_file_path}")
                sys.exit(1)
            
            # Generate outputs
            self._generate_outputs(tf_file, vm_outputs)
        
        print(f"[OK] Terraform configuration generated: {self.output_tf_file}")
        print(f"📊 Resource groups to create: {len(self.resource_groups_to_create)}")
        print(f"🖥️ VMs to deploy: {len(vm_outputs)}")
    
    def _generate_outputs(self, tf_file, vm_list: List[str]):
        """Generate Terraform outputs for VM information"""
        tf_file.write(f'''
# ==== Outputs ====

output "vm_private_ips" {{
  description = "Private IP addresses of all VMs"
  value = {{
''')
        
        for vm_name in vm_list:
            tf_file.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.private_ip_address\n')
        
        tf_file.write('''  }
}

output "vm_resource_groups" {
  description = "Resource groups containing the VMs"
  value = {
''')
        
        for vm_name in vm_list:
            tf_file.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.resource_group_name\n')
        
        tf_file.write('''  }
}

output "deployment_summary" {
  description = "Deployment summary information"
  value = {
    environment     = var.environment
    vm_count       = length([''')
        
        vm_names = '", "'.join(vm_list)
        tf_file.write(f'"{vm_names}"')
        
        tf_file.write('''])
    project_name   = "''' + self.project_name + '''"
    deployment_time = timestamp()
  }
}
''')
        
        print(f"📊 Generated outputs for {len(vm_list)} VMs")
    
    def _collect_resource_groups(self):
        """First pass to collect all resource groups that need to be created"""
        try:
            with open(self.csv_file_path, newline='') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if row.get("create_rg", "").lower() == "true":
                        rg_name = row.get("resource_group", "").strip()
                        if rg_name:
                            self.resource_groups_to_create.add(rg_name)
        except FileNotFoundError:
            pass
    
    def _generate_resource_groups(self, tf_file):
        """Generate resource group resources"""
        if not self.resource_groups_to_create:
            return
            
        tf_file.write("\n# ==== Resource Groups ====\n")
        
        for rg_name in sorted(self.resource_groups_to_create):
            # Parse default tags for resource group
            tags = self.parse_tags("")
            tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
            
            tf_file.write(f'''
resource "azurerm_resource_group" "{rg_name.replace('-', '_')}_rg" {{
  name     = "{rg_name}"
  location = var.location

  tags = {{
    {tags_str}
  }}
}}
''')
    
    def _write_provider_block(self, tf_file):
        """Write provider and variable blocks - using local state on agent server"""
        
        tf_file.write(f'''
terraform {{
  required_version = ">= 1.0"
  required_providers {{
    azurerm = {{
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }}
  }}
  
  # Local backend - state stored on agent server
  # Path: C:\\TerraformState\\Project\\{self.project_name}\\{self.environment}\\terraform.tfstate
}}

provider "azurerm" {{
  features {{
    resource_group {{
      prevent_deletion_if_contains_resources = false
    }}
    virtual_machine {{
      delete_os_disk_on_deletion = true
    }}
  }}
  subscription_id = "{self.config['subscription_id']}"
}}

variable "location" {{
  description = "Location for resources"
  type        = string
  default     = "{self.config['location']}"
}}

variable "environment" {{
  description = "Environment name"
  type        = string
  default     = "{self.environment}"
}}

variable "project_name" {{
  description = "Project name"
  type        = string
  default     = "{self.project_name}"
}}

# Common data sources
data "azurerm_virtual_network" "main_vnet" {{
  name                = "{self.config['vnet_name']}"
  resource_group_name = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault" "main_kv" {{
  name                = "{self.config['keyvault_name']}"
  resource_group_name = "{self.config['keyvault_rg']}"
}}

data "azurerm_monitor_data_collection_rule" "main_dcr" {{
  name                = "{self.config['dcr_name']}"
  resource_group_name = "{self.config['dcr_rg']}"
}}
''')
        
        print(f"[CONFIG] Local backend configured for: C:\\TerraformState\\Project\\{self.project_name}\\{self.environment}\\")

    def _generate_vm_resources(self, tf_file, row: Dict[str, str], cloud_init_content: str):
        """Generate Terraform resources for a single VM"""
        # Extract VM configuration from CSV
        vm_name = row["vm_name"].strip()
        resource_group = row["resource_group"].strip()
        vm_role = row["vm_role"].strip()
        subnet_type = row["subnet_type"].strip()
        subnet_index = int(row.get("subnet_index", 0))
        static_ip = row["static_ip"].strip()
        vm_size = row["vm_size"].strip()  # Read directly from CSV
        os_type = row.get("os_type", "linux").strip().lower()
        
        # OS Image details from CSV
        os_publisher = row.get("os_publisher", "RedHat").strip()
        os_offer = row.get("os_offer", "RHEL").strip()
        os_sku = row.get("os_sku", "92-gen2").strip()
        os_version = row.get("os_version", "latest").strip()
        
        custom_tags = row.get("custom_tags", "").strip()
        create_rg = row.get("create_rg", "false").lower() == "true"
        
        # Calculate values
        subnet_name = self.get_subnet_name(subnet_type, subnet_index)
        tags = self.parse_tags(custom_tags)
        
        # Create OS image object from CSV data
        os_image = {
            'publisher': os_publisher,
            'offer': os_offer,
            'sku': os_sku,
            'version': os_version
        }
        
        # Validate VM size
        if not vm_size:
            print(f"⚠️ No VM size specified for {vm_name}, using Standard_D4s_v5")
            vm_size = "Standard_D4s_v5"
        
        # Format tags for Terraform
        tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
        
        # Select appropriate script based on OS type
        if os_type.lower() == 'windows':
            script_blob_name = self.config['script_blob_name_windows']
            script_description = "Windows PowerShell setup script"
        else:
            script_blob_name = self.config['script_blob_name_linux']
            script_description = "Linux shell setup script"
        
        # Generate SAS URL - TODO: Should be generated dynamically or from Key Vault
        # For now, using direct blob URL (assumes public read or managed identity access)
        sas_url = f"https://{self.config['script_storage_account']}.blob.core.windows.net/{self.config['script_storage_container']}/{script_blob_name}"
        
        print(f"ℹ️ Using {script_description}: {script_blob_name}")
        print(f"⚠️ WARNING: Using direct blob URL. Consider implementing dynamic SAS token generation.")
        
        # Resource group reference
        rg_reference = f"azurerm_resource_group.{resource_group.replace('-', '_')}_rg.name" if create_rg else f'"{resource_group}"'
        
        tf_file.write(f'''
# ==== {vm_name} Resources ====

# Subnet data source
data "azurerm_subnet" "{vm_name}_subnet" {{
  name                 = "{subnet_name}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "{self.config['vnet_rg']}"
}}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "{vm_name}_admin_password" {{
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

# Network Interface
resource "azurerm_network_interface" "{vm_name}_nic" {{
  name                = "{vm_name}-nic"
  location            = var.location
  resource_group_name = {rg_reference}

  ip_configuration {{
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.{vm_name}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "{static_ip}"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

        # Generate VM resource based on OS type
        if os_type == "linux":
            self._generate_linux_vm(tf_file, vm_name, vm_size, tags_str, cloud_init_content, sas_url, os_image, rg_reference)
        else:
            self._generate_windows_vm(tf_file, vm_name, vm_size, tags_str, sas_url, os_image, rg_reference)
        
        # Generate additional disks
        self._generate_data_disks(tf_file, vm_name, row, os_type, rg_reference)
        
        # Generate auto shutdown
        self._generate_auto_shutdown(tf_file, vm_name, tags_str, os_type)
    
    def _generate_linux_vm(self, tf_file, vm_name: str, vm_size: str, tags_str: str, cloud_init_content: str, sas_url: str, os_image: Dict, rg_reference: str):
        """Generate Linux VM resources"""
        tf_file.write(f'''
# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = {rg_reference}
  location            = var.location
  size                = "{vm_size}"

  network_interface_ids = [
    azurerm_network_interface.{vm_name}_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  disable_password_authentication = false

  os_disk {{
    caching              = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}

  source_image_reference {{
    publisher = "{os_image['publisher']}"
    offer     = "{os_image['offer']}"
    sku       = "{os_image['sku']}"
    version   = "{os_image['version']}"
  }}

  custom_data = "{cloud_init_content}"
  
  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {{
    {tags_str}
  }}
}}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_linux_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "sh {self.config['script_blob_name']}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
    
    def _generate_windows_vm(self, tf_file, vm_name: str, vm_size: str, tags_str: str, sas_url: str, os_image: Dict, rg_reference: str):
        """Generate Windows VM resources"""
        tf_file.write(f'''
# Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = {rg_reference}
  location            = var.location
  size                = "{vm_size}"

  network_interface_ids = [
    azurerm_network_interface.{vm_name}_nic.id
  ]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  license_type   = "Windows_Server"

  os_disk {{
    caching              = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}

  source_image_reference {{
    publisher = "{os_image['publisher']}"
    offer     = "{os_image['offer']}"
    sku       = "{os_image['sku']}"
    version   = "{os_image['version']}"
  }}
  
  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {{
    {tags_str}
  }}
}}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_windows_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File {self.config['script_blob_name']}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
    
    def _generate_data_disks(self, tf_file, vm_name: str, row: Dict[str, str], os_type: str, rg_reference: str):
        """Generate additional data disks for VM"""
        vm_resource_type = "linux_virtual_machine" if os_type == "linux" else "windows_virtual_machine"
        
        for idx in range(1, 4):  # Support up to 3 additional disks (disk_1_size, disk_2_size, disk_3_size)
            disk_size = row.get(f"disk_{idx}_size", "").strip()
            
            if disk_size and disk_size.isdigit():
                disk_name = f"{vm_name}_DataDisk_{idx-1}"
                lun = idx - 1
                
                tf_file.write(f'''
# Data Disk {idx}
resource "azurerm_managed_disk" "{disk_name}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = {rg_reference}
  storage_account_type = "{self.storage_standards['data_disk_type']}"
  disk_size_gb         = {disk_size}
  create_option        = "Empty"
}}

resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_disk_{idx}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{disk_name}.id
  virtual_machine_id = azurerm_{vm_resource_type}.{vm_name}.id
  lun                = {lun}
  create_option      = "Attach"
  caching            = "{self.storage_standards['data_disk_caching']}"
}}
''')
    
    def _generate_auto_shutdown(self, tf_file, vm_name: str, tags_str: str, os_type: str):
        """Generate auto shutdown schedule (hardcoded configuration)"""
        if not self.shutdown_config['enabled']:
            return
            
        vm_resource_type = "linux_virtual_machine" if os_type == "linux" else "windows_virtual_machine"
        
        tf_file.write(f'''
# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}_shutdown" {{
  virtual_machine_id = azurerm_{vm_resource_type}.{vm_name}.id
  location           = var.location
  enabled            = {str(self.shutdown_config['enabled']).lower()}

  daily_recurrence_time = "{self.shutdown_config['time']}"
  timezone              = "{self.shutdown_config['timezone']}"

  notification_settings {{
    enabled = false
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

def main():
    """Main execution function"""
    print("[START] Enhanced Terraform VM Configuration Generator v2")
    
    generator = TerraformVMGenerator()
    generator.generate_terraform()
    
    print("[SUCCESS] Terraform configuration generation completed successfully")

if __name__ == "__main__":
    main()