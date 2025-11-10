#!/usr/bin/env python3
"""
Enhanced VM Creation Terraform Generator v2
Now includes automatic SAS token generation for custom scripts.
Supports DEV/SIT environments with flexible CSV structure.
"""

import base64
import csv
import json
import os
import sys
from datetime import datetime, timedelta
from typing import Dict, Any, List

from azure.storage.blob import (
    BlobServiceClient,
    generate_blob_sas,
    BlobSasPermissions
)


class TerraformVMGenerator:
    def __init__(self):
        """Initialize generator with environment variables"""
        self.environment = os.getenv('ENVIRONMENT', 'DEV')
        self.project_name = os.getenv('PROJECT_NAME', 'BaaS-Platform')

        # Environment-specific configuration
        self.config = {
            'subscription_id': os.getenv('SUBSCRIPTION_ID'),
            'location': os.getenv('LOCATION', 'swedencentral'),
            'vnet_name': os.getenv('VNET_NAME'),
            'vnet_rg': os.getenv('VNET_RG'),
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
            'script_storage_key': os.getenv('SCRIPT_STORAGE_KEY'),  # used for SAS generation
            'shutdown_enabled': os.getenv('SHUTDOWN_ENABLED', 'true')
        }

        # OS Templates
        self.os_templates = {
            "windows-2019": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2019-Datacenter", "version": "latest"},
            "windows-2022": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2022-Datacenter", "version": "latest"},
            "ubuntu-20.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-focal", "sku": "20_04-lts-gen2", "version": "latest"},
            "ubuntu-22.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest"},
            "rhel-8": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "8-LVM", "version": "latest"},
        }

        # Disk Standards
        self.storage_standards = {
            'os_disk_type': 'StandardSSD_LRS',
            'data_disk_type': 'StandardSSD_LRS',
            'disk_caching': 'ReadWrite',
            'data_disk_caching': 'None'
        }

        # Auto Shutdown
        self.shutdown_config = {
            'enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'time': os.getenv('shutdown_time', '2000'),
            'timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }

        # Paths
        self.csv_file_path = os.getenv('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.cloud_init_file = "./core/Deployment-Cloud-init-improved.yaml"

        # SAS Token Settings
        self.sas_duration_hours = 8  # validity of SAS token

        self.resource_groups_to_create = set()
        self.validate_config()

    # -------------------
    # Core Validations
    # -------------------
    def validate_config(self):
        required_vars = ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name']
        missing_vars = [v for v in required_vars if not self.config.get(v)]
        if missing_vars:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing_vars)}")
            sys.exit(1)
        print(f"[OK] Config validated for {self.environment} environment.")

    # -------------------
    # SAS Token Generator
    # -------------------
    def generate_sas_url(self, os_type: str) -> str:
        """Generate a SAS URL for blob script (auto-expires)"""
        account = self.config['script_storage_account']
        container = self.config['script_storage_container']
        key = self.config['script_storage_key']

        if not all([account, container, key]):
            print(f"[WARN] Storage account, container, or key missing. Skipping SAS generation.")
            return None

        blob_name = self.config['script_blob_name_windows'] if os_type.lower() == 'windows' else self.config['script_blob_name_linux']

        expiry = datetime.utcnow() + timedelta(hours=self.sas_duration_hours)
        sas_token = generate_blob_sas(
            account_name=account,
            container_name=container,
            blob_name=blob_name,
            account_key=key,
            permission=BlobSasPermissions(read=True),
            expiry=expiry
        )

        sas_url = f"https://{account}.blob.core.windows.net/{container}/{blob_name}?{sas_token}"
        print(f"[INFO] SAS URL generated for {os_type} script (valid {self.sas_duration_hours}h)")
        return sas_url

    # -------------------
    # Other Core Functions (unchanged)
    # -------------------
    def read_and_encode_cloud_init_yaml(self):
        try:
            with open(self.cloud_init_file, 'r', encoding='utf-8') as f:
                content = f.read()
                encoded = base64.b64encode(content.encode('utf-8')).decode('ascii')
                return encoded
        except FileNotFoundError:
            print(f"[WARN] Cloud-init not found: {self.cloud_init_file}")
            return ""

    def resolve_os_template(self, name: str) -> Dict[str, str]:
        name = name.strip().lower()
        if name not in self.os_templates:
            print(f"[WARN] Unknown OS template '{name}', defaulting to windows-2019.")
            name = "windows-2019"
        return self.os_templates[name]

    # -------------------
    # VM Resource Generator (simplified section)
    # -------------------
    def _generate_vm_resources(self, tf_file, row: Dict[str, str], cloud_init_content: str):
        vm_name = row["vm_name"].strip()
        os_template = row.get("os_template", "windows-2019").strip().lower()
        os_config = self.resolve_os_template(os_template)
        os_type = os_config["os_type"]

        # SAS token generation per OS type
        sas_url = self.generate_sas_url(os_type)

        # Basic info
        print(f"[INFO] Generating VM {vm_name} ({os_type})")

        # Terraform snippet
        tf_file.write(f"\n# --- {vm_name} ({os_type}) ---\n")
        tf_file.write(f"# SAS URL: {sas_url if sas_url else 'None'}\n")

        # (rest of the TF generation continues here — unchanged from your original script)

    def generate_terraform(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        with open(self.output_tf_file, "w") as tf:
            tf.write("# Terraform configuration (auto-generated)\n")
            with open(self.csv_file_path) as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if not row.get("vm_name"): 
                        continue
                    self._generate_vm_resources(tf, row, "")
        print(f"[OK] Terraform config written to {self.output_tf_file}")


def main():
    print("[START] Enhanced Terraform Generator v2 (SAS support)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Terraform configuration generation completed.")


if __name__ == "__main__":
    main()