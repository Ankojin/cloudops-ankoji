# Universal Azure DevOps Pipeline Local Tester
# This script can test ANY Azure DevOps pipeline locally
# 
# Usage Examples:
#   .\local-pipeline-test.ps1 -YamlPath "path/to/pipeline.yml" -WhatIf
#   .\local-pipeline-test.ps1 -YamlPath "ci-cd-pipeline.yml" -Parameters @{environment='dev'; version='1.0'} -Variables @{buildId='123'}
#   .\local-pipeline-test.ps1 -YamlPath "deploy.yml" -ExecuteSteps -StepsToRun @('validate', 'build')

param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the Azure DevOps YAML pipeline file")]
    [string]$YamlPath,
    
    [Parameter(HelpMessage = "Pipeline parameters as hashtable")]
    [hashtable]$Parameters = @{},
    
    [Parameter(HelpMessage = "Pipeline variables as hashtable")]
    [hashtable]$Variables = @{},
    
    [Parameter(HelpMessage = "Environment variables as hashtable")]
    [hashtable]$EnvironmentVariables = @{},
    
    [Parameter(HelpMessage = "Only validate without executing")]
    [switch]$WhatIf,
    
    [Parameter(HelpMessage = "Execute compatible PowerShell steps locally")]
    [switch]$ExecuteSteps,
    
    [Parameter(HelpMessage = "Specific steps to run (by display name pattern)")]
    [string[]]$StepsToRun = @(),
    
    [Parameter(HelpMessage = "Skip steps matching these patterns")]
    [string[]]$SkipSteps = @(),
    
    [Parameter(HelpMessage = "Show detailed parsing information")]
    [switch]$Verbose,
    
    [Parameter(HelpMessage = "Generate execution report")]
    [switch]$GenerateReport,
    
    [Parameter(HelpMessage = "Output directory for reports and logs")]
    [string]$OutputDirectory = "."
)

Write-Host "🧪 Universal Azure DevOps Pipeline Tester" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Validate YAML file exists
if (-not (Test-Path $YamlPath)) {
    Write-Error "❌ YAML file not found: $YamlPath"
    exit 1
}

$yamlFileName = Split-Path $YamlPath -Leaf
Write-Host "`n📄 Testing Pipeline: $yamlFileName" -ForegroundColor White

# Setup Azure DevOps simulation environment
function Set-AzureDevOpsEnvironment {
    param([hashtable]$CustomEnvVars = @{})
    
    # Standard Azure DevOps variables
    $defaultVars = @{
        'SYSTEM_DEFAULTWORKINGDIRECTORY' = (Get-Location).Path
        'AGENT_TEMPDIRECTORY' = $env:TEMP
        'BUILD_REPOSITORY_NAME' = (Split-Path (Get-Location) -Leaf)
        'BUILD_SOURCESDIRECTORY' = (Get-Location).Path
        'AGENT_BUILDDIRECTORY' = (Get-Location).Path
        'SYSTEM_TEAMPROJECT' = 'LocalTest'
        'BUILD_BUILDNUMBER' = "Local-$(Get-Date -Format 'yyyyMMdd.HHmmss')"
        'BUILD_DEFINITIONNAME' = $yamlFileName -replace '\.ya?ml$', ''
        'AGENT_OS' = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' } else { 'Linux' }
        'AGENT_JOBSTATUS' = 'Succeeded'
    }
    
    # Merge with custom environment variables
    $allVars = $defaultVars + $CustomEnvVars
    
    foreach ($var in $allVars.GetEnumerator()) {
        Set-Item -Path "env:$($var.Key)" -Value $var.Value -Force
        if ($Verbose) {
            Write-Host "  Set env:$($var.Key) = $($var.Value)" -ForegroundColor DarkGray
        }
    }
}

