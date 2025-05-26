
VM Migration Script (Snapshot + SAS + Managed Disk)

Files:
- vm-migration.ps1        : Main PowerShell script to run
- vm-migration-map.csv    : Sample input/output CSV mapping
- README.txt              : This file

Instructions:
1. Replace service principal IDs/secrets and subscription IDs in the script.
2. Customize the CSV with your VM info (source/target RGs, VNETs, etc).
3. Run the script in PowerShell 7 with Az modules installed.

Make sure both source and target service principals have correct RBAC permissions!
