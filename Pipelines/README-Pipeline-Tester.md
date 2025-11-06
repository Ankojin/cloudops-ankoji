# Universal Azure DevOps Pipeline Local Tester

A comprehensive PowerShell script to test ANY Azure DevOps pipeline locally before deployment.

## 🎯 Features

- **Universal Compatibility**: Works with any Azure DevOps YAML pipeline
- **YAML Parsing**: Automatically detects parameters, variables, and steps
- **File Validation**: Checks if referenced scripts and files exist
- **Syntax Checking**: Validates PowerShell script syntax
- **Step Simulation**: Simulates pipeline step execution safely
- **Selective Execution**: Run only specific steps or skip certain steps
- **Environment Simulation**: Replicates Azure DevOps environment variables
- **Detailed Reporting**: Generate JSON reports of pipeline analysis
- **Multiple Modes**: Validation-only, simulation, or full execution modes

## 🚀 Quick Start

```powershell
# Basic validation (recommended first step)
.\local-pipeline-test.ps1 -YamlPath "your-pipeline.yml" -WhatIf

# Full pipeline analysis with verbose output
.\local-pipeline-test.ps1 -YamlPath "your-pipeline.yml" -WhatIf -Verbose

# Simulate step execution
.\local-pipeline-test.ps1 -YamlPath "your-pipeline.yml" -ExecuteSteps
```

## 📋 Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `YamlPath` | string | Path to Azure DevOps YAML pipeline file | Required |
| `Parameters` | hashtable | Pipeline parameters | `@{}` |
| `Variables` | hashtable | Pipeline variables | `@{}` |
| `EnvironmentVariables` | hashtable | Custom environment variables | `@{}` |
| `WhatIf` | switch | Validation mode only (no execution) | False |
| `ExecuteSteps` | switch | Enable step execution simulation | False |
| `StepsToRun` | string[] | Only run steps matching these patterns | All steps |
| `SkipSteps` | string[] | Skip steps matching these patterns | None |
| `Verbose` | switch | Show detailed parsing information | False |
| `GenerateReport` | switch | Create JSON analysis report | False |
| `OutputDirectory` | string | Directory for reports and logs | Current directory |

## 🔧 Usage Examples

### Basic Validation
```powershell
# Validate pipeline syntax and structure
.\local-pipeline-test.ps1 -YamlPath "ci-pipeline.yml" -WhatIf

# Detailed validation with verbose output
.\local-pipeline-test.ps1 -YamlPath "deploy-pipeline.yml" -WhatIf -Verbose
```

### Testing with Parameters
```powershell
# Test with specific parameters
.\local-pipeline-test.ps1 -YamlPath "build-pipeline.yml" -WhatIf -Parameters @{
    environment = 'staging'
    version = '2.1.0'
    configuration = 'Release'
}

# Test with variables and environment settings
.\local-pipeline-test.ps1 -YamlPath "infrastructure.yml" -WhatIf -Variables @{
    resourceGroup = 'test-rg'
    location = 'eastus'
} -EnvironmentVariables @{
    ARM_CLIENT_ID = 'test-client-id'
    ARM_TENANT_ID = 'test-tenant-id'
}
```

### Step Execution Simulation
```powershell
# Simulate all steps
.\local-pipeline-test.ps1 -YamlPath "full-pipeline.yml" -ExecuteSteps

# Execute only specific steps
.\local-pipeline-test.ps1 -YamlPath "pipeline.yml" -ExecuteSteps -StepsToRun @('Build', 'Test', 'Package')

# Skip deployment steps
.\local-pipeline-test.ps1 -YamlPath "pipeline.yml" -ExecuteSteps -SkipSteps @('Deploy', 'Release')
```

### Advanced Scenarios
```powershell
# Generate comprehensive report
.\local-pipeline-test.ps1 -YamlPath "complex-pipeline.yml" -WhatIf -GenerateReport -OutputDirectory "C:\Reports" -Verbose

# Test multi-environment pipeline
.\local-pipeline-test.ps1 -YamlPath "multi-env.yml" -ExecuteSteps -Parameters @{
    targetEnvironment = 'dev'
    deploymentMode = 'incremental'
} -Variables @{
    buildNumber = '20231105.1'
}
```

