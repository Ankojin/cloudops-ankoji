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
            'keyvault_name': os.getenv('KEYVAULT_NAME'),
            'keyvault_rg': os.getenv('KEYVAULT_RG'),
            'dcr_name': os.getenv('DCR_NAME'),
            'dcr_rg': os.getenv('DCR_RG'),
            'diagnostics_storage': os.getenv('DIAGNOSTICS_STORAGE'),
            'diagnostics_storage_rg': os.getenv('DIAGNOSTICS_STORAGE_RG'),
            'script_storage_account': os.getenv('SCRIPT_STORAGE_ACCOUNT'),
            'script_storage_container': os.getenv('SCRIPT_STORAGE_CONTAINER'),
            'script_blob_name_linux': os.getenv('SCRIPT_BLOB_NAME_LINUX'),
            'script_blob_name_windows': os.getenv('SCRIPT_BLOB_NAME_WINDOWS')
        }
        
        # Predefined OS Templates (Corporate Standards)
        self.os_templates = {
            # Windows Templates
            "windows-2019": {
                "os_type": "windows",
                "publisher": "MicrosoftWindowsServer", 
                "offer": "WindowsServer",
                "sku": "2019-Datacenter",
                "version": "latest"
            },
            "windows-2022": {
                "os_type": "windows",
                "publisher": "MicrosoftWindowsServer",
                "offer": "WindowsServer", 
                "sku": "2022-Datacenter",
                "version": "latest"
            },
            "windows-2016": {
                "os_type": "windows",
                "publisher": "MicrosoftWindowsServer",
                "offer": "WindowsServer",
                "sku": "2016-Datacenter",
                "version": "latest"
            },
            # Ubuntu Templates
            "ubuntu-20.04": {
                "os_type": "linux",
                "publisher": "Canonical",
                "offer": "0001-com-ubuntu-server-focal",
                "sku": "20_04-lts-gen2",
                "version": "latest"
            },
            "ubuntu-22.04": {
                "os_type": "linux", 
                "publisher": "Canonical",
                "offer": "0001-com-ubuntu-server-jammy",
                "sku": "22_04-lts-gen2",
                "version": "latest"
            },
            "ubuntu-18.04": {
                "os_type": "linux",
                "publisher": "Canonical", 
                "offer": "UbuntuServer",
                "sku": "18.04-LTS",
                "version": "latest"
            },
            # Red Hat Enterprise Linux Templates
            "rhel-8": {
                "os_type": "linux",
                "publisher": "RedHat",
                "offer": "RHEL", 
                "sku": "8-gen2",
                "version": "latest"
            },
            "rhel-9": {
                "os_type": "linux",
                "publisher": "RedHat",
                "offer": "RHEL",
                "sku": "9-gen2", 
                "version": "latest"
            },
            "rhel-7": {
                "os_type": "linux",
                "publisher": "RedHat",
                "offer": "RHEL",
                "sku": "7-gen2",
                "version": "latest"
            },
            # CentOS Templates
            "centos-7": {
                "os_type": "linux",
                "publisher": "OpenLogic",
                "offer": "CentOS",
                "sku": "7_9-gen2",
                "version": "latest"
            },
            # SUSE Linux Templates
            "sles-15": {
                "os_type": "linux",
                "publisher": "SUSE",
                "offer": "sles-15-sp3",
                "sku": "gen2",
                "version": "latest"
            }
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
        
        # Paths - relative to pipeline working directory ($(Build.SourcesDirectory)/Pipelines/VM-Creation)
        self.csv_file_path = os.getenv('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.cloud_init_file = "./core/Deployment-Cloud-init.yaml"
        
        # Track resource groups to create
        self.resource_groups_to_create = set()
        
        # Validate required environment variables
        self.validate_config()
    
    def validate_config(self):
        """Validate required environment variables are present"""
        required_vars = ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name']
        missing_vars = [var for var in required_vars if not self.config.get(var)]
        
        if missing_vars:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing_vars)}")
            sys.exit(1)
            
        print(f"[OK] Configuration validated for {self.environment} environment")
        print(f"[INFO] Available OS templates: {', '.join(self.os_templates.keys())}")
    
    def read_and_encode_cloud_init_yaml(self) -> str:
        """Read and base64 encode cloud-init file"""
        try:
            with open(self.cloud_init_file, 'r') as f:
                content = f.read()
                return base64.b64encode(content.encode()).decode()
        except FileNotFoundError:
            print(f"[WARNING] Cloud-init file {self.cloud_init_file} not found.")
            return ""
    
    def parse_tags(self, tags_str: str = None) -> Dict[str, str]:
        """Parse mandatory tags from JSON format only"""
        
        # Define mandatory tags with their required keys
        mandatory_tag_keys = [
            "Company", "Department", "ProjectName", "ApplicationName", 
            "StartDate", "EndDate", "Region", "ApproverName", 
            "RequesterName", "BusinessOwner", "TechnicalOwner", 
            "CostCenter", "ServiceClass", "ManagedBy"
        ]
        
        tags = {}
        
        # Get tags from JSON format (mandatory)
        json_tags = os.getenv('default_tags_json')
        if not json_tags or json_tags.strip() == '{}' or json_tags.strip() == '':
            print("[ERROR] Mandatory tags are required!")
            print("[REQUIRED] Required tags JSON format:")
            print('{"Company": "BAB", "Department": "Information Technology", "ProjectName": "YOUR_PROJECT", "ApplicationName": "YOUR_APP", "StartDate": "2025-11-08", "EndDate": "2025-11-08", "Region": "Sweden Central", "ApproverName": "YOUR_APPROVER", "RequesterName": "CloudOps Team", "BusinessOwner": "YOUR_OWNER", "TechnicalOwner": "YOUR_TECH_OWNER", "CostCenter": "YOUR_COST_CENTER", "ServiceClass": "YOUR_SERVICE_CLASS", "ManagedBy": "CloudOps Team"}')
            raise ValueError("Mandatory tags JSON is required but not provided")
        
        try:
            parsed_tags = json.loads(json_tags)
            if isinstance(parsed_tags, dict):
                tags.update(parsed_tags)
                print(f"[OK] Loaded {len(tags)} tags from JSON format")
                
                # Validate all mandatory tags are present
                missing_tags = [key for key in mandatory_tag_keys if key not in tags]
                if missing_tags:
                    print(f"[ERROR] Missing mandatory tags: {', '.join(missing_tags)}")
                    print("[REQUIRED] Required tags:")
                    for key in mandatory_tag_keys:
                        print(f"  - {key}")
                    raise ValueError(f"Missing mandatory tags: {', '.join(missing_tags)}")
                
                # Validate Company is BAB
                if tags.get('Company', '').upper() != 'BAB':
                    print("[ERROR] Company must be 'BAB'")
                    raise ValueError("Company tag must be 'BAB'")
                
                print("[OK] All mandatory tags validated successfully")
            else:
                raise ValueError("Tags must be a JSON object")
                
        except json.JSONDecodeError as e:
            print(f"[ERROR] Invalid JSON format in tags: {e}")
            print("[EXPECTED] Expected JSON format:")
            print('{"Company": "BAB", "Department": "Information Technology", ...}')
            raise ValueError(f"Invalid JSON format: {e}")
        
        # NOTE: CSV tags are ignored - tags come ONLY from mandatory GUI JSON input
        if tags_str and tags_str.strip():
            print("[INFO] Ignoring CSV tags - using mandatory GUI JSON tags only")
        
        # Add auto-generated tags (these override everything)
        from datetime import datetime
        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = datetime.now().strftime('%Y-%m-%d')
        tags['Environment'] = self.environment
        tags['Project'] = self.project_name
        
        print(f"[TAGS] Final tag count: {len(tags)} (including auto-generated)")
        return tags
    
    def resolve_os_template(self, os_template: str) -> Dict[str, str]:
        """Resolve OS template to detailed OS configuration"""
        template = os_template.strip().lower()
        
        if template not in self.os_templates:
            print(f"[WARNING] Unknown OS template: {os_template}")
            print(f"[INFO] Available templates: {', '.join(self.os_templates.keys())}")
            print(f"[INFO] Defaulting to windows-2019")
            template = "windows-2019"
        
        os_config = self.os_templates[template]
        print(f"[INFO] Using OS template '{template}': {os_config['publisher']} {os_config['offer']} {os_config['sku']}")
        
        return {
            'os_type': os_config['os_type'],
            'publisher': os_config['publisher'],
            'offer': os_config['offer'],
            'sku': os_config['sku'],
            'version': os_config['version']
        }
    
    def generate_terraform(self):
        """Generate Terraform configuration"""
        # Create output directory
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        
        # Get absolute paths for debugging
        abs_output_path = os.path.abspath(self.output_tf_file)
        abs_working_dir = os.path.abspath(".")
        
        print(f"[DEBUG] Current working directory: {abs_working_dir}")
        print(f"[DEBUG] Relative output path: {self.output_tf_file}")
        print(f"[DEBUG] Absolute output path: {abs_output_path}")
        print(f"[DEBUG] Output directory created: {os.path.dirname(abs_output_path)}")
        
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
                    for row_num, row in enumerate(reader, start=2):  # Start at 2 since line 1 is header
                        # Skip empty rows
                        if not row.get("vm_name", "").strip():
                            print(f"Skipping empty row {row_num}")
                            continue
                        
                        print(f"Processing row {row_num}: {dict(row)}")
                        vm_name = row["vm_name"].strip()
                        vm_outputs.append(vm_name)
                        self._generate_vm_resources(tf_file, row, cloud_init_content)
            except FileNotFoundError:
                print(f"[ERROR] CSV file not found: {self.csv_file_path}")
                sys.exit(1)
            
            # Generate outputs
            self._generate_outputs(tf_file, vm_outputs)
        
        print(f"[OK] Terraform configuration generated: {self.output_tf_file}")
        print(f"[OK] Absolute path: {os.path.abspath(self.output_tf_file)}")
        print(f"[INFO] File size: {os.path.getsize(self.output_tf_file)} bytes")
        print(f"[INFO] Resource groups to create: {len(self.resource_groups_to_create)}")
        print(f"[INFO] VMs to deploy: {len(vm_outputs)}")
    
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
        
        print(f"[INFO] Generated outputs for {len(vm_list)} VMs")
    
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
            # Parse default tags for resource group (no CSV tags)
            tags = self.parse_tags()
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
        subnet_name = row["subnet_name"].strip()
        static_ip = row["static_ip"].strip()
        vm_size = row["vm_size"].strip()  # Read directly from CSV
        os_template = row.get("os_template", "windows-2019").strip()
        
        # Resolve OS template to detailed configuration
        os_config = self.resolve_os_template(os_template)
        os_type = os_config['os_type']
        
        custom_tags = row.get("custom_tags", "").strip()  # Will be ignored
        create_rg = row.get("create_rg", "false").lower() == "true"
        
        # Parse tags from environment variables (GUI input)
        tags = self.parse_tags()
        
        print(f"[INFO] Processing VM: {vm_name}")
        print(f"[INFO] Using subnet: {subnet_name}")
        print(f"[INFO] Static IP: {static_ip}")
        print(f"[INFO] OS Template: {os_template}")
        
        # Create OS image object from resolved template
        os_image = {
            'publisher': os_config['publisher'],
            'offer': os_config['offer'],
            'sku': os_config['sku'],
            'version': os_config['version']
        }
        
        # Validate VM size
        if not vm_size:
            print(f"[WARNING] No VM size specified for {vm_name}, using Standard_D4s_v5")
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
        
        # Check if script storage is configured
        script_enabled = all([
            self.config['script_storage_account'],
            self.config['script_storage_container'],
            script_blob_name
        ])
        
        # TEMPORARILY DISABLE Custom Script Extension due to 409 Conflict errors
        # TODO: Enable after resolving blob storage authentication
        script_enabled = False
        
        if script_enabled:
            # Generate SAS URL - TODO: Should be generated dynamically or from Key Vault
            # For now, using direct blob URL (assumes public read or managed identity access)
            sas_url = f"https://{self.config['script_storage_account']}.blob.core.windows.net/{self.config['script_storage_container']}/{script_blob_name}"
            print(f"[INFO] Using {script_description}: {script_blob_name}")
            print(f"[WARNING] Using direct blob URL. Consider implementing dynamic SAS token generation.")
        else:
            print(f"[INFO] Custom Script Extension disabled - preventing 409 Conflict errors")
            print(f"[INFO] Script storage config: storage_account={bool(self.config['script_storage_account'])}, container={bool(self.config['script_storage_container'])}, blob={bool(script_blob_name)}")
            print(f"[TODO] Enable Custom Script Extension after resolving blob storage authentication")
            sas_url = None
        
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
            self._generate_linux_vm(tf_file, vm_name, vm_size, tags_str, cloud_init_content, sas_url, os_image, rg_reference, script_blob_name, script_enabled)
        else:
            self._generate_windows_vm(tf_file, vm_name, vm_size, tags_str, sas_url, os_image, rg_reference, script_blob_name, script_enabled)
        
        # Generate additional disks
        self._generate_data_disks(tf_file, vm_name, row, os_type, rg_reference)
        
        # Generate auto shutdown
        self._generate_auto_shutdown(tf_file, vm_name, tags_str, os_type)
    
    def _generate_linux_vm(self, tf_file, vm_name: str, vm_size: str, tags_str: str, cloud_init_content: str, sas_url: str, os_image: Dict, rg_reference: str, script_blob_name: str, script_enabled: bool = True):
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

# Custom Script Extension (Conditional)''')
        
        if script_enabled and sas_url:
            tf_file.write(f'''
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "sh {script_blob_name}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
        else:
            tf_file.write(f'''
# Custom Script Extension disabled - preventing 409 Conflict errors  
# ISSUE: Blob storage authentication causing deployment failures
# TODO: Configure SAS token generation or managed identity access
# To enable: Resolve blob storage access and set script_enabled = True
''')
        
        tf_file.write('''
''')  # Close the section
    
    def _generate_windows_vm(self, tf_file, vm_name: str, vm_size: str, tags_str: str, sas_url: str, os_image: Dict, rg_reference: str, script_blob_name: str, script_enabled: bool = True):
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

# Custom Script Extension (Conditional)''')
        
        if script_enabled and sas_url:
            tf_file.write(f'''
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File {script_blob_name}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
        else:
            tf_file.write(f'''
# Custom Script Extension disabled - preventing 409 Conflict errors
# ISSUE: Blob storage authentication causing deployment failures
# TODO: Configure SAS token generation or managed identity access
# To enable: Resolve blob storage access and set script_enabled = True
''')
        
        tf_file.write('''
''')  # Close the section
    
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