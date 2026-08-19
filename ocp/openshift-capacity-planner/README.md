# OpenShift Capacity Planner

Enterprise capacity assessment tool for:

- Red Hat OpenShift 4.x
- Azure Red Hat OpenShift (ARO)

Generates:

- Interactive offline HTML dashboard
- CSV exports
- JSON reports
- Growth forecasting
- Capacity recommendations


---

# Features

## Cluster Inventory

Collects:

- Nodes
- Node roles
- MachineSets
- VM sizes (ARO)
- Namespaces
- Pods
- PVCs
- StorageClasses


## Capacity Analysis

Calculates:

- CPU allocatable capacity
- Memory allocatable capacity
- CPU requests
- Memory requests
- Utilization percentage
- Overcommit
- Growth scenarios


## Forecasting

Simulates:

- Current
- +25%
- +50%
- +75%
- +100%


## Dashboard

Offline HTML report:

- Executive summary
- Health score
- Capacity status
- CPU charts
- Memory charts
- Namespace consumption
- Top consumers
- Recommendations


---

# Requirements


## Client Machine


Required:
bash
jq
awk
oc

Verify:

```bash
oc version

jq --version