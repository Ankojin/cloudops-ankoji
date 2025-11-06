# Pipeline Testing Guide

## 🎯 Overview
This directory contains test files and scripts to validate the ServiceNow-Azure DevOps pipeline components while the ServiceNow Developer prepares the request forms.

## 📁 Test Files

### Sample Request Files
- **`sample-user-request.json`** - Standard user account creation request
- **`sample-service-account-request.json`** - Service account creation request

### Test Script
- **`Test-Pipeline.ps1`** - PowerShell script to validate pipeline components

## 🧪 Testing the Pipeline

### 1. Test JSON Schema Validation
```powershell
.\Test-Pipeline.ps1 -TestType schema
```
This validates that the sample JSON files conform to the user-account-schema.json structure.

### 2. Test Request Parsing
```powershell
.\Test-Pipeline.ps1 -TestType parse
```
This tests the Parse-ServiceNowRequest.ps1 script with sample data.

### 3. Test Business Validation
```powershell
.\Test-Pipeline.ps1 -TestType validate
```
This validates the Validate-Request.ps1 script logic.

### 4. Test Execution Logic
```powershell
.\Test-Pipeline.ps1 -TestType execute
```
This checks the Execute-AzureAutomation.ps1 script configuration.

### 5. Test Pipeline Configuration
```powershell
.\Test-Pipeline.ps1 -TestType pipeline
```
This validates the main pipeline YAML configuration.

### 6. Run All Tests
```powershell
.\Test-Pipeline.ps1 -TestType all
```
This runs all tests in sequence.

## 📋 CSV Field Mapping

The test samples are aligned with the user-properties.csv requirements:

| CSV Field | JSON Field | Sample Value |
|-----------|------------|--------------|
| request_type | accountType | "User Account" |
| company | company | "BAB" |
| first_name | userDetails.firstName | "John" |
| last_name | userDetails.lastName | "Doe" |
| job_title | userDetails.jobTitle | "Software Developer" |
| department | userDetails.department | "IT" |
| employee_type | userDetails.employeeType | "Permanent" |
| manager | userDetails.manager | "jane.smith@bab.com" |

## 🔍 Test Coverage

### Schema Validation
- ✅ Required fields from CSV are mandatory
- ✅ Field length limits match CSV specifications
- ✅ Choice fields match CSV options
- ✅ Account types: "User Account" and "Service Account"
- ✅ Companies: "BAB", "ENJAZ", "ABIC", "ODC"
- ✅ Employee types: "Permanent", "Contract", "Temporary", "Vendor"

### Business Logic
- ✅ UPN validation (email format)
- ✅ Service account naming conventions (svc- prefix)
- ✅ Required approvals based on account type
- ✅ Company-specific validations

### Integration Points
- ✅ Pipeline webhook configuration
- ✅ Script integration paths
- ✅ Azure AD integration ready
- ✅ ServiceNow status updates

## 🚀 Ready for ServiceNow Developer

The pipeline components are ready and tested. The ServiceNow Developer can:

1. **Create the request form** using the user-properties.csv field definitions
2. **Test with sample payloads** using the provided JSON files
3. **Validate webhook integration** using the test script
4. **Configure business rules** to generate the JSON payload structure

## 📞 Pipeline Team Contact

For pipeline-related questions or issues:
- Pipeline components are validated and ready
- Sample payloads match the expected JSON schema
- Test scripts are available for validation
- Integration points are configured

## 🎯 Next Steps

1. **ServiceNow Developer**: Create forms based on CSV properties
2. **Pipeline Team**: Monitor test results and provide support
3. **Integration Testing**: Use sample payloads for end-to-end testing
4. **Production Deployment**: Deploy after successful testing