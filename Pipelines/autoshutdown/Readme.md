
# Azure VM Auto-Shutdown with Terraform & Azure Pipelines

## Overview

This solution automates the configuration of daily auto-shutdown schedules for all virtual machines in a specified Azure resource group using Terraform, orchestrated by Azure Pipelines.

## Repository Structure

- `Pipelines/autoshutdown/main.tf`  
  Terraform configuration for discovering VMs and applying auto-shutdown schedules.
- `Pipelines/autoshutdown/autoshutdown-pipelines.yml`  
  Azure Pipeline YAML for deploying the Terraform configuration.

## Prerequisites

- Azure subscription with sufficient permissions.
- Azure DevOps agent pool (`cloudops-agent`) with Terraform installed or configured via pipeline.
- Variable group `TerraformVariables` in Azure DevOps containing credentials:
  - `servicePrincipalId`
  - `servicePrincipalKey`
  - `tenantId`
  - (Optional) `subscription_id` and `resource_group_name` if not provided as pipeline parameters.

## Usage

### 1. Configure Pipeline Parameters

When running the pipeline, you will be prompted for:
- **Azure Subscription ID**
- **Resource Group Name**
- **Shutdown Time (HHmm)** (default: `2000`)
- **Time Zone** (default: `Arab Standard Time`)

You can set default values in `autoshutdown-pipelines.yml`.

### 2. Pipeline Steps

- **TerraformInstaller@0**: Installs the latest Terraform version.
- **Terraform Init**: Initializes Terraform in the correct working directory.
- **Terraform Validate**: Validates the configuration.
- **Terraform Plan**: Plans the changes, passing all required variables.
- **Terraform Apply**: Applies the planned changes.

### 3. How It Works

- Discovers all VMs in the specified resource group.
- Applies an auto-shutdown schedule to each VM at the specified time and time zone.
- Notification settings are disabled by default.
