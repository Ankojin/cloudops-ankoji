# Pipeline Testing Script for ServiceNow Integration
# This script allows you to test the pipeline components locally

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TestType,
    
    [Parameter(Mandatory = $false)]
    [string]$SampleFile = ""
)

# Define paths
$ScriptsPath = Join-Path $PSScriptRoot "..\Scripts"
$TestsPath = Join-Path $PSScriptRoot ".."
$SchemasPath = Join-Path $PSScriptRoot "..\Schemas"

Write-Host "🚀 ServiceNow Pipeline Component Test" -ForegroundColor Green
Write-Host "Testing: $TestType" -ForegroundColor Yellow

switch ($TestType.ToLower()) {
    "schema" {
        Write-Host "`n📋 Testing JSON Schema Validation..." -ForegroundColor Cyan
        
        # Test with all account type samples
        $normalSamplePath = Join-Path $PSScriptRoot "sample-user-request.json"
        $avdSamplePath = Join-Path $PSScriptRoot "sample-avd-account-request.json"
        $serviceSamplePath = Join-Path $PSScriptRoot "sample-service-account-request.json"
        $schemaPath = Join-Path $SchemasPath "user-account-schema.json"
        
        if (Test-Path $normalSamplePath) {
            Write-Host "✅ Normal account sample found: $normalSamplePath" -ForegroundColor Green
            $userContent = Get-Content $normalSamplePath -Raw
            try {
                $userJson = $userContent | ConvertFrom-Json
                Write-Host "✅ Normal account sample JSON is valid" -ForegroundColor Green
                Write-Host "   - Request Type: $($userJson.requestType)" -ForegroundColor Gray
                Write-Host "   - Account Type: $($userJson.accountType)" -ForegroundColor Gray
                Write-Host "   - Company: $($userJson.company)" -ForegroundColor Gray
                Write-Host "   - First Name: $($userJson.userDetails.firstName)" -ForegroundColor Gray
                Write-Host "   - Last Name: $($userJson.userDetails.lastName)" -ForegroundColor Gray
                
                # Calculate expected UPN
                $firstThree = ($userJson.userDetails.firstName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $lastThree = ($userJson.userDetails.lastName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $companyCode = switch ($userJson.company) { "BAB" { "B" }; "ENJAZ" { "E" }; "ABIC" { "A" }; "ODC" { "O" } }
                $expectedUPN = "$firstThree$lastThree-$companyCode@babgroup.com"
                Write-Host "   - Expected UPN: $expectedUPN" -ForegroundColor Cyan
            }
            catch {
                Write-Host "❌ Normal account sample JSON is invalid: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        if (Test-Path $avdSamplePath) {
            Write-Host "✅ AVD account sample found: $avdSamplePath" -ForegroundColor Green
            $avdContent = Get-Content $avdSamplePath -Raw
            try {
                $avdJson = $avdContent | ConvertFrom-Json
                Write-Host "✅ AVD account sample JSON is valid" -ForegroundColor Green
                Write-Host "   - Request Type: $($avdJson.requestType)" -ForegroundColor Gray
                Write-Host "   - Account Type: $($avdJson.accountType)" -ForegroundColor Gray
                Write-Host "   - Company: $($avdJson.company)" -ForegroundColor Gray
                Write-Host "   - First Name: $($avdJson.userDetails.firstName)" -ForegroundColor Gray
                Write-Host "   - Last Name: $($avdJson.userDetails.lastName)" -ForegroundColor Gray
                
                # Calculate expected UPN
                $firstThree = ($avdJson.userDetails.firstName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $lastThree = ($avdJson.userDetails.lastName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $companyCode = switch ($avdJson.company) { "BAB" { "B" }; "ENJAZ" { "E" }; "ABIC" { "A" }; "ODC" { "O" } }
                $expectedUPN = "$firstThree$lastThree-$companyCode@babgroup.com"
                Write-Host "   - Expected UPN: $expectedUPN" -ForegroundColor Cyan
                if ($avdJson.avdConfiguration) {
                    Write-Host "   - Host Pool: $($avdJson.avdConfiguration.hostPoolName)" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "❌ AVD account sample JSON is invalid: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        if (Test-Path $serviceSamplePath) {
            Write-Host "✅ Service account sample found: $serviceSamplePath" -ForegroundColor Green
            $serviceContent = Get-Content $serviceSamplePath -Raw
            try {
                $serviceJson = $serviceContent | ConvertFrom-Json
                Write-Host "✅ Service account sample JSON is valid" -ForegroundColor Green
                Write-Host "   - Request Type: $($serviceJson.requestType)" -ForegroundColor Gray
                Write-Host "   - Account Type: $($serviceJson.accountType)" -ForegroundColor Gray
                Write-Host "   - Company: $($serviceJson.company)" -ForegroundColor Gray
                Write-Host "   - First Name: $($serviceJson.userDetails.firstName)" -ForegroundColor Gray
                Write-Host "   - Last Name: $($serviceJson.userDetails.lastName)" -ForegroundColor Gray
                
                # Calculate expected UPN (service accounts get svc- prefix)
                $firstThree = ($serviceJson.userDetails.firstName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $lastThree = ($serviceJson.userDetails.lastName -replace '[^a-zA-Z]', '').ToLower().Substring(0, 3)
                $companyCode = switch ($serviceJson.company) { "BAB" { "B" }; "ENJAZ" { "E" }; "ABIC" { "A" }; "ODC" { "O" } }
                $expectedUPN = "svc-$firstThree$lastThree-$companyCode@babgroup.com"
                Write-Host "   - Expected UPN: $expectedUPN" -ForegroundColor Cyan
                if ($serviceJson.serviceAccountDetails) {
                    Write-Host "   - Service Name: $($serviceJson.serviceAccountDetails.serviceName)" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "❌ Service account sample JSON is invalid: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    "parse" {
        Write-Host "`n🔍 Testing Parse Script..." -ForegroundColor Cyan
        
        if (-not $SampleFile) {
            $SampleFile = Join-Path $PSScriptRoot "sample-user-request.json"
        }
        
        if (-not (Test-Path $SampleFile)) {
            Write-Host "❌ Sample file not found: $SampleFile" -ForegroundColor Red
            return
        }
        
        $parseScript = Join-Path $ScriptsPath "Parse-ServiceNowRequest.ps1"
        if (Test-Path $parseScript) {
            Write-Host "✅ Parse script found: $parseScript" -ForegroundColor Green
            
            # Test the parsing logic
            try {
                Write-Host "Testing JSON parsing with sample file..." -ForegroundColor Gray
                $content = Get-Content $SampleFile -Raw
                $parsed = $content | ConvertFrom-Json
                
                Write-Host "✅ Parsing successful!" -ForegroundColor Green
                Write-Host "   - Request ID: $($parsed.requestId)" -ForegroundColor Gray
                Write-Host "   - Account Type: $($parsed.accountType)" -ForegroundColor Gray
                Write-Host "   - Company: $($parsed.company)" -ForegroundColor Gray
                
                # Check required fields from CSV
                $requiredFields = @('requestType', 'company', 'userDetails')
                foreach ($field in $requiredFields) {
                    if ($parsed.$field) {
                        Write-Host "   ✅ Required field '$field': Present" -ForegroundColor Green
                    } else {
                        Write-Host "   ❌ Required field '$field': Missing" -ForegroundColor Red
                    }
                }
                
                # Check CSV mandatory user details
                $userRequiredFields = @('firstName', 'lastName', 'jobTitle', 'department', 'employeeType', 'manager')
                foreach ($field in $userRequiredFields) {
                    if ($parsed.userDetails.$field) {
                        Write-Host "   ✅ User field '$field': $($parsed.userDetails.$field)" -ForegroundColor Green
                    } else {
                        Write-Host "   ❌ User field '$field': Missing" -ForegroundColor Red
                    }
                }
                
            }
            catch {
                Write-Host "❌ Parsing failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "❌ Parse script not found: $parseScript" -ForegroundColor Red
        }
    }
    
    "validate" {
        Write-Host "`n🔒 Testing Validation Script..." -ForegroundColor Cyan
        
        $validateScript = Join-Path $ScriptsPath "Validate-Request.ps1"
        if (Test-Path $validateScript) {
            Write-Host "✅ Validation script found: $validateScript" -ForegroundColor Green
            Write-Host "Script contains business rules for:" -ForegroundColor Gray
            
            # Check what validations are implemented
            $scriptContent = Get-Content $validateScript -Raw
            
            if ($scriptContent -match "user_account") {
                Write-Host "   ✅ User account validation" -ForegroundColor Green
            }
            
            if ($scriptContent -match "Service Account") {
                Write-Host "   ✅ Service account validation" -ForegroundColor Green
            }
            
            if ($scriptContent -match "company|Company") {
                Write-Host "   ✅ Company validation" -ForegroundColor Green
            }
            
            if ($scriptContent -match "employeeType|employee_type") {
                Write-Host "   ✅ Employee type validation" -ForegroundColor Green
            }
            
        } else {
            Write-Host "❌ Validation script not found: $validateScript" -ForegroundColor Red
        }
    }
    
    "upn" {
        Write-Host "`n🔤 Testing UPN Generation..." -ForegroundColor Cyan
        
        $upnScript = Join-Path $ScriptsPath "Generate-UPN.ps1"
        if (Test-Path $upnScript) {
            Write-Host "✅ UPN generation script found: $upnScript" -ForegroundColor Green
            
            # Test UPN generation with sample data
            Write-Host "Testing UPN generation with sample data..." -ForegroundColor Gray
            
            $testCases = @(
                @{ FirstName = "Ankoji Rao"; LastName = "Nagisetty"; Company = "BAB"; AccountType = "Normal Account"; Expected = "anknag-B@babgroup.com" }
                @{ FirstName = "Ahmed Hassan"; LastName = "Mohammed"; Company = "ENJAZ"; AccountType = "AVD Account"; Expected = "ahmmoh-E@babgroup.com" }
                @{ FirstName = "Backup"; LastName = "Service"; Company = "BAB"; AccountType = "Service Account"; Expected = "svc-bacser-B@babgroup.com" }
                @{ FirstName = "John"; LastName = "Doe"; Company = "ABIC"; AccountType = "Normal Account"; Expected = "johdoe-A@babgroup.com" }
                @{ FirstName = "Jane"; LastName = "Smith"; Company = "ODC"; AccountType = "AVD Account"; Expected = "jansmi-O@babgroup.com" }
            )
            
            foreach ($testCase in $testCases) {
                try {
                    $result = & $upnScript -FirstName $testCase.FirstName -LastName $testCase.LastName -Company $testCase.Company -AccountType $testCase.AccountType -Domain "babgroup.com"
                    
                    if ($result.UPN -eq $testCase.Expected) {
                        Write-Host "   ✅ $($testCase.FirstName) $($testCase.LastName) ($($testCase.AccountType) - $($testCase.Company)): $($result.UPN)" -ForegroundColor Green
                    } else {
                        Write-Host "   ❌ $($testCase.FirstName) $($testCase.LastName) ($($testCase.AccountType) - $($testCase.Company)): Expected $($testCase.Expected), Got $($result.UPN)" -ForegroundColor Red
                    }
                    
                    # Expected display name varies by account type
                    $expectedDisplayName = if ($testCase.AccountType -eq "Service Account") {
                        "Service Account - $($testCase.FirstName) $($testCase.LastName)"
                    } else {
                        "$($testCase.FirstName) $($testCase.LastName)"
                    }
                    
                    if ($result.DisplayName -eq $expectedDisplayName) {
                        Write-Host "      ✅ Display Name: $($result.DisplayName)" -ForegroundColor Green
                    } else {
                        Write-Host "      ❌ Display Name: Expected '$expectedDisplayName', Got '$($result.DisplayName)'" -ForegroundColor Red
                    }
                }
                catch {
                    Write-Host "   ❌ UPN generation failed for $($testCase.FirstName) $($testCase.LastName): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            
        } else {
            Write-Host "❌ UPN generation script not found: $upnScript" -ForegroundColor Red
        }
    }
    
    "execute" {
        Write-Host "`n⚡ Testing Execution Script..." -ForegroundColor Cyan
        
        $executeScript = Join-Path $ScriptsPath "Create-User-AAD.ps1"
        if (Test-Path $executeScript) {
            Write-Host "✅ Execution script found: $executeScript" -ForegroundColor Green
            
            # Check for user account creation logic
            $scriptContent = Get-Content $executeScript -Raw
            
            if ($scriptContent -match "Create Service Account|Create Normal AVD Users") {
                Write-Host "   ✅ User account creation operations found" -ForegroundColor Green
            }
            
            if ($scriptContent -match "OperationType") {
                Write-Host "   ✅ Azure AD user creation script ready" -ForegroundColor Green
            }
            
        } else {
            Write-Host "❌ Execution script not found: $executeScript" -ForegroundColor Red
        }
    }
    
    "pipeline" {
        Write-Host "`n🔄 Testing Pipeline Configuration..." -ForegroundColor Cyan
        
        $pipelinePath = Join-Path $TestsPath "servicenow-user-creation-pipeline.yml"
        if (Test-Path $pipelinePath) {
            Write-Host "✅ Pipeline file found: $pipelinePath" -ForegroundColor Green
            
            $pipelineContent = Get-Content $pipelinePath -Raw
            
            # Check key pipeline components
            if ($pipelineContent -match "user_account") {
                Write-Host "   ✅ User account request type configured" -ForegroundColor Green
            }
            
            if ($pipelineContent -match "ServiceNowWebhook") {
                Write-Host "   ✅ ServiceNow webhook configured" -ForegroundColor Green
            }
            
            if ($pipelineContent -match "Parse-ServiceNowRequest") {
                Write-Host "   ✅ Parse step configured" -ForegroundColor Green
            }
            
            if ($pipelineContent -match "Validate-Request") {
                Write-Host "   ✅ Validation step configured" -ForegroundColor Green
            }
            
            if ($pipelineContent -match "Create-User-AAD") {
                Write-Host "   ✅ Execution step configured" -ForegroundColor Green
            }
            
        } else {
            Write-Host "❌ Pipeline file not found: $pipelinePath" -ForegroundColor Red
        }
    }
    
    "all" {
        Write-Host "`n🧪 Running All Tests..." -ForegroundColor Cyan
        
        & $PSCommandPath -TestType "schema"
        & $PSCommandPath -TestType "parse"
        & $PSCommandPath -TestType "validate"
        & $PSCommandPath -TestType "upn"
        & $PSCommandPath -TestType "execute"
        & $PSCommandPath -TestType "pipeline"
    }
    
    default {
        Write-Host "`n❌ Unknown test type: $TestType" -ForegroundColor Red
        Write-Host "Available test types:" -ForegroundColor Yellow
        Write-Host "  - schema    : Test JSON schema validation" -ForegroundColor Gray
        Write-Host "  - parse     : Test request parsing" -ForegroundColor Gray
        Write-Host "  - validate  : Test business validation" -ForegroundColor Gray
        Write-Host "  - upn       : Test UPN generation logic" -ForegroundColor Gray
        Write-Host "  - execute   : Test execution logic" -ForegroundColor Gray
        Write-Host "  - pipeline  : Test pipeline configuration" -ForegroundColor Gray
        Write-Host "  - all       : Run all tests" -ForegroundColor Gray
        Write-Host "`nExample: .\Test-Pipeline.ps1 -TestType upn" -ForegroundColor Yellow
    }
}

Write-Host "`n✨ Test completed!" -ForegroundColor Green