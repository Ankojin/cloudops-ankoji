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

Additional CSV exports provide an auditable scheduling inventory:

- `node_inventory_detailed.csv`
- `node_taints.csv`
- `pod_effective_requests.csv`
- `pod_tolerations.csv`
- `pool_capacity_detail.csv`


---

# Features

## Cluster Inventory

Collects:

- Nodes
- Node roles
- Ready and schedulable state
- Node taints, worker-pool classification, VM type, and zone
- MachineSets
- VM sizes (ARO)
- Namespaces
- Pods
- Pod placement, effective requests, init-container reservations, and tolerations
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
