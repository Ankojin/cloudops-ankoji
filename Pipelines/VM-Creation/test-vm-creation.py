#!/usr/bin/env python3
"""
Test script to validate CSV processing and environment variable handling
"""

import os
import csv
import sys

def test_environment_variables():
    """Test if required environment variables are set"""
    required_vars = [
        'ENVIRONMENT', 'PROJECT_NAME', 'SUBSCRIPTION_ID', 'VNET_NAME',
        'KEYVAULT_NAME', 'LOCATION'
    ]
    
    print("🔍 Testing Environment Variables:")
    missing_vars = []
    for var in required_vars:
        value = os.getenv(var)
        if value:
            print(f"  ✅ {var}: {value}")
        else:
            print(f"  ❌ {var}: Not set")
            missing_vars.append(var)
    
    return len(missing_vars) == 0, missing_vars

def test_csv_reading():
    """Test CSV file reading and processing"""
    print("\n📊 Testing CSV File Processing:")
    try:
        with open('simplified-vms.csv', 'r') as file:
            csv_reader = csv.DictReader(file)
            rows = list(csv_reader)
            
        print(f"  ✅ CSV file read successfully")
        print(f"  ✅ Found {len(rows)} VM configurations")
        print(f"  ✅ Columns: {list(rows[0].keys()) if rows else 'None'}")
        
        # Validate required columns
        required_columns = ['vm_name', 'resource_group', 'vm_size', 'os_type']
        missing_columns = [col for col in required_columns if col not in rows[0].keys()]
        
        if missing_columns:
            print(f"  ❌ Missing required columns: {missing_columns}")
            return False, []
        
        print("  ✅ All required columns present")
        
        # Show sample data
        print(f"\n📝 Sample VM Configuration:")
        for i, row in enumerate(rows[:2]):  # Show first 2 VMs
            print(f"  VM {i+1}: {row['vm_name']} ({row['vm_size']}, {row['os_type']})")
        
        return True, rows
        
    except FileNotFoundError:
        print("  ❌ simplified-vms.csv file not found")
        return False, []
    except Exception as e:
        print(f"  ❌ Error reading CSV: {str(e)}")
        return False, []

def test_terraform_generation_preparation():
    """Test basic Terraform generation logic"""
    print("\n🏗️ Testing Terraform Generation Preparation:")
    
    project_name = os.getenv('PROJECT_NAME', 'BaaS-Platform')
    project_dir = f"Project/{project_name}"
    
    print(f"  📁 Project directory would be: {project_dir}")
    print(f"  📄 Main file would be: {project_dir}/main.tf")
    
    # Test directory creation logic
    try:
        if not os.path.exists("Project"):
            print("  📁 Project directory does not exist (normal for test)")
        else:
            print("  📁 Project directory already exists")
        
        return True
    except Exception as e:
        print(f"  ❌ Error in directory logic: {str(e)}")
        return False

def main():
    """Main test function"""
    print("🧪 VM Creation Python Script - Test Mode")
    print("=" * 50)
    
    # Test 1: Environment Variables
    env_ok, missing_vars = test_environment_variables()
    
    # Test 2: CSV Processing
    csv_ok, vm_data = test_csv_reading()
    
    # Test 3: Terraform Preparation
    tf_ok = test_terraform_generation_preparation()
    
    # Summary
    print("\n📋 Test Summary:")
    print("=" * 50)
    if env_ok:
        print("  ✅ Environment variables: PASSED")
    else:
        print(f"  ❌ Environment variables: FAILED (missing: {missing_vars})")
    
    if csv_ok:
        print(f"  ✅ CSV processing: PASSED ({len(vm_data)} VMs found)")
    else:
        print("  ❌ CSV processing: FAILED")
    
    if tf_ok:
        print("  ✅ Terraform preparation: PASSED")
    else:
        print("  ❌ Terraform preparation: FAILED")
    
    overall_status = env_ok and csv_ok and tf_ok
    print(f"\n🎯 Overall Test Status: {'PASSED ✅' if overall_status else 'FAILED ❌'}")
    
    if overall_status:
        print("\n🚀 Ready to proceed with full Terraform generation!")
    else:
        print("\n⚠️ Fix issues before proceeding with pipeline execution.")
    
    return 0 if overall_status else 1

if __name__ == "__main__":
    sys.exit(main())