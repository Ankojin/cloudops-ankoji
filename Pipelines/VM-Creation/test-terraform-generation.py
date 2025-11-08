#!/usr/bin/env python3
"""
Safe Terraform generation test - creates files but doesn't deploy
"""

import os
import sys
import json

# Add the directory containing the original script to the path
sys.path.insert(0, '.')

# Set additional required environment variables for testing
os.environ['DIAGNOSTICS_STORAGE'] = 'testdiagnosticstorage'
os.environ['SCRIPT_STORAGE_CONTAINER'] = 'scripts'
os.environ['SCRIPT_BLOB_NAME'] = 'test-script.sh'
os.environ['DCR_NAME'] = 'test-dcr'
os.environ['DCR_RG'] = 'test-dcr-rg'
os.environ['DEFAULT_TAGS'] = 'Environment=DEV;Project=BaaS-Platform'

# Create a simple CSV with just one test VM for safe testing
test_csv_content = """vm_name,resource_group,vm_role,subnet_type,subnet_index,static_ip,vm_size,os_type,os_publisher,os_offer,os_sku,os_version,disk_1_size,disk_2_size,disk_3_size,custom_tags,create_rg
TESTVM01,test-rg-01,test_server,app,0,10.189.56.100,Standard_B2s,linux,RedHat,RHEL,92-gen2,latest,128,,,Environment=Test;Project=Test,true"""

# Write test CSV
with open('test-vms.csv', 'w') as f:
    f.write(test_csv_content)

print("🧪 Testing Terraform Generation (Safe Mode)")
print("=" * 50)

try:
    # Import the main generator class
    from generate_tf_v2_enhanced import TerraformVMGenerator
    
    # Create an instance
    generator = TerraformVMGenerator()
    
    # Override the CSV file name for testing
    generator.csv_file = 'test-vms.csv'
    
    print("✅ Successfully imported TerraformVMGenerator")
    print(f"📊 Environment: {generator.environment}")
    print(f"📁 Project: {generator.project_name}")
    print(f"🌍 Location: {generator.config.get('location', 'Not set')}")
    
    # Test CSV reading
    print("\n📊 Testing CSV Reading:")
    try:
        vm_data = generator.read_vm_data()
        print(f"  ✅ Read {len(vm_data)} VM configurations from test CSV")
        for vm in vm_data:
            print(f"    - {vm['vm_name']} ({vm['vm_size']}, {vm['os_type']})")
    except Exception as e:
        print(f"  ❌ Error reading CSV: {str(e)}")
        sys.exit(1)
    
    # Test configuration generation (without file creation)
    print("\n🏗️ Testing Configuration Generation:")
    try:
        # Generate the configuration
        config = generator.generate_terraform_config()
        print("  ✅ Terraform configuration generated successfully")
        print(f"  📄 Configuration length: {len(config)} characters")
        
        # Show a snippet
        lines = config.split('\n')[:20]
        print("\n📝 Configuration Preview (first 20 lines):")
        for i, line in enumerate(lines, 1):
            print(f"  {i:2d}: {line}")
        
        if len(lines) < len(config.split('\n')):
            remaining = len(config.split('\n')) - len(lines)
            print(f"    ... and {remaining} more lines")
            
    except Exception as e:
        print(f"  ❌ Error generating configuration: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    
    print("\n✅ Safe Terraform Generation Test: PASSED")
    print("\n🎯 The Python script can successfully:")
    print("  ✅ Read environment variables")
    print("  ✅ Process CSV data") 
    print("  ✅ Generate Terraform configuration")
    print("\n🚀 Ready for pipeline testing!")

except ImportError as e:
    print(f"❌ Could not import generate-tf-v2-enhanced.py: {str(e)}")
    print("This might be due to the filename having hyphens instead of underscores")
    
    # Try to fix the import by copying the file with a Python-friendly name
    print("\n🔧 Attempting to create a Python-importable version...")
    try:
        with open('generate-tf-v2-enhanced.py', 'r') as source:
            content = source.read()
        
        with open('generate_tf_v2_enhanced.py', 'w') as target:
            target.write(content)
        
        print("✅ Created generate_tf_v2_enhanced.py")
        print("🔄 Please run the test again")
        
    except Exception as copy_error:
        print(f"❌ Could not create importable version: {str(copy_error)}")

except Exception as e:
    print(f"❌ Unexpected error: {str(e)}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

finally:
    # Clean up test files
    for test_file in ['test-vms.csv', 'generate_tf_v2_enhanced.py']:
        if os.path.exists(test_file):
            os.remove(test_file)
            print(f"🧹 Cleaned up {test_file}")