#!/usr/bin/env python3
"""
Enhanced VM Creation Terraform Generator v2 (fixed)
Handles multiple subnets, resource groups, and standardized configurations
Supports DEV/SIT environments with flexible CSV structure
"""

import base64
from datetime import datetime, timedelta
from azure.storage.blob import generate_blob_sas, BlobSasPermissions
import csv
import json
import os
import re
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
            # RHEL, CentOS, SLES...
            "rhel-8": {
                "os_type": "linux",
                "publisher": "RedHat",
                "offer": "RHEL",
                "sku": "8-LVM",
                "version": "latest"
            },
            "rhel-9": {
                "os_type": "linux",
                "publisher": "RedHat",
                "offer": "RHEL",
                "sku": "9_4",
                "version": "latest"
            },
            "centos-7": {
                "os_type": "linux",
                "publisher": "OpenLogic",
                "offer": "CentOS",
                "sku": "7_9-gen2",
                "version": "latest"
            },
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
            'os_disk_type': 'StandardSSD_LRS',
            'data_disk_type': 'StandardSSD_LRS',
            'disk_caching': 'ReadWrite',
            'data_disk_caching': 'None'
        }

        # Auto shutdown (hardcoded)
        self.shutdown_config = {
            'enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'time': os.getenv('shutdown_time', '2000'),
            'timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }

        # Paths - relative to pipeline working directory
        self.csv_file_path = os.getenv('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"

        # Track resource groups to create
        self.resource_groups_to_create = set()

        # Enable custom scripts by default
        self.enable_custom_scripts = True  # ✅ ENABLED now by default
        self.sas_expiry_hours = int(os.getenv('SAS_EXPIRY_HOURS', '6'))

    # === NEW FUNCTION ===
    def _generate_sas_url(self, os_type: str) -> str:
        """Generate a time-bound SAS URL for the OS-specific setup script"""
        account_name = self.config['script_storage_account']
        account_key = os.getenv('SCRIPT_STORAGE_KEY')
        container_name = self.config['script_storage_container']
        
        if not account_key:
            print("[ERROR] SCRIPT_STORAGE_KEY environment variable is missing!")
            sys.exit(1)

        # Choose blob depending on OS type
        blob_name = (
            self.config['script_blob_name_windows']
            if os_type.lower() == 'windows'
            else self.config['script_blob_name_linux']
        )

        if not blob_name:
            print(f"[ERROR] Missing blob name for {os_type} script in configuration.")
            sys.exit(1)

        expiry_time = datetime.utcnow() + timedelta(hours=self.sas_expiry_hours)

        sas_token = generate_blob_sas(
            account_name=account_name,
            container_name=container_name,
            blob_name=blob_name,
            account_key=account_key,
            permission=BlobSasPermissions(read=True),
            expiry=expiry_time
        )

        sas_url = f"https://{account_name}.blob.core.windows.net/{container_name}/{blob_name}?{sas_token}"

        # Mask for output
        masked_token = sas_token[:40] + "...(masked)"
        print(f"[SAS] Generated {os_type} SAS URL (valid {self.sas_expiry_hours}h):")
        print(f"       https://{account_name}.blob.core.windows.net/{container_name}/{blob_name}?sv=...&sig={masked_token}")
        return sas_url

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

    def parse_tags(self, tags_str: str = None) -> Dict[str, str]:
        """Parse mandatory tags from JSON format only (environment variable default_tags_json)"""
        mandatory_tag_keys = [
            "Company", "Department", "ProjectName", "ApplicationName",
            "StartDate", "EndDate", "Region", "ApproverName",
            "RequesterName", "BusinessOwner", "TechnicalOwner",
            "CostCenter", "ServiceClass", "ManagedBy"
        ]

        tags = {}
        json_tags = os.getenv('default_tags_json')
        if not json_tags or json_tags.strip() == '{}' or json_tags.strip() == '':
            print("[ERROR] Mandatory tags are required!")
            print("[REQUIRED] Provide default_tags_json environment variable with required tags.")
            raise ValueError("Mandatory tags JSON is required but not provided")

        try:
            parsed_tags = json.loads(json_tags)
            if not isinstance(parsed_tags, dict):
                raise ValueError("Tags must be a JSON object")
            tags.update(parsed_tags)

            missing_tags = [key for key in mandatory_tag_keys if key not in tags]
            if missing_tags:
                print(f"[ERROR] Missing mandatory tags: {', '.join(missing_tags)}")
                raise ValueError(f"Missing mandatory tags: {', '.join(missing_tags)}")

            if tags.get('Company', '').upper() != 'BAB':
                print("[ERROR] Company must be 'BAB'")
                raise ValueError("Company tag must be 'BAB'")

            print(f"[OK] Loaded {len(tags)} tags from JSON format")

        except json.JSONDecodeError as e:
            print(f"[ERROR] Invalid JSON format in tags: {e}")
            raise

        # Add auto-generated tags
        from datetime import datetime
        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = datetime.now().strftime('%Y-%m-%d')
        tags['Environment'] = self.environment
        tags['Project'] = self.project_name

        return tags

    def _format_tags(self, tags: Dict[str, str]) -> str:
        """Format Python dict tags to Terraform HCL map text"""
        items = []
        for k, v in tags.items():
            # Escape double quotes in values
            safe_v = str(v).replace('"', '\\"')
            items.append(f'    "{k}" = "{safe_v}"')
        return ",\n".join(items)

    def resolve_os_template(self, os_template: str) -> Dict[str, str]:
        """Resolve OS template to detailed OS configuration"""
        template = os_template.strip().lower()
        if template not in self.os_templates:
            print(f"[WARNING] Unknown OS template: {os_template}. Defaulting to windows-2019")
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

    def _sanitize_resource_name(self, name: str) -> str:
        """Sanitize a string so it is safe as a Terraform resource identifier"""
        # Terraform resource names: letters, digits, underscores, dashes are allowed in names, but identifiers can't contain dashes
        # We'll convert dashes to underscores and remove illegal chars
        return re.sub(r'[^0-9A-Za-z_]', '_', name.replace('-', '_'))

    def generate_terraform(self):
        """Generate Terraform configuration"""
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)

        abs_output_path = os.path.abspath(self.output_tf_file)
        abs_working_dir = os.path.abspath(".")
        print(f"[DEBUG] Current working directory: {abs_working_dir}")
        print(f"[DEBUG] Output path: {abs_output_path}")

        vm_outputs: List[str] = []

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
                    for row_num, row in enumerate(reader, start=2):  # start=2 because header is line 1
                        vm_name_raw = (row.get("vm_name") or "").strip()
                        if not vm_name_raw:
                            print(f"[DEBUG] Skipping empty row {row_num}")
                            continue

                        # sanitize for Terraform identifiers
                        vm_name = self._sanitize_resource_name(vm_name_raw)
                        print(f"[INFO] Processing row {row_num}: vm_name='{vm_name_raw}' -> identifier='{vm_name}'")
                        vm_outputs.append(vm_name)
                        self._generate_vm_resources(tf_file, row, vm_name)
            except FileNotFoundError:
                print(f"[ERROR] CSV file not found: {self.csv_file_path}")
                sys.exit(1)

            # Generate outputs
            self._generate_outputs(tf_file, vm_outputs)

        print(f"[OK] Terraform configuration generated: {self.output_tf_file}")
        print(f"[INFO] File size: {os.path.getsize(self.output_tf_file)} bytes")
        print(f"[INFO] Resource groups to create: {len(self.resource_groups_to_create)}")
        print(f"[INFO] VMs to deploy: {len(vm_outputs)}")

    def _generate_outputs(self, tf_file, vm_list: List[str]):
        """Generate Terraform outputs for VM information"""
        tf_file.write('\n# ==== Outputs ====\n\n')
        tf_file.write('output "vm_private_ips" {\n  description = "Private IP addresses of all VMs"\n  value = {\n')
        for vm_name in vm_list:
            tf_file.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.private_ip_address\n')
        tf_file.write('  }\n}\n\n')

        tf_file.write('output "vm_resource_groups" {\n  description = "Resource groups containing the VMs"\n  value = {\n')
        for vm_name in vm_list:
            tf_file.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.resource_group_name\n')
        tf_file.write('  }\n}\n\n')

        tf_file.write('output "deployment_summary" {\n  description = "Deployment summary information"\n  value = {\n')
        tf_file.write('    environment     = var.environment\n')
        # vm_count and names
        tf_file.write(f'    vm_count       = {len(vm_list)}\n')
        names_list = ', '.join([f'"{n}"' for n in vm_list])
        tf_file.write(f'    vm_names       = [{names_list}]\n')
        tf_file.write(f'    project_name   = "{self.project_name}"\n')
        tf_file.write('    deployment_time = timestamp()\n')
        tf_file.write('  }\n}\n\n')

        print(f"[INFO] Generated outputs for {len(vm_list)} VMs")

    def _collect_resource_groups(self):
        """First pass to collect all resource groups that need to be created"""
        try:
            with open(self.csv_file_path, newline='') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if (row.get("create_rg") or "").strip().lower() == "true":
                        rg_name = (row.get("resource_group") or "").strip()
                        if rg_name:
                            self.resource_groups_to_create.add(rg_name)
        except FileNotFoundError:
            # upstream will handle missing CSV; here we just skip
            pass

    def _generate_resource_groups(self, tf_file):
        """Generate resource group resources"""
        if not self.resource_groups_to_create:
            return
        tf_file.write("\n# ==== Resource Groups ====\n")
        for rg_name in sorted(self.resource_groups_to_create):
            identifier = self._sanitize_resource_name(rg_name) + "_rg"
            tags = self.parse_tags()
            tags_str = self._format_tags(tags)
            tf_file.write(f'''
resource "azurerm_resource_group" "{identifier}" {{
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
        print(f"[CONFIG] Provider and datasources written. Local backend path: C:\\TerraformState\\Project\\{self.project_name}\\{self.environment}\\")

    def _generate_vm_resources(self, tf_file, row: Dict[str, str], vm_name: str):
        """Generate Terraform resources for a single VM"""
        resource_group = (row.get("resource_group") or "").strip()
        vm_role = (row.get("vm_role") or "").strip()
        subnet_name = (row.get("subnet_name") or "").strip()
        static_ip = (row.get("static_ip") or "").strip()
        vm_size = (row.get("vm_size") or "").strip()
        os_template = (row.get("os_template") or "windows-2019").strip()

        os_config = self.resolve_os_template(os_template)
        os_type = os_config['os_type']

        create_rg = (row.get("create_rg") or "false").strip().lower() == "true"

        tags = self.parse_tags()
        tags_str = self._format_tags(tags)

        print(f"[INFO] Processing VM: {vm_name} - subnet: {subnet_name} - static_ip: {static_ip} - os_template: {os_template}")

        os_image = {
            'publisher': os_config['publisher'],
            'offer': os_config['offer'],
            'sku': os_config['sku'],
            'version': os_config['version']
        }

        if not vm_size:
            print(f"[WARNING] No VM size specified for {vm_name}, using Standard_D4s_v5")
            vm_size = "Standard_D4s_v5"

        if os_type.lower() == 'windows':
            script_blob_name = self.config['script_blob_name_windows']
            script_description = "Windows PowerShell setup script"
        else:
            script_blob_name = self.config['script_blob_name_linux']
            script_description = "Linux shell setup script"

    # Generate SAS URL automatically if scripts enabled
    sas_url = None
    if self.enable_custom_scripts:
      try:
        sas_url = self._generate_sas_url(os_type)
      except Exception as e:
        print(f"[ERROR] SAS generation failed for {vm_name}: {e}")
        sas_url = None
    else:
      print("[SKIP] Custom scripts globally disabled.")

    # Replace old sas_url logic with automatic SAS from above
    if sas_url:
      print(f"[OK] Using SAS URL for {os_type} script (time-limited)")
    else:
      print(f"[WARN] No SAS URL generated for {vm_name}, skipping script extension.")

        # Resource group reference expression for Terraform
        if create_rg:
            rg_identifier = self._sanitize_resource_name(resource_group) + "_rg"
            rg_reference = f'azurerm_resource_group.{rg_identifier}.name'
        else:
            rg_reference = f'"{resource_group}"'

        # Subnet data source
        tf_file.write(f'''
# ==== {vm_name} Resources ====

data "azurerm_subnet" "{vm_name}_subnet" {{
  name                 = "{subnet_name}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault_secret" "{vm_name}_admin_password" {{
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

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
            self._generate_linux_vm(tf_file, vm_name, vm_size, tags_str, sas_url, os_image, rg_reference, script_blob_name, script_enabled)
        else:
            self._generate_windows_vm(tf_file, vm_name, vm_size, tags_str, sas_url, os_image, rg_reference, script_blob_name, script_enabled)

        # Additional disks and shutdown
        self._generate_data_disks(tf_file, vm_name, row, os_type, rg_reference)
        self._generate_auto_shutdown(tf_file, vm_name, tags_str, os_type)

    def _generate_linux_vm(self, tf_file, vm_name: str, vm_size: str, tags_str: str, sas_url: str, os_image: Dict, rg_reference: str, script_blob_name: str, script_enabled: bool = True):
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

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
{tags_str}
  }}
}}
''')

        # Extensions (Linux) - AMA + DCR association + optional script
        tf_file.write(f'''
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {{
{tags_str}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_linux_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}
''')

        if script_enabled and sas_url:
            tf_file.write(f'''
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "bash {script_blob_name}"
  }})

  tags = {{
{tags_str}
  }}
}}
''')
        else:
            tf_file.write('\n# Custom Script Extension DISABLED for Linux\n')

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
''')

        tf_file.write(f'''
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

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_windows_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}
''')

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
            tf_file.write('\n# Custom Script Extension DISABLED for Windows\n')

    def _generate_data_disks(self, tf_file, vm_name: str, row: Dict[str, str], os_type: str, rg_reference: str):
        """Generate additional data disks for VM"""
        vm_resource_type = "linux_virtual_machine" if os_type == "linux" else "windows_virtual_machine"
        for idx in range(1, 4):
            disk_size = (row.get(f"disk_{idx}_size") or "").strip()
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
    print("[START] Enhanced Terraform VM Configuration Generator v2 (fixed)")
    generator = TerraformVMGenerator()
    generator.generate_terraform()
    print("[SUCCESS] Terraform configuration generation completed successfully")

if __name__ == "__main__":
    main()