## 📊 Output Information

The tester provides detailed information about:

- **Pipeline Structure**: Parameters, variables, steps count
- **File Validation**: Existence and syntax of referenced files
- **Step Analysis**: Type, display name, and execution path for each step
- **Environment Setup**: Azure DevOps environment variable simulation
- **Execution Results**: Success/failure rates for simulated steps

## 🔍 What Gets Analyzed

### YAML Structure
- Parameters and their defaults
- Variables and their values
- Steps, jobs, and stages
- File references and paths

### File Validation
- PowerShell script syntax checking
- File existence verification
- Path resolution for Azure DevOps variables

### Step Types Supported
- **PowerShell**: File-based and inline scripts
- **Task**: Azure DevOps marketplace tasks
- **Script**: Shell scripts
- **Bash**: Linux bash scripts

## 🚨 Safety Features

- **No Actual Execution**: By default, only simulates execution
- **WhatIf Mode**: Safe validation without any side effects
- **Syntax Validation**: Catches PowerShell errors before deployment
- **Path Checking**: Verifies all referenced files exist
- **Selective Execution**: Choose which steps to run/skip

## 📁 Environment Simulation

The tester sets up Azure DevOps-like environment variables:

```
SYSTEM_DEFAULTWORKINGDIRECTORY = Current directory
AGENT_TEMPDIRECTORY = System temp folder
BUILD_REPOSITORY_NAME = Repository name
BUILD_SOURCESDIRECTORY = Current directory
AGENT_BUILDDIRECTORY = Current directory
SYSTEM_TEAMPROJECT = 'LocalTest'
BUILD_BUILDNUMBER = Timestamp-based build number
BUILD_DEFINITIONNAME = Pipeline filename
AGENT_OS = Current OS (Windows/Linux)
```

## 🎯 Use Cases

### Pre-Deployment Validation
- Verify YAML syntax before committing
- Check all referenced files exist
- Validate PowerShell script syntax
- Test parameter combinations

### Development & Debugging
- Test pipeline changes locally
- Debug script issues without Azure DevOps
- Validate new step additions
- Test variable substitutions

### CI/CD Pipeline Types
- **Build Pipelines**: Validate build steps and artifacts
- **Release Pipelines**: Test deployment logic
- **Infrastructure Pipelines**: Verify Terraform/ARM templates
- **Multi-Stage Pipelines**: Analyze complex workflows

### Team Workflows
- Code reviews with pipeline validation
- Onboarding new team members
- Documentation and training
- Pipeline quality assurance

## 📈 Best Practices

1. **Always start with `-WhatIf`** for initial validation
2. **Use `-Verbose`** for detailed troubleshooting
3. **Test with real parameters** that match your environment
4. **Generate reports** for documentation and auditing
5. **Run before every commit** to catch issues early
6. **Use selective execution** to test specific functionality

## 🔧 Customization

The script can be easily customized for specific needs:

- Add custom step type handlers
- Extend environment variable simulation
- Integrate with specific tools or frameworks
- Add organization-specific validation rules

## 📝 Reports

When using `-GenerateReport`, the tester creates a comprehensive JSON report containing:

- Pipeline structure analysis
- File validation results
- Environment configuration
- Execution summary (if applicable)
- Timestamps and metadata

## 🤝 Integration

The universal tester integrates well with:

- **Git hooks**: Run validation on commit/push
- **VS Code**: Use as task for integrated development
- **CI systems**: Validate pipelines in other CI tools
- **Documentation**: Generate pipeline documentation
- **Testing frameworks**: Part of infrastructure testing

---

## 💡 Pro Tips

- Keep the tester in your repository root for easy access
- Create project-specific parameter files for common scenarios
- Use with git hooks to prevent broken pipeline commits
- Combine with Azure CLI for complete pipeline validation workflow

This universal tester works with ANY Azure DevOps pipeline, making it an invaluable tool for DevOps teams!