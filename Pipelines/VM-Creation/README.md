# Azure VM Creation Automation

Enterprise-grade automated VM creation using Terraform, Azure DevOps, and CSV-driven configuration.

## 📁 File Structure

```
VM-Creation/
├── 📚 documentation/
│   ├── VM-Creation-Quick-Start-Guide.md    # 📖 Complete setup & usage guide
│   ├── Copy-Paste-Variable-Values.md       # 📋 Azure DevOps variable configuration
│   └── Simplification-Summary.md           # 📋 Cleanup documentation
│
├── 🔧 core/
│   ├── generate-tf-v2-enhanced.py          # 🐍 Main Python script (CSV → Terraform)
│   ├── simplified-vms.csv                  # 📊 VM specification template
│   ├── variables.tf                        # ⚙️ Terraform variable definitions
│   └── Deployment-Cloud-init.yaml          # ☁️ Linux VM initialization
│
├── 🚀 pipelines/  
│   ├── Terraform-Apply-Modify-Working.yml  # ▶️ Deploy VMs pipeline
│   └── Terraform-Destroy-pipeline.yml      # 🗑️ Destroy VMs pipeline
│
├── 🖥️ scripts/
│   ├── linuxpostconf.sh                    # 🐧 Linux setup (LVM, users, security)
│   └── windows-postconf-script-secure.ps1  # 🪟 Windows setup (domain join, disks)
│
├── 🧪 testing/
│   └── test-vm-creation.py                 # ✅ Local testing & validation
│
└── README.md                               # 📋 This file
```

## 🚀 Quick Start

### 1️⃣ **Read the Guide**
Start with `documentation/VM-Creation-Quick-Start-Guide.md` for complete setup instructions.

### 2️⃣ **Configure Variables**  
Use `documentation/Copy-Paste-Variable-Values.md` to set up Azure DevOps variable groups.

### 3️⃣ **Prepare CSV**
Edit `core/simplified-vms.csv` with your VM specifications.

### 4️⃣ **Deploy**
Run `pipelines/Terraform-Apply-Modify-Working.yml` pipeline in Azure DevOps.

## ✨ Key Features

- **🎯 CSV-Driven**: Bulk VM creation from simple spreadsheet format
- **🔐 Secure**: Azure Key Vault integration for credentials
- **🌐 Multi-OS**: Automatic Windows/Linux script selection
- **📊 Smart Tagging**: Dynamic environment-specific tags
- **🔧 Post-Config**: Automated disk setup and domain joining
- **📈 Enterprise-Ready**: Comprehensive logging and error handling

## 🎯 Usage Examples

### Deploy Development VMs:
```bash
# 1. Update core/simplified-vms.csv with DEV VMs
# 2. Run pipeline with Environment=DEV
# 3. VMs automatically configured with post-scripts
```

### Test Configuration:
```bash
cd testing
python test-vm-creation.py
```

## 📋 Support

- **📖 Documentation**: See `documentation/VM-Creation-Quick-Start-Guide.md`
- **🔧 Configuration**: See `documentation/Copy-Paste-Variable-Values.md`  
- **🧪 Testing**: Use `testing/test-vm-creation.py`
- **📊 Examples**: Check `core/simplified-vms.csv`

---

**🎉 Ready for enterprise VM automation!**

*For detailed setup instructions, troubleshooting, and advanced configuration, see the Quick Start Guide.*