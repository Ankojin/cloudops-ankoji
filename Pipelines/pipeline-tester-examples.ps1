# Universal Azure DevOps Pipeline Tester - Usage Examples
# ========================================================

# Basic pipeline validation (recommended first step)
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -WhatIf

# Detailed validation with verbose output
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -WhatIf -Verbose

# Test with parameters and variables
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -WhatIf -Parameters @{time_zone='EST'} -Variables @{environment='dev'}

# Simulate step execution (safe simulation mode)
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -ExecuteSteps

# Execute only specific steps
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -ExecuteSteps -StepsToRun @('Setup', 'Validate')

# Skip certain steps
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -ExecuteSteps -SkipSteps @('Terraform', 'Deploy')

# Generate detailed report
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -WhatIf -GenerateReport -OutputDirectory "C:\Reports"

# Test any other pipeline
.\local-pipeline-test.ps1 -YamlPath "..\..\other-pipeline.yml" -WhatIf

# Test with environment variables
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -WhatIf -EnvironmentVariables @{ARM_CLIENT_ID='test'; ARM_TENANT_ID='test'}

# Advanced: Full simulation with custom environment
.\local-pipeline-test.ps1 -YamlPath "autoshutdown-multiple-csv.yml" -ExecuteSteps -Parameters @{time_zone='UTC'} -Variables @{buildId='123'} -EnvironmentVariables @{CUSTOM_VAR='value'} -Verbose -GenerateReport

# Examples for different pipeline types:

# CI/CD Pipeline
# .\local-pipeline-test.ps1 -YamlPath "ci-cd-pipeline.yml" -WhatIf -Parameters @{environment='staging'; version='2.1.0'}

# Infrastructure Pipeline  
# .\local-pipeline-test.ps1 -YamlPath "infrastructure-deploy.yml" -ExecuteSteps -SkipSteps @('Deploy') -Variables @{resourceGroup='test-rg'}

# Build Pipeline
# .\local-pipeline-test.ps1 -YamlPath "build-pipeline.yml" -ExecuteSteps -StepsToRun @('Build', 'Test'} -Variables @{buildConfiguration='Release'}

# Multi-stage Pipeline
# .\local-pipeline-test.ps1 -YamlPath "multi-stage-deploy.yml" -WhatIf -Verbose -GenerateReport

Write-Host "📚 Universal Pipeline Tester Usage Examples" -ForegroundColor Cyan
Write-Host "Copy and paste any of the above commands to test your pipelines!" -ForegroundColor Yellow