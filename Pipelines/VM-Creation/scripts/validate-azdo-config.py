#!/usr/bin/env python3
"""
Azure DevOps Configuration Validation Script
Validates that all required variable groups and configurations are properly set up
"""

import json
import os
import sys
from typing import Dict, List, Any

class AzureDevOpsConfigValidator:
    def __init__(self):
        """Initialize validator with required configurations"""
        self.required_global_vars = [
            'TF_STATE_PATH',
            'pythonVersion',
            'terraformVersion'
        ]
        
        self.required_env_vars = [
            'subscription_id',
            'location',
            'vnet_name',
            'vnet_rg',
            'subnet_rg',
            'subnets_config',
            'keyvault_name',
            'keyvault_rg',
            'dcr_name',
            'dcr_rg',
            'diagnostics_storage',
            'diagnostics_storage_rg',
            'script_storage_account',
            'script_storage_container',
            'script_blob_name_linux',
            'script_blob_name_windows',
            'shutdown_enabled',
            'shutdown_time',
            'shutdown_timezone'
        ]
        
        self.validation_results = []
        
    def validate_environment_variables(self, environment: str):
        """Validate environment variables for a specific environment"""
        print(f"\n🔍 Validating {environment} Environment Configuration")
        print("=" * 60)
        
        missing_vars = []
        invalid_json_vars = []
        
        for var_name in self.required_env_vars:
            var_value = os.getenv(var_name)
            
            if not var_value:
                missing_vars.append(var_name)
                print(f"❌ MISSING: {var_name}")
            else:
                print(f"✅ FOUND: {var_name}")
                
                # Validate JSON format for subnets_config
                if var_name == 'subnets_config':
                    try:
                        subnets = json.loads(var_value)
                        if isinstance(subnets, dict) and subnets:
                            print(f"  📍 Subnets: {list(subnets.keys())}")
                            for subnet_type, subnet_list in subnets.items():
                                print(f"    - {subnet_type}: {len(subnet_list)} subnets")
                        else:
                            invalid_json_vars.append(var_name)
                            print(f"  ❌ Invalid JSON structure for {var_name}")
                    except json.JSONDecodeError:
                        invalid_json_vars.append(var_name)
                        print(f"  ❌ Invalid JSON format for {var_name}")
                        
                # Validate boolean values
                elif var_name in ['shutdown_enabled']:
                    if var_value.lower() not in ['true', 'false']:
                        print(f"  ⚠️ WARNING: {var_name} should be 'true' or 'false', found: {var_value}")
        
        # Summary for this environment
        if missing_vars:
            print(f"\n❌ {environment} Environment: {len(missing_vars)} missing variables")
            self.validation_results.append({
                'environment': environment,
                'status': 'FAIL',
                'missing_vars': missing_vars,
                'invalid_json_vars': invalid_json_vars
            })
        elif invalid_json_vars:
            print(f"\n⚠️ {environment} Environment: Variables found but {len(invalid_json_vars)} have invalid JSON")
            self.validation_results.append({
                'environment': environment,
                'status': 'PARTIAL',
                'missing_vars': [],
                'invalid_json_vars': invalid_json_vars
            })
        else:
            print(f"\n✅ {environment} Environment: All variables validated successfully")
            self.validation_results.append({
                'environment': environment,
                'status': 'PASS',
                'missing_vars': [],
                'invalid_json_vars': []
            })
    
    def validate_mandatory_tags(self):
        """Validate mandatory tags JSON format"""
        print(f"\n🏷️ Validating Mandatory Tags Configuration")
        print("=" * 60)
        
        mandatory_tag_keys = [
            "Company", "Department", "ProjectName", "ApplicationName",
            "StartDate", "EndDate", "Region", "ApproverName",
            "RequesterName", "BusinessOwner", "TechnicalOwner",
            "CostCenter", "ServiceClass", "ManagedBy"
        ]
        
        tags_json = os.getenv('default_tags_json', '{}')
        
        if not tags_json or tags_json.strip() == '{}':
            print("⚠️ No mandatory tags provided - this is expected for validation")
            print("💡 Tags will be provided via pipeline GUI during execution")
            return
        
        try:
            tags = json.loads(tags_json)
            missing_tags = [key for key in mandatory_tag_keys if key not in tags]
            
            if missing_tags:
                print(f"❌ Missing mandatory tags: {', '.join(missing_tags)}")
            else:
                print("✅ All mandatory tags structure validated")
                
                # Validate Company tag
                if tags.get('Company', '').upper() != 'BAB':
                    print("❌ Company tag must be 'BAB'")
                else:
                    print("✅ Company tag validated")
                    
        except json.JSONDecodeError as e:
            print(f"❌ Invalid JSON format in tags: {e}")
    
    def validate_file_structure(self):
        """Validate required files exist"""
        print(f"\n📁 Validating File Structure")
        print("=" * 60)
        
        required_files = [
            'core/generate-tf-v2-enhanced.py',
            'core/simplified-vms.csv',
            'core/Deployment-Cloud-init.yaml',
            'pipelines/Terraform-Apply-Modify-Working.yml'
        ]
        
        base_path = os.getcwd()
        
        for file_path in required_files:
            full_path = os.path.join(base_path, file_path)
            if os.path.exists(full_path):
                print(f"✅ FOUND: {file_path}")
            else:
                print(f"❌ MISSING: {file_path}")
                
    def validate_azure_resources_connectivity(self):
        """Validate Azure resources can be accessed (simulation)"""
        print(f"\n🔗 Azure Resources Connectivity Check")
        print("=" * 60)
        
        azure_resources = [
            ('VNet', os.getenv('vnet_name'), os.getenv('vnet_rg')),
            ('Key Vault', os.getenv('keyvault_name'), os.getenv('keyvault_rg')),
            ('DCR', os.getenv('dcr_name'), os.getenv('dcr_rg')),
            ('Storage', os.getenv('diagnostics_storage'), os.getenv('diagnostics_storage_rg'))
        ]
        
        for resource_type, resource_name, resource_rg in azure_resources:
            if resource_name and resource_rg:
                print(f"✅ {resource_type}: {resource_name} in {resource_rg}")
                print(f"   💡 Validate access to this resource in Azure portal")
            else:
                print(f"❌ {resource_type}: Missing configuration")
    
    def print_summary(self):
        """Print validation summary"""
        print(f"\n📊 VALIDATION SUMMARY")
        print("=" * 60)
        
        total_envs = len(self.validation_results)
        passed_envs = len([r for r in self.validation_results if r['status'] == 'PASS'])
        failed_envs = len([r for r in self.validation_results if r['status'] == 'FAIL'])
        partial_envs = len([r for r in self.validation_results if r['status'] == 'PARTIAL'])
        
        print(f"Environments Validated: {total_envs}")
        print(f"✅ Passed: {passed_envs}")
        print(f"⚠️ Partial: {partial_envs}")
        print(f"❌ Failed: {failed_envs}")
        
        if failed_envs > 0:
            print(f"\n❌ CONFIGURATION ISSUES FOUND")
            print("Please fix the missing variables before running the pipeline.")
            return False
        elif partial_envs > 0:
            print(f"\n⚠️ CONFIGURATION WARNINGS")
            print("Some configurations have issues but pipeline may still work.")
            return True
        else:
            print(f"\n✅ ALL CONFIGURATIONS VALIDATED")
            print("Ready for pipeline execution!")
            return True
    
    def generate_sample_config(self):
        """Generate sample variable group configuration"""
        print(f"\n📝 SAMPLE VARIABLE GROUP CONFIGURATION")
        print("=" * 60)
        
        sample_config = {
            "VM-Creation-SIT": {
                "subscription_id": "12345678-1234-1234-1234-123456789012",
                "location": "swedencentral",
                "vnet_name": "vnet-baas-sit-001",
                "vnet_rg": "rg-networking-sit",
                "subnets_config": json.dumps({
                    "app": ["snet-sit-nonpci-app-01", "snet-sit-nonpci-app-02"],
                    "db": ["snet-sit-nonpci-db-01"],
                    "web": ["snet-sit-nonpci-web-01"]
                }),
                "keyvault_name": "kv-baas-sit-001",
                "keyvault_rg": "rg-security-sit"
            }
        }
        
        print("Copy this configuration to your Azure DevOps variable groups:")
        print(json.dumps(sample_config, indent=2))

def main():
    """Main validation function"""
    print("🚀 Azure DevOps Configuration Validator")
    print("=" * 60)
    
    validator = AzureDevOpsConfigValidator()
    
    # Determine environment from env var or default to SIT
    environment = os.getenv('ENVIRONMENT', 'SIT')
    
    # Validate current environment configuration
    validator.validate_environment_variables(environment)
    
    # Validate mandatory tags
    validator.validate_mandatory_tags()
    
    # Validate file structure
    validator.validate_file_structure()
    
    # Validate Azure resources
    validator.validate_azure_resources_connectivity()
    
    # Print summary
    success = validator.print_summary()
    
    # Generate sample config if needed
    if not success:
        validator.generate_sample_config()
    
    return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())