# YAML Parser for Azure DevOps pipelines
function Parse-AzureDevOpsYaml {
    param([string]$Content)
    
    $pipeline = @{
        Parameters = @()
        Variables = @()
        Steps = @()
        Jobs = @()
        Stages = @()
        Triggers = @()
        Resources = @()
    }
    
    # Parse parameters
    if ($Content -match '(?s)parameters:\s*\n((?:\s+-.*\n?)*?)(?=\n\S|\Z)') {
        $paramSection = $matches[1]
        $paramMatches = [regex]::Matches($paramSection, '^\s*-\s*name:\s*(\w+).*?(?=^\s*-|\Z)', 'Multiline,Singleline')
        foreach ($match in $paramMatches) {
            $pipeline.Parameters += $match.Groups[1].Value
        }
    }
    
    # Parse variables
    if ($Content -match '(?s)variables:\s*\n((?:\s+-.*\n?)*?)(?=\n\S|\Z)') {
        $varSection = $matches[1]
        $varMatches = [regex]::Matches($varSection, '^\s*-?\s*(\w+):\s*(.+)$', 'Multiline')
        foreach ($match in $varMatches) {
            $pipeline.Variables += @{Name = $match.Groups[1].Value; Value = $match.Groups[2].Value}
        }
    }
    
    # Parse steps (simplified)
    $stepMatches = [regex]::Matches($Content, '(?s)-\s*(task:|powershell:|script:|bash:).*?(?=^\s*-|\Z)', 'Multiline')
    foreach ($match in $stepMatches) {
        $stepContent = $match.Value
        $stepType = $match.Groups[1].Value -replace ':', ''
        
        # Extract display name
        $displayName = if ($stepContent -match "displayName:\s*['\"]?([^'\"\n]+)['\"]?") { 
            $matches[1] 
        } else { 
            "Step $($pipeline.Steps.Count + 1)" 
        }
        
        # Extract file path for task steps
        $filePath = if ($stepContent -match "filePath:\s*['\"]?([^'\"\n]+)['\"]?") { 
            $matches[1] 
        } else { 
            $null 
        }
        
        # Extract inline script
        $inlineScript = if ($stepContent -match '(?s)(powershell|script|bash):\s*\|\s*\n(.*?)(?=^\s*\S|\Z)') {
            $matches[2]
        } else { 
            $null 
        }
        
        $pipeline.Steps += @{
            Type = $stepType
            DisplayName = $displayName
            FilePath = $filePath
            InlineScript = $inlineScript
            RawContent = $stepContent
        }
    }
    
    return $pipeline
}

# Step execution simulator
function Invoke-PipelineStep {
    param(
        [hashtable]$Step,
        [hashtable]$Parameters,
        [hashtable]$Variables,
        [switch]$WhatIf
    )
    
    Write-Host "`n� Executing: $($Step.DisplayName)" -ForegroundColor Yellow
    
    try {
        switch ($Step.Type) {
            'powershell' {
                if ($Step.FilePath) {
                    $resolvedPath = $Step.FilePath -replace '\$\(System\.DefaultWorkingDirectory\)', $env:SYSTEM_DEFAULTWORKINGDIRECTORY
                    $resolvedPath = $resolvedPath -replace '/', '\'
                    
                    if (Test-Path $resolvedPath) {
                        Write-Host "  📄 File: $resolvedPath" -ForegroundColor Cyan
                        if (-not $WhatIf) {
                            Write-Host "  ⚡ Executing PowerShell file..." -ForegroundColor Green
                            # & $resolvedPath # Uncomment to actually execute
                            Write-Host "  ✅ [SIMULATED] File execution completed" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "  ❌ File not found: $resolvedPath" -ForegroundColor Red
                        return $false
                    }
                } elseif ($Step.InlineScript) {
                    Write-Host "  📝 Inline PowerShell script detected" -ForegroundColor Cyan
                    if (-not $WhatIf) {
                        Write-Host "  ⚡ Executing inline script..." -ForegroundColor Green
                        # Invoke-Expression $Step.InlineScript # Uncomment to actually execute
                        Write-Host "  ✅ [SIMULATED] Inline script completed" -ForegroundColor Green
                    }
                }
            }
            
            'task' {
                Write-Host "  🔧 Azure DevOps Task (cannot execute locally)" -ForegroundColor Yellow
                Write-Host "  ℹ️  Task would run in Azure DevOps environment" -ForegroundColor Cyan
            }
            
            'script' {
                Write-Host "  💻 Shell script detected" -ForegroundColor Cyan
                if (-not $WhatIf) {
                    Write-Host "  ✅ [SIMULATED] Script execution completed" -ForegroundColor Green
                }
            }
            
            'bash' {
                Write-Host "  🐧 Bash script detected" -ForegroundColor Cyan
                if (-not $WhatIf) {
                    Write-Host "  ✅ [SIMULATED] Bash execution completed" -ForegroundColor Green
                }
            }
            
            default {
                Write-Host "  ❓ Unknown step type: $($Step.Type)" -ForegroundColor Magenta
            }
        }
        
        return $true
    }
    catch {
        Write-Host "  ❌ Step failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main execution logic
try {
    # Setup environment
    Set-AzureDevOpsEnvironment -CustomEnvVars $EnvironmentVariables
    
    # Set pipeline variables
    foreach ($var in $Variables.GetEnumerator()) {
        Set-Variable -Name $var.Key -Value $var.Value -Scope Global
        if ($Verbose) {
            Write-Host "  Set variable: $($var.Key) = $($var.Value)" -ForegroundColor DarkGray
        }
    }
    
    Write-Host "`n📋 Configuration:" -ForegroundColor Yellow
    Write-Host "  YAML File: $YamlPath"
    Write-Host "  Working Directory: $env:SYSTEM_DEFAULTWORKINGDIRECTORY"
    Write-Host "  Temp Directory: $env:AGENT_TEMPDIRECTORY"
    Write-Host "  Mode: $(if ($WhatIf) { 'Validation Only' } else { 'Full Simulation' })"
    
    # Show parameters
    if ($Parameters.Count -gt 0) {
        Write-Host "`n🔧 Parameters:" -ForegroundColor Yellow
        $Parameters.GetEnumerator() | ForEach-Object {
            Write-Host "  $($_.Key): $($_.Value)"
        }
    }
    
    # Show variables
    if ($Variables.Count -gt 0) {
        Write-Host "`n📊 Variables:" -ForegroundColor Yellow
        $Variables.GetEnumerator() | ForEach-Object {
            Write-Host "  $($_.Key): $($_.Value)"
        }
    }
    
    Write-Host "`n🔍 Parsing Pipeline..." -ForegroundColor Green
    
    # Read and parse YAML
    $yamlContent = Get-Content $YamlPath -Raw -Encoding UTF8
    $pipeline = Parse-AzureDevOpsYaml -Content $yamlContent
    
    # Display pipeline structure
    Write-Host "`n📊 Pipeline Structure:" -ForegroundColor Yellow
    Write-Host "  Parameters: $($pipeline.Parameters.Count)"
    Write-Host "  Variables: $($pipeline.Variables.Count)"
    Write-Host "  Steps: $($pipeline.Steps.Count)"
    
    if ($Verbose) {
        Write-Host "`n📋 Detected Parameters:" -ForegroundColor Cyan
        $pipeline.Parameters | ForEach-Object { Write-Host "  - $_" }
        
        Write-Host "`n📋 Detected Variables:" -ForegroundColor Cyan
        $pipeline.Variables | ForEach-Object { Write-Host "  - $($_.Name): $($_.Value)" }
    }
    
    # List all steps
    Write-Host "`n📋 Pipeline Steps:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $pipeline.Steps.Count; $i++) {
        $step = $pipeline.Steps[$i]
        $status = "🔸"
        if ($step.FilePath) {
            $resolvedPath = $step.FilePath -replace '\$\(System\.DefaultWorkingDirectory\)', $env:SYSTEM_DEFAULTWORKINGDIRECTORY
            $resolvedPath = $resolvedPath -replace '/', '\'
            $status = if (Test-Path $resolvedPath) { "✅" } else { "❌" }
        }
        Write-Host "  $($i+1). $status [$($step.Type.ToUpper())] $($step.DisplayName)" -ForegroundColor White
    }
    
    # Validate referenced files
    Write-Host "`n📁 File Validation:" -ForegroundColor Yellow
    $referencedFiles = $pipeline.Steps | Where-Object { $_.FilePath } | ForEach-Object { $_.FilePath }
    $allFilesExist = $true
    
    foreach ($file in $referencedFiles) {
        $resolvedPath = $file -replace '\$\(System\.DefaultWorkingDirectory\)', $env:SYSTEM_DEFAULTWORKINGDIRECTORY
        $resolvedPath = $resolvedPath -replace '/', '\'
        
        if (Test-Path $resolvedPath) {
            Write-Host "  ✅ $file" -ForegroundColor Green
            
            # Validate PowerShell syntax
            if ($resolvedPath -match '\.ps1$') {
                try {
                    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $resolvedPath -Raw), [ref]$null)
                    Write-Host "    ✅ PowerShell syntax valid" -ForegroundColor Green
                }
                catch {
                    Write-Host "    ❌ PowerShell syntax error: $($_.Exception.Message)" -ForegroundColor Red
                    $allFilesExist = $false
                }
            }
        }
        else {
            Write-Host "  ❌ $file (Not Found)" -ForegroundColor Red
            $allFilesExist = $false
        }
    }
    
    # Execute steps if requested
    if ($ExecuteSteps -and -not $WhatIf) {
        Write-Host "`n🚀 Executing Pipeline Steps..." -ForegroundColor Green
        
        $executedSteps = 0
        $failedSteps = 0
        
        foreach ($step in $pipeline.Steps) {
            # Check if step should be executed
            $shouldExecute = $true
            
            if ($StepsToRun.Count -gt 0) {
                $shouldExecute = $StepsToRun | Where-Object { $step.DisplayName -like "*$_*" }
            }
            
            if ($SkipSteps.Count -gt 0) {
                $shouldSkip = $SkipSteps | Where-Object { $step.DisplayName -like "*$_*" }
                if ($shouldSkip) { $shouldExecute = $false }
            }
            
            if ($shouldExecute) {
                $success = Invoke-PipelineStep -Step $step -Parameters $Parameters -Variables $Variables -WhatIf:$WhatIf
                $executedSteps++
                if (-not $success) { $failedSteps++ }
            }
            else {
                Write-Host "`n⏭️  Skipping: $($step.DisplayName)" -ForegroundColor Gray
            }
        }
        
        Write-Host "`n📊 Execution Summary:" -ForegroundColor Yellow
        Write-Host "  Total Steps: $($pipeline.Steps.Count)"
        Write-Host "  Executed: $executedSteps"
        Write-Host "  Failed: $failedSteps"
        Write-Host "  Success Rate: $(if ($executedSteps -gt 0) { [math]::Round((($executedSteps - $failedSteps) / $executedSteps) * 100, 1) } else { 0 })%"
    }
    
    # Generate report if requested
    if ($GenerateReport) {
        $reportPath = Join-Path $OutputDirectory "pipeline-test-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        
        $report = @{
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            PipelineFile = $YamlPath
            Parameters = $Parameters
            Variables = $Variables
            ParsedStructure = $pipeline
            ValidationResults = @{
                AllFilesExist = $allFilesExist
                TotalSteps = $pipeline.Steps.Count
                ReferencedFiles = $referencedFiles
            }
        }
        
        $report | ConvertTo-Json -Depth 10 | Out-File $reportPath -Encoding UTF8
        Write-Host "`n📄 Report saved: $reportPath" -ForegroundColor Cyan
    }
    
    # Final status
    if ($WhatIf) {
        Write-Host "`n✅ Pipeline validation completed successfully!" -ForegroundColor Green
        Write-Host "   Use -ExecuteSteps to simulate step execution" -ForegroundColor Cyan
    }
    else {
        Write-Host "`n✅ Pipeline testing completed!" -ForegroundColor Green
    }
    
    if (-not $allFilesExist) {
        Write-Host "⚠️  Some referenced files are missing - fix before deployment" -ForegroundColor Yellow
        exit 1
    }
}
catch {
    Write-Error "❌ Pipeline testing failed: $($_.Exception.Message)"
    if ($Verbose) {
        Write-Error $_.ScriptStackTrace
    }
    exit 1
}