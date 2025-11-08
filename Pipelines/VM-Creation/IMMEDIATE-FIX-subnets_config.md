# 🚨 IMMEDIATE FIX: subnets_config Variable Issue

## Problem:
The pipeline cannot find the `subnets_config` variable in your Azure DevOps variable group.

## Solution:

### Step 1: Go to Azure DevOps Variable Groups
1. Open your Azure DevOps project
2. Navigate to **Pipelines** → **Library** → **Variable groups**
3. Find the **VM-Creation-SIT** variable group
4. Click **Edit**

### Step 2: Add/Update subnets_config Variable
Add this exact variable:

**Variable Name:** 
```
subnets_config
```

**Variable Value (copy this exactly):**
```json
{"app": ["snet-sit-nonpci-app-01", "snet-sit-nonpci-app-02", "snet-sit-nonpci-app-03"], "db": ["snet-sit-nonpci-db-01", "snet-sit-nonpci-db-02"], "web": ["snet-sit-nonpci-web-01", "snet-sit-nonpci-web-02"]}
```

### Step 3: Save and Re-run
1. Click **Save** in the variable group
2. Go back to your pipeline
3. Click **Run pipeline** again

## ⚠️ Important Notes:
- **Use the EXACT JSON format above** (single line, no extra spaces)
- **Do NOT add line breaks** in the JSON value
- **Do NOT mark this variable as secret** (it's just subnet names)
- **Make sure there are no extra quotes** around the JSON

## Alternative: Quick Test Format
If the above doesn't work, try this simplified version first:
```json
{"app": ["snet-sit-nonpci-app-01"], "db": ["snet-sit-nonpci-db-01"], "web": ["snet-sit-nonpci-web-01"]}
```

## Verification:
After adding the variable, you can verify it's working by:
1. Re-running the pipeline
2. Looking for this message: "✅ SET: SUBNETS_CONFIG (JSON format validated)"

The enhanced pipeline will now show you exactly what value it received and validate the JSON format before proceeding.