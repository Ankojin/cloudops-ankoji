# 🐍 Python Configuration for cloudops-agent

## 🔧 **What Was Updated**

Since we switched from `ubuntu-latest` (Linux) to `cloudops-agent` (Windows), the Python configuration needed several important updates:

### **1. Added Python Setup Task**
```yaml
# Added to both Apply and Destroy pipelines:
- task: UsePythonVersion@0
  inputs:
    versionSpec: '$(pythonVersion)'  # Set to "3.9"
    addToPath: true
    architecture: 'x64'
  displayName: 'Setup Python $(pythonVersion)'
```

### **2. Updated Python Command**
```yaml
# BEFORE (Linux):
python3 $(tfWorkingDirectory)/generate-tf-v2-enhanced.py

# AFTER (Windows):
python $(tfWorkingDirectory)/generate-tf-v2-enhanced.py
```

### **3. Converted Scripts to PowerShell**
```yaml
# BEFORE (Bash):
- script: |
    export ENVIRONMENT="${{ parameters.environment }}"
    python3 script.py

# AFTER (PowerShell):
- task: PowerShell@2
  inputs:
    targetType: 'inline'
    script: |
      $env:ENVIRONMENT = "${{ parameters.environment }}"
      python script.py
```

## 🏗️ **Agent Requirements**

Your `cloudops-agent` must have:

### **Required Software:**
- ✅ **Python 3.9** (or compatible version)
- ✅ **Azure CLI** (for `az login` commands)
- ✅ **Terraform** (for infrastructure deployment)
- ✅ **PowerShell** (for pipeline scripts)

### **Python Modules:**
The `generate-tf-v2-enhanced.py` script uses these standard modules:
```python
import base64
import csv
import json
import os
import sys
from typing import Dict, Any, List
```
*No additional pip installs required - all standard library modules*

## 🔍 **How Python is Used**

### **1. Environment Variables**
Python script receives all configuration via environment variables:
```python
# From Variable Groups:
self.environment = os.getenv('ENVIRONMENT', 'DEV')
self.project_name = os.getenv('PROJECT_NAME', 'BaaS-Platform')
self.config = {
    'subscription_id': os.getenv('SUBSCRIPTION_ID'),
    'vnet_name': os.getenv('VNET_NAME'),
    'keyvault_name': os.getenv('KEYVAULT_NAME'),
    # ... and many more
}
```

### **2. CSV Processing**
```python
# Reads VM specifications from CSV:
with open('simplified-vms.csv', 'r') as file:
    csv_reader = csv.DictReader(file)
    for row in csv_reader:
        # Process each VM configuration
```

### **3. Terraform Generation**
```python
# Creates main.tf with all resources:
def generate_terraform_config(self):
    # Provider configuration
    # Data sources
    # Resource groups
    # Virtual machines
    # Network interfaces
    # Managed disks
    # Extensions
```

## ⚡ **Pipeline Execution Flow**

### **Python Integration Steps:**
```
1. Setup Python Task
   ├── Install Python 3.9
   ├── Add to PATH
   └── Verify installation

2. Set Environment Variables (PowerShell)
   ├── PROJECT_NAME = "BaaS-Platform"
   ├── ENVIRONMENT = "DEV" or "SIT"
   ├── All Variable Group values
   └── TF_STATE_PATH = "C:/TerraformState/..."

3. Execute Python Script (PowerShell)
   ├── cd to working directory
   ├── Set environment variables
   ├── Run: python generate-tf-v2-enhanced.py
   └── Generate: Project/BaaS-Platform/main.tf

4. Continue with Terraform Operations
   ├── terraform init
   ├── terraform plan
   └── terraform apply
```

## 🔧 **Troubleshooting Python Issues**

### **Common Problems & Solutions:**

**1. Python Not Found:**
```yaml
# Ensure UsePythonVersion task runs first:
- task: UsePythonVersion@0
  inputs:
    versionSpec: '3.9'
    addToPath: true
```

**2. Module Import Errors:**
```bash
# All modules are standard library - no pip installs needed
# If issues persist, check Python installation on agent
```

**3. Environment Variable Issues:**
```powershell
# Debug environment variables in PowerShell:
Write-Host "ENVIRONMENT: $($env:ENVIRONMENT)"
Write-Host "PROJECT_NAME: $($env:PROJECT_NAME)"
Get-ChildItem env: | Where-Object {$_.Name -like "*VNET*"}
```

**4. Script Execution Errors:**
```powershell
# PowerShell error handling:
python "$(tfWorkingDirectory)/generate-tf-v2-enhanced.py"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Python script failed!"
    exit 1
}
```

## 📋 **Verification Steps**

### **Test Python Setup:**
```powershell
# Check Python version:
python --version
# Should output: Python 3.9.x

# Test script execution:
python -c "import sys; print(sys.version)"

# Verify environment variables:
python -c "import os; print(f'ENV: {os.getenv(\"ENVIRONMENT\", \"Not Set\")}')"
```

## 🚨 **Important Notes**

### **Windows vs Linux Differences:**
- ✅ **Command**: Use `python` not `python3`
- ✅ **Paths**: Windows paths with backslashes handled by Python
- ✅ **Environment**: PowerShell environment variable syntax
- ✅ **Error Handling**: PowerShell `$LASTEXITCODE` instead of bash `$?`

### **Agent Prerequisites:**
Make sure your `cloudops-agent` has:
- Python 3.9+ installed and in PATH
- Azure CLI installed for authentication
- Terraform installed for infrastructure operations
- Proper permissions to create directories in `C:\TerraformState\`

The Python configuration is now fully compatible with your Windows-based `cloudops-agent` and will work seamlessly with the VM creation